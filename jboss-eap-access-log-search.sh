#!/bin/bash
# JBoss EAP access_log を、反映時刻以降・JST の昇順で表示する。
# RHEL 9.8 の SSH 端末（Tera Term など）へ、このファイルの内容を
# そのまま貼り付けて実行する。
# 長い行は \ で折り返してある。\ の後ろに空白は入れない。
# 終端の EOS 行は消さない。
#
# 検索するファイル:
#   /mnt/logs/コンテナ/logs/ECSサービス/mid/タスクID/access_log.log
#   /mnt/logs/コンテナ/logs/ECSサービス/mid/current/access_log.log
#   /mnt/logs/コンテナ/logs/ECSサービス/mid/current/access_log.YYYY-MM-DD.log
#
# コンテナは front と back。
# ECS サービスは intra-web, intra-api, inter-api, sf-api。
# タスク ID は英数字 32 文字。
#
# エラーは HTTP 5xx（サーバエラー）で赤。
# 警告は HTTP 4xx（クライアントエラー）で黄。
# タイムゾーンが無い時刻は JST として扱う。

bash <<'EOS'
set -euo pipefail
umask 077

# ===== 検索条件（貼り付ける前にここを書き換える） =====
# 反映時刻 (JST)。この時刻以降を表示する。
REFLECT_TIME="2026-08-26 10:30:00"
# 空なら最新まで。例: 2026-08-26 12:00:00
END_TIME=""
# コンテナ。front と back。
CONTAINERS="front back"
# ECS サービス。
SERVICES="intra-web intra-api inter-api sf-api"
# 表示する区分。SHOW_ALL=1 のときは全部出す。
# ERROR は HTTP 5xx。WARN は HTTP 4xx。
# 500 や 5xx のように、ステータスでも指定できる。
LEVELS="ERROR WARN"
SHOW_ALL="0"
# 空なら区分条件だけ。含む行だけ残す（正規表現ではない）。
KEYWORD=""
BASE_DIR="/mnt/logs"
# リクエスト行とメッセージの表示上限。超えた分は省略する。
# Referer と UA は、画面幅に合わせて 180 文字で省略する。
MAX_FIELD="2000"
# 1 にすると、整形した行に加えて生の行も出す。
SHOW_RAW="0"
# 1 にすると、リダイレクト先でも色を付ける。
FORCE_COLOR="0"
# ======================================================

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

hr() {
  printf '%s\n' \
    "=============================================================================="
}

thin() {
  printf '%s\n' \
    "------------------------------------------------------------------------------"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

normalize_time() {
  local raw="$1" label="$2" cleaned
  cleaned=$(trim "$raw")
  cleaned=${cleaned//T/ }
  if [[ ! "$cleaned" =~ \
    ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}(:[0-9]{2})?$ ]]
  then
    die "${label}の形式が不正です: ${raw}"$'\n'"例: 2026-08-26 10:30:00"
  fi
  date -d "$cleaned" +%Y-%m-%d\ %H:%M:%S 2>/dev/null \
    || die "${label}が実在する日時ではありません: ${raw}"
}

csv_join() {
  local out="" x
  for x in "$@"; do
    if [[ -z "$out" ]]; then
      out="$x"
    else
      out="${out}, ${x}"
    fi
  done
  printf '%s' "$out"
}

setup_color() {
  C_RST=""
  C_BLD=""
  C_DIM=""
  C_RED=""
  C_YEL=""
  C_CYA=""
  C_GRN=""
  C_BLU=""
  C_BRED=""
  C_BYEL=""
  C_BAR_RED=""
  C_BAR_YEL=""
  if [[ "$FORCE_COLOR" == "1" || ( -t 1 && -z "${NO_COLOR:-}" ) ]]; then
    C_RST=$'\033[0m'
    C_BLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_YEL=$'\033[33m'
    C_CYA=$'\033[1;36m'
    C_GRN=$'\033[32m'
    C_BLU=$'\033[34m'
    C_BRED=$'\033[1;97;41m'
    C_BYEL=$'\033[1;30;43m'
    C_BAR_RED=$'\033[1;31m'
    C_BAR_YEL=$'\033[1;33m'
  fi
  export C_RST C_BLD C_DIM C_RED C_YEL C_CYA C_GRN C_BLU
  export C_BRED C_BYEL C_BAR_RED C_BAR_YEL
}

print_banner() {
  local level_text keyword_text end_text color_text
  if [[ "$SHOW_ALL" == "1" ]]; then
    level_text="全リクエスト（2xx や 3xx も含む）"
  else
    level_text="${LEVELS// /, }（ERROR=HTTP 5xx、WARN=HTTP 4xx）"
  fi
  if [[ -z "$KEYWORD" ]]; then
    keyword_text="指定なし"
  else
    keyword_text="$KEYWORD"
  fi
  if [[ -z "$END_NORM" ]]; then
    end_text="指定なし（最新まで）"
  else
    end_text="${END_NORM} まで"
  fi
  if [[ -n "$C_RST" ]]; then
    color_text="${C_BRED}エラー(5xx)${C_RST}は赤、${C_BYEL}警告(4xx)${C_RST}は黄"
  else
    color_text="この出力先では色を付けていません（端末へ直接出すと色が付きます）"
  fi
  hr
  printf '%s\n' " JBoss EAP access_log 検索"
  hr
  printf '%s\n' "  反映時刻 (JST) : ${REFLECT_NORM} 以降"
  printf '%s\n' "  終了時刻 (JST) : ${end_text}"
  printf '%s\n' "  コンテナ       : $(csv_join "${container_arr[@]}")"
  printf '%s\n' "  ECSサービス    : $(csv_join "${service_arr[@]}")"
  printf '%s\n' "  表示           : ${level_text}"
  printf '%s\n' "  キーワード     : ${keyword_text}"
  printf '%s\n' "  基点           : ${BASE_DIR}"
  printf '%s\n' "  対象ファイル   : access_log.log, access_log.YYYY-MM-DD.log"
  printf '%s\n' "  表示順         : JST の昇順"
  printf '%s\n' "  タイムゾーン   : 無い時刻は JST。ある場合は JST に換算"
  printf '%s\n' "  色             : ${color_text}"
  printf '%s\n' "  ローテーション : 反映日の前日より古い日付ファイルは読まない"
  hr
}

print_file_list() {
  local i n limit key container service count path
  thin
  printf '%s\n' " 対象ファイル ${#PATHS[@]} 件"
  if [[ ${#PATHS[@]} -gt 0 ]]; then
    thin
    n=0
    limit=40
    i=0
    while [[ $i -lt ${#PATHS[@]} ]]; do
      n=$((n + 1))
      if [[ $n -le $limit ]]; then
        printf '%s\n' \
          "  ${n}. コンテナ: ${CONTS[$i]}  ECSサービス: ${SERVS[$i]}  種別: ${KINDS[$i]}  タスク: ${TASKS[$i]}"
        printf '%s\n' "     ファイル: ${NAMES[$i]}"
        printf '%s\n' "     パス: ${PATHS[$i]}"
      fi
      i=$((i + 1))
    done
    if [[ ${#PATHS[@]} -gt $limit ]]; then
      printf '%s\n' "  ... 他 $(( ${#PATHS[@]} - limit )) 件"
    fi
  fi
  if [[ "$SKIPPED" -gt 0 ]]; then
    printf '%s\n' \
      "  読み飛ばした古いローテーション: ${SKIPPED} 件（反映日の前日より前）"
  fi
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    thin
    printf '%s\n' " ディレクトリなし:"
    for path in "${MISSING[@]}"; do
      printf '%s\n' "  ${path}"
    done
  fi
  if [[ ${#EMPTY_PAIRS[@]} -gt 0 ]]; then
    thin
    printf '%s\n' " ログファイルなし:"
    for key in "${EMPTY_PAIRS[@]}"; do
      IFS=$'\t' read -r container service path <<< "$key"
      printf '%s\n' "  コンテナ: ${container}  ECSサービス: ${service}"
      printf '%s\n' "  ${path}"
    done
  fi
  if [[ ${#OLD_ONLY_PAIRS[@]} -gt 0 ]]; then
    thin
    printf '%s\n' \
      " 古いローテーションだけで、反映時刻の範囲には入らないサービス:"
    for key in "${OLD_ONLY_PAIRS[@]}"; do
      IFS=$'\t' read -r container service path count <<< "$key"
      printf '%s\n' \
        "  コンテナ: ${container}  ECSサービス: ${service}  読み飛ばし: ${count} 件"
      printf '%s\n' "  ${path}"
    done
  fi
  if [[ ${#UNREADABLE[@]} -gt 0 ]]; then
    thin
    printf '%s\n' " 読めないパス:"
    for path in "${UNREADABLE[@]}"; do
      printf '%s\n' "  ${path}"
    done
  fi
  if [[ ${#BROKEN[@]} -gt 0 ]]; then
    thin
    printf '%s\n' " 切れたシンボリックリンク:"
    for path in "${BROKEN[@]}"; do
      printf '%s\n' "  ${path}"
    done
  fi
  if [[ ${#OUTSIDE[@]} -gt 0 ]]; then
    thin
    printf '%s\n' " 基点の外を指していたため除外:"
    for path in "${OUTSIDE[@]}"; do
      printf '%s\n' "  ${path}"
    done
  fi
  hr
}

load_stats() {
  local key rest cc ss ll nn code
  LINES_READ=0
  RECORDS_SEEN=0
  RECORDS_IN_TIME=0
  CLASS_EXCLUDED=0
  NO_STATUS=0
  KEYWORD_EXCLUDED=0
  SHOWN=0
  UNPARSED=0
  READ_ERRORS=0
  SAMPLE_UNPARSED=""
  SAMPLE_NOSTATUS=""
  CNT=()
  STATUS_COUNT=()
  LEVEL_COUNT=()
  while IFS=$'\t' read -r key rest || [[ -n "${key:-}" ]]; do
    [[ -z "${key:-}" ]] && continue
    case "$key" in
      lines_read) LINES_READ=$rest ;;
      records_seen) RECORDS_SEEN=$rest ;;
      records_in_time) RECORDS_IN_TIME=$rest ;;
      class_excluded) CLASS_EXCLUDED=$rest ;;
      no_status) NO_STATUS=$rest ;;
      keyword_excluded) KEYWORD_EXCLUDED=$rest ;;
      shown) SHOWN=$rest ;;
      unparsed) UNPARSED=$rest ;;
      read_errors) READ_ERRORS=$rest ;;
      sample_unparsed) SAMPLE_UNPARSED=$rest ;;
      sample_nostatus) SAMPLE_NOSTATUS=$rest ;;
      count)
        IFS=$'\t' read -r cc ss ll nn <<< "$rest"
        CNT["${cc}|${ss}|${ll}"]=$nn
        ;;
      status)
        IFS=$'\t' read -r code nn <<< "$rest"
        STATUS_COUNT["$code"]=$nn
        ;;
      levelonly)
        IFS=$'\t' read -r code nn <<< "$rest"
        LEVEL_COUNT["$code"]=$nn
        ;;
    esac
  done < "$stats"
}

count_of() {
  local key="$1"
  printf '%s' "${CNT[$key]:-0}"
}

print_status_breakdown() {
  local n code level
  if [[ ${#STATUS_COUNT[@]} -eq 0 && ${#LEVEL_COUNT[@]} -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "  ステータス内訳"
  if [[ ${#STATUS_COUNT[@]} -gt 0 ]]; then
    while IFS=$'\t' read -r n code; do
      printf '%s\n' "    HTTP ${code} × ${n}"
    done < <(
      for code in "${!STATUS_COUNT[@]}"; do
        printf '%d\t%s\n' "${STATUS_COUNT[$code]}" "$code"
      done | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2n
    )
  fi
  if [[ ${#LEVEL_COUNT[@]} -gt 0 ]]; then
    while IFS=$'\t' read -r n level; do
      printf '%s\n' "    レベル ${level} × ${n}"
    done < <(
      for level in "${!LEVEL_COUNT[@]}"; do
        printf '%d\t%s\n' "${LEVEL_COUNT[$level]}" "$level"
      done | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2
    )
  fi
}

print_summary() {
  local key container service e w ok redir info unk total
  local te=0 tw=0 tok=0 tre=0 tinfo=0 tunk=0 row
  hr
  printf '%s\n' " 件数（コンテナ / ECSサービス）"
  thin
  if [[ ${#PAIR_ORDER[@]} -eq 0 ]]; then
    printf '%s\n' "  集計するファイルがありません。"
  else
    for key in "${PAIR_ORDER[@]}"; do
      IFS=$'\t' read -r container service <<< "$key"
      e=$(count_of "${container}|${service}|ERROR")
      w=$(count_of "${container}|${service}|WARN")
      ok=$(count_of "${container}|${service}|OK")
      redir=$(count_of "${container}|${service}|REDIRECT")
      info=$(count_of "${container}|${service}|INFO")
      unk=$(count_of "${container}|${service}|UNKNOWN")
      total=$((e + w + ok + redir + info + unk))
      te=$((te + e))
      tw=$((tw + w))
      tok=$((tok + ok))
      tre=$((tre + redir))
      tinfo=$((tinfo + info))
      tunk=$((tunk + unk))
      row="  コンテナ ${container} / ECSサービス ${service}  エラー ${e}  警告 ${w}"
      if [[ "$SHOW_ALL" == "1" ]]; then
        row="${row}  正常 ${ok}  転送 ${redir}"
      fi
      if [[ "$info" -gt 0 ]]; then
        row="${row}  情報 ${info}"
      fi
      if [[ "$unk" -gt 0 ]]; then
        row="${row}  不明 ${unk}"
      fi
      printf '%s\n' "${row}  合計 ${total}"
    done
  fi
  thin
  row="  合計  エラー ${te}  警告 ${tw}"
  if [[ "$SHOW_ALL" == "1" ]]; then
    row="${row}  正常 ${tok}  転送 ${tre}"
  fi
  if [[ "$tinfo" -gt 0 ]]; then
    row="${row}  情報 ${tinfo}"
  fi
  if [[ "$tunk" -gt 0 ]]; then
    row="${row}  不明 ${tunk}"
  fi
  printf '%s\n' "${row}  表示 ${SHOWN}"
  print_status_breakdown
  printf '%s\n' "  読み込んだ行数           : ${LINES_READ}"
  printf '%s\n' "  時刻を読めた行           : ${RECORDS_SEEN}"
  printf '%s\n' "  反映時刻の範囲内         : ${RECORDS_IN_TIME}"
  printf '%s\n' "  区分条件で除外           : ${CLASS_EXCLUDED}"
  printf '%s\n' "  キーワードで除外         : ${KEYWORD_EXCLUDED}"
  printf '%s\n' "  表示                     : ${SHOWN}"
  printf '%s\n' "  時刻を読めない行         : ${UNPARSED}"
  if [[ "$UNPARSED" -gt 0 && -n "$SAMPLE_UNPARSED" ]]; then
    printf '%s\n' "    例: ${SAMPLE_UNPARSED}"
  fi
  printf '%s\n' "  時刻はあるがステータス不明 : ${NO_STATUS}"
  if [[ "$NO_STATUS" -gt 0 && -n "$SAMPLE_NOSTATUS" ]]; then
    printf '%s\n' "    例: ${SAMPLE_NOSTATUS}"
    printf '%s\n' \
      "    想定: 10.0.0.1 - - [26/Aug/2026:10:31:02 +0900] \"GET /path HTTP/1.1\" 500 123"
  fi
  if [[ "$READ_ERRORS" -gt 0 ]]; then
    printf '%s\n' "  読込エラー               : ${READ_ERRORS}"
  fi
  hr
}

remember_task() {
  local idx="$1" task="$2" is_current="$3"
  if [[ "$is_current" == "1" ]]; then
    KINDS[$idx]="current"
  fi
  if [[ "$task" =~ ^[0-9A-Za-z]{32}$ ]]; then
    TASKS[$idx]=$task
  fi
}

add_file() {
  local path="$1" container="$2" service="$3" task="$4" is_current="$5"
  local base_name="" file_date="" real="" inode="" idx="" kind=""
  base_name=$(basename -- "$path")
  if [[ "$base_name" =~ \
    ^access_log\.([0-9]{4}-[0-9]{2}-[0-9]{2})\.log$ ]]
  then
    file_date="${BASH_REMATCH[1]}"
    if ! date -d "$file_date" +%Y-%m-%d >/dev/null 2>&1; then
      return 0
    fi
  elif [[ "$base_name" != "access_log.log" ]]; then
    return 0
  fi
  if [[ -L "$path" && ! -e "$path" ]]; then
    if [[ -z "${BROKEN_MARK[$path]+x}" ]]; then
      BROKEN_MARK[$path]=1
      BROKEN+=("$path")
    fi
    return 0
  fi
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  if ! real=$(readlink -f -- "$path"); then
    return 0
  fi
  case "$real" in
    "$CURRENT_MID_REAL"/*) ;;
    *)
      if [[ -z "${OUTSIDE_MARK[$real]+x}" ]]; then
        OUTSIDE_MARK[$real]=1
        OUTSIDE+=("${path} -> ${real}")
      fi
      return 0
      ;;
  esac
  # stat はリンク自身を見る。-L で実体の inode を取り、current の二重読みを防ぐ。
  if ! inode=$(stat -L -c '%d:%i' -- "$path"); then
    return 0
  fi
  if [[ -n "${SEEN_INODE[$inode]+x}" ]]; then
    idx=${SEEN_INODE[$inode]}
    if [[ "$idx" == "skip" || "$idx" == "unread" ]]; then
      return 0
    fi
    remember_task "$idx" "$task" "$is_current"
    return 0
  fi
  if [[ ! -r "$path" ]]; then
    SEEN_INODE[$inode]="unread"
    UNREADABLE+=("$path")
    return 0
  fi
  if [[ -n "$file_date" ]]; then
    if [[ "$file_date" < "$skip_before" ]]; then
      SEEN_INODE[$inode]="skip"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
    if [[ -n "$skip_after" && "$file_date" > "$skip_after" ]]; then
      SEEN_INODE[$inode]="skip"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
  fi
  if [[ "$is_current" == "1" ]]; then
    kind="current"
  else
    kind="task"
  fi
  idx=${#PATHS[@]}
  SEEN_INODE[$inode]=$idx
  PATHS[$idx]=$path
  CONTS[$idx]=$container
  SERVS[$idx]=$service
  if [[ "$task" =~ ^[0-9A-Za-z]{32}$ ]]; then
    TASKS[$idx]=$task
  else
    TASKS[$idx]="-"
  fi
  KINDS[$idx]=$kind
  NAMES[$idx]=$base_name
}

scan_one_dir() {
  local dir="$1" container="$2" service="$3" task="$4" is_current="$5"
  local f
  local dated=()
  local sorted=()
  if [[ -e "${dir}/access_log.log" || -L "${dir}/access_log.log" ]]; then
    add_file \
      "${dir}/access_log.log" \
      "$container" "$service" "$task" "$is_current"
  fi
  dated=("${dir}"/access_log.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].log)
  if [[ ${#dated[@]} -gt 0 ]]; then
    mapfile -t sorted < <(printf '%s\n' "${dated[@]}" | LC_ALL=C sort)
    for f in "${sorted[@]}"; do
      if [[ -e "$f" || -L "$f" ]]; then
        add_file "$f" "$container" "$service" "$task" "$is_current"
      fi
    done
  fi
}

scan_service() {
  local container="$1" service="$2"
  local mid="${BASE_DIR}/${container}/logs/${service}/mid"
  local before skipped_before name d t
  local task_dirs=()
  local task_names=()
  if [[ ! -d "$mid" ]]; then
    MISSING+=("$mid")
    return 0
  fi
  if [[ ! -r "$mid" || ! -x "$mid" ]]; then
    UNREADABLE+=("$mid")
    return 0
  fi
  if ! CURRENT_MID_REAL=$(readlink -f -- "$mid"); then
    CURRENT_MID_REAL=$mid
  fi
  before=${#PATHS[@]}
  skipped_before=$SKIPPED
  for d in "$mid"/*/; do
    name=$(basename -- "$d")
    if [[ "$name" =~ ^[0-9A-Za-z]{32}$ ]]; then
      task_dirs+=("$name")
    fi
  done
  if [[ ${#task_dirs[@]} -gt 0 ]]; then
    mapfile -t task_names < <(printf '%s\n' "${task_dirs[@]}" | LC_ALL=C sort)
  fi
  if [[ ${#task_names[@]} -gt 0 ]]; then
    for t in "${task_names[@]}"; do
      scan_one_dir "${mid}/${t}" "$container" "$service" "$t" "0"
    done
  fi
  if [[ -L "${mid}/current" && ! -e "${mid}/current" ]]; then
    if [[ -z "${BROKEN_MARK[${mid}/current]+x}" ]]; then
      BROKEN_MARK["${mid}/current"]=1
      BROKEN+=("${mid}/current")
    fi
  elif [[ -d "${mid}/current" ]]; then
    scan_one_dir "${mid}/current" "$container" "$service" "-" "1"
  fi
  if [[ ${#PATHS[@]} -eq $before ]]; then
    if [[ "$SKIPPED" -gt "$skipped_before" ]]; then
      OLD_ONLY_PAIRS+=(
        "${container}"$'\t'"${service}"$'\t'"${mid}"$'\t'"$((SKIPPED - skipped_before))"
      )
    else
      EMPTY_PAIRS+=("${container}"$'\t'"${service}"$'\t'"${mid}")
    fi
  fi
}

write_manifest() {
  local i key
  : > "$manifest"
  i=0
  while [[ $i -lt ${#PATHS[@]} ]]; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${CONTS[$i]}" \
      "${SERVS[$i]}" \
      "${TASKS[$i]}" \
      "${KINDS[$i]}" \
      "${NAMES[$i]}" \
      "${PATHS[$i]}" >> "$manifest"
    key="${CONTS[$i]}"$'\t'"${SERVS[$i]}"
    if [[ -z "${PAIR_MARK[$key]+x}" ]]; then
      PAIR_MARK[$key]=1
      PAIR_ORDER+=("$key")
    fi
    i=$((i + 1))
  done
}

if [[ "$SHOW_ALL" != "0" && "$SHOW_ALL" != "1" ]]; then
  die "SHOW_ALL は 0 か 1 です。"
fi
if [[ "$SHOW_RAW" != "0" && "$SHOW_RAW" != "1" ]]; then
  die "SHOW_RAW は 0 か 1 です。"
fi
if [[ "$FORCE_COLOR" != "0" && "$FORCE_COLOR" != "1" ]]; then
  die "FORCE_COLOR は 0 か 1 です。"
fi
if [[ ! "$MAX_FIELD" =~ ^[0-9]+$ ]] || [[ "$MAX_FIELD" -lt 80 ]]; then
  die "MAX_FIELD は 80 以上の整数です。"
fi
awk_ver=$(awk --version 2>/dev/null || true)
case "$awk_ver" in
  *GNU\ Awk*) ;;
  *) die "GNU awk (gawk) が必要です。RHEL 9 の awk は gawk です。" ;;
esac

REFLECT_NORM=$(normalize_time "$REFLECT_TIME" "反映時刻")
END_NORM=""
if [[ -n "$(trim "$END_TIME")" ]]; then
  END_NORM=$(normalize_time "$END_TIME" "終了時刻")
fi
if [[ -n "$END_NORM" && "$END_NORM" < "$REFLECT_NORM" ]]; then
  die "終了時刻が反映時刻より前です。"
fi
reflect_date=${REFLECT_NORM%% *}
skip_before=$(date -d "${reflect_date} -1 day" +%Y-%m-%d) \
  || die "反映日の計算に失敗しました。"
skip_after=""
if [[ -n "$END_NORM" ]]; then
  end_date=${END_NORM%% *}
  skip_after=$(date -d "${end_date} +1 day" +%Y-%m-%d) \
    || die "終了日の計算に失敗しました。"
fi
REFLECT_KEY="${REFLECT_NORM}.000"
END_KEY=""
if [[ -n "$END_NORM" ]]; then
  END_KEY="${END_NORM}.999"
fi

read -r -a container_arr <<< "$CONTAINERS"
read -r -a service_arr <<< "$SERVICES"
if [[ ${#container_arr[@]} -eq 0 || ${#service_arr[@]} -eq 0 ]]; then
  die "CONTAINERS と SERVICES を指定してください。"
fi
for name in "${container_arr[@]}" "${service_arr[@]}"; do
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "コンテナ名または ECS サービス名が不正です: ${name}"
  fi
done
if [[ ! -d "$BASE_DIR" ]]; then
  die "基点ディレクトリがありません: ${BASE_DIR}"
fi
BASE_DIR=$(readlink -f -- "$BASE_DIR")

export REFLECT_KEY END_KEY LEVELS SHOW_ALL KEYWORD MAX_FIELD SHOW_RAW

setup_color
print_banner

shopt -s nullglob
declare -A SEEN_INODE=()
declare -A OUTSIDE_MARK=()
declare -A BROKEN_MARK=()
declare -A PAIR_MARK=()
declare -A CNT=()
declare -A STATUS_COUNT=()
declare -A LEVEL_COUNT=()
PATHS=()
CONTS=()
SERVS=()
TASKS=()
KINDS=()
NAMES=()
PAIR_ORDER=()
MISSING=()
EMPTY_PAIRS=()
OLD_ONLY_PAIRS=()
UNREADABLE=()
BROKEN=()
OUTSIDE=()
SKIPPED=0
CURRENT_MID_REAL=""

for container in "${container_arr[@]}"; do
  for service in "${service_arr[@]}"; do
    scan_service "$container" "$service"
  done
done

print_file_list

manifest=$(mktemp)
records=$(mktemp)
stats=$(mktemp)
extract_awk=$(mktemp)
format_awk=$(mktemp)
trap 'rm -f "$manifest" "$records" "$stats" "$extract_awk" "$format_awk"' EXIT
export MANIFEST="$manifest" RECORDS="$records" STATS="$stats"

if [[ ${#PATHS[@]} -eq 0 ]]; then
  printf '\n%s\n\n' \
    "該当するログはありません。読み込む access_log がありません。"
  exit 0
fi

write_manifest

cat > "$extract_awk" <<'EXTRACT_AWK'
function ymd_to_jd(Y, M, D,    a, y, m) {
  a = int((14 - M) / 12)
  y = Y + 4800 - a
  m = M + 12 * a - 3
  return D + int((153 * m + 2) / 5) + 365 * y + int(y / 4) - int(y / 100) + int(y / 400) - 32045
}
function jd_to_ymd(jd,    a, b, c, d, e, m, day, month, year) {
  a = jd + 32044
  b = int((4 * a + 3) / 146097)
  c = a - int((146097 * b) / 4)
  d = int((4 * c + 3) / 1461)
  e = c - int((1461 * d) / 4)
  m = int((5 * e + 2) / 153)
  day = e - int((153 * m + 2) / 5) + 1
  month = m + 3 - 12 * int(m / 10)
  year = b * 100 + d - 4800 + int(m / 10)
  return sprintf("%04d-%02d-%02d", year, month, day)
}
function shift_min(date, hms, ms, delta,    da, ta, total, days, rem, h, mi, s, jd) {
  split(date, da, "-")
  split(hms, ta, ":")
  total = (ta[1] + 0) * 60 + (ta[2] + 0) + delta
  days = int(total / 1440)
  rem = total % 1440
  if (rem < 0) {
    rem += 1440
    days--
  }
  h = int(rem / 60)
  mi = rem % 60
  s = ta[3] + 0
  jd = ymd_to_jd(da[1] + 0, da[2] + 0, da[3] + 0) + days
  return sprintf("%s %02d:%02d:%02d.%03d", jd_to_ymd(jd), h, mi, s, ms + 0)
}
function offset_minutes(tz,    sign, t, hh, mm) {
  if (tz == "" || tz == "JST") return 540
  if (tz == "Z" || tz == "UTC" || tz == "GMT") return 0
  sign = 1
  if (substr(tz, 1, 1) == "-") sign = -1
  t = tz
  sub(/^[+-]/, "", t)
  sub(/:/, "", t)
  hh = substr(t, 1, 2) + 0
  mm = substr(t, 3, 2) + 0
  return sign * (hh * 60 + mm)
}
function pad_ms(ms) {
  if (ms == "") return "000"
  if (length(ms) >= 3) return substr(ms, 1, 3)
  if (length(ms) == 2) return ms "0"
  if (length(ms) == 1) return ms "00"
  return "000"
}
function month_of(name,    u) {
  u = toupper(name)
  if (u == "JAN") return 1
  if (u == "FEB") return 2
  if (u == "MAR") return 3
  if (u == "APR") return 4
  if (u == "MAY") return 5
  if (u == "JUN") return 6
  if (u == "JUL") return 7
  if (u == "AUG") return 8
  if (u == "SEP") return 9
  if (u == "OCT") return 10
  if (u == "NOV") return 11
  if (u == "DEC") return 12
  return 0
}
function sanitize(s) {
  if (s == "") return ""
  gsub(/[\t\r\n\034]/, " ", s)
  gsub(/[\001-\010\013\014\016-\037\177]/, "", s)
  return s
}
function clip_sample(s) {
  s = sanitize(s)
  gsub(/\t/, " ", s)
  if (length(s) > 180) s = substr(s, 1, 180) "..."
  return s
}
function norm_level(s) {
  s = toupper(s)
  if (s == "WARNING") return "WARN"
  return s
}
function is_level(s) {
  return norm_level(s) ~ /^(FATAL|SEVERE|EMERGENCY|ERROR|WARN|INFO|DEBUG|TRACE)$/
}
function is_method(s) {
  return s ~ /^(GET|HEAD|POST|PUT|DELETE|CONNECT|OPTIONS|TRACE|PATCH)$/
}
function is_status(s) {
  return s ~ /^[1-5][0-9][0-9]$/
}
function status_class(code,    n) {
  if (!is_status(code)) return ""
  n = substr(code, 1, 1)
  if (n == "5") return "ERROR"
  if (n == "4") return "WARN"
  if (n == "3") return "REDIRECT"
  if (n == "2") return "OK"
  if (n == "1") return "INFO"
  return ""
}
function class_from_level(level,    u) {
  if (level == "") return ""
  u = norm_level(level)
  if (u == "ERROR" || u == "FATAL" || u == "SEVERE" || u == "EMERGENCY") return "ERROR"
  if (u == "WARN") return "WARN"
  if (u == "INFO" || u == "DEBUG" || u == "TRACE") return "OK"
  return ""
}
function decide_class(    c) {
  c = status_class(g_status)
  if (c != "") return c
  c = class_from_level(g_level)
  if (c != "") return c
  return "UNKNOWN"
}
function accept_record(class, status, level,    i, n, x, list) {
  if (show_all == 1) return 1
  n = split(levels, list, /[[:space:],]+/)
  for (i = 1; i <= n; i++) {
    x = toupper(list[i])
    if (x == "WARNING") x = "WARN"
    if (x == "") continue
    if (x == class) return 1
    if (status != "" && x == status) return 1
    if (level != "" && x == level) return 1
    if (x ~ /^[1-5]XX$/ && is_status(status) && substr(status, 1, 1) == substr(x, 1, 1)) return 1
  }
  return 0
}
function reset_fields() {
  g_ts = ""
  g_level = ""
  g_status = ""
  g_method = ""
  g_uri = ""
  g_proto = ""
  g_client = ""
  g_user = ""
  g_bytes = ""
  g_referer = ""
  g_ua = ""
  g_extra = ""
  g_message = ""
  g_orig = ""
  g_scan = ""
}
function append_extra(tok) {
  if (g_extra == "") g_extra = tok
  else g_extra = g_extra " " tok
}
function append_message(tok) {
  if (g_message == "") g_message = tok
  else g_message = g_message " " tok
}
function parse_request_line(text,    n, p, i, uri) {
  sub(/^[[:space:]]+/, "", text)
  sub(/[[:space:]]+$/, "", text)
  n = split(text, p, /[[:space:]]+/)
  if (n < 1) return
  g_method = p[1]
  if (n == 1) return
  if (n == 2) {
    g_uri = p[2]
    return
  }
  uri = p[2]
  if (p[n] ~ /^HTTP\/[0-9.]+$/) {
    g_proto = p[n]
    for (i = 3; i <= n - 1; i++) uri = uri " " p[i]
  } else {
    for (i = 3; i <= n; i++) uri = uri " " p[i]
  }
  g_uri = uri
}
function handle_quoted(text) {
  if (g_method == "" && text ~ /^(GET|HEAD|POST|PUT|DELETE|CONNECT|OPTIONS|TRACE|PATCH)([[:space:]]|$)/) {
    parse_request_line(text)
    return
  }
  if (g_level != "" && g_method == "" && g_status == "") {
    append_message("\"" text "\"")
    return
  }
  if (g_referer == "" && (text == "-" || text ~ /^https?:\/\//)) {
    g_referer = text
    return
  }
  if (g_ua == "") {
    g_ua = text
    return
  }
  append_extra("\"" text "\"")
}
function handle_bare(tok) {
  if (g_level != "" && g_method == "" && g_status == "") {
    append_message(tok)
    return
  }
  if (g_level == "" && is_level(tok) && g_method == "" && g_status == "") {
    g_level = norm_level(tok)
    return
  }
  if (g_method == "" && is_method(tok)) {
    g_method = tok
    return
  }
  if (g_method != "" && g_uri == "" && !is_status(tok) && tok !~ /^HTTP\//) {
    g_uri = tok
    return
  }
  if (g_method != "" && g_uri != "" && g_proto == "" && tok ~ /^HTTP\/[0-9.]+$/) {
    g_proto = tok
    return
  }
  if (g_status == "" && is_status(tok)) {
    g_status = tok
    return
  }
  if (g_status != "" && g_bytes == "" && tok ~ /^([0-9]+|-)$/) {
    g_bytes = tok
    return
  }
  if (g_client == "" && g_method == "" && g_status == "" && g_level == "") {
    g_client = tok
    return
  }
  append_extra(tok)
}
function parse_prefix(prefix,    n, p) {
  sub(/^[[:space:]]+/, "", prefix)
  sub(/[[:space:]]+$/, "", prefix)
  if (prefix == "") return
  n = split(prefix, p, /[[:space:]]+/)
  if (n >= 1 && p[1] != "") g_client = p[1]
  if (n >= 3) g_user = p[3]
}
function build_ts(year, mon, day, hh, mm, ss, ms, tz,    hms, off) {
  if (mon < 1 || mon > 12 || day < 1 || day > 31) return 0
  hh += 0
  mm += 0
  ss += 0
  if (hh > 23 || mm > 59 || ss > 59) return 0
  hms = sprintf("%02d:%02d:%02d", hh, mm, ss)
  if (tz != "") {
    off = offset_minutes(tz)
    if (off != 540) {
      g_orig = sprintf("%04d-%02d-%02d %s %s", year, mon, day, hms, tz)
    }
  } else {
    tz = "JST"
  }
  g_ts = shift_min( \
    sprintf("%04d-%02d-%02d", year, mon, day), \
    hms, pad_ms(ms), 540 - offset_minutes(tz))
  return 1
}
function parse_quoted_rest(rest,    tok, guard, was_quoted, i, n, c, out) {
  g_scan = rest
  guard = 0
  while (guard < 80) {
    guard++
    sub(/^[[:space:]]+/, "", g_scan)
    if (g_scan == "") return
    was_quoted = 0
    if (substr(g_scan, 1, 1) == "\"") {
      was_quoted = 1
      out = ""
      n = length(g_scan)
      i = 2
      while (i <= n) {
        c = substr(g_scan, i, 1)
        if (c == "\"") {
          g_scan = substr(g_scan, i + 1)
          break
        }
        out = out c
        i++
      }
      if (i > n && substr(g_scan, 1, 1) == "\"") g_scan = ""
      if (was_quoted) handle_quoted(out)
      continue
    }
    if (match(g_scan, /^[^[:space:]]+/)) {
      tok = substr(g_scan, 1, RLENGTH)
      g_scan = substr(g_scan, RLENGTH + 1)
      handle_bare(tok)
      continue
    }
    return
  }
}
function parse_line(line,    mon, ms, tz) {
  reset_fields()
  if (match(line, iso_re, cap)) {
    ms = cap[8]
    tz = cap[10]
    if (build_ts(cap[1] + 0, cap[2] + 0, cap[3] + 0, cap[4], cap[5], cap[6], ms, tz) == 0) {
      return 0
    }
    parse_quoted_rest(substr(line, RLENGTH + 1))
    return 1
  }
  if (match(line, br_re, cap)) {
    mon = month_of(cap[2])
    if (mon == 0) return 0
    ms = cap[8]
    tz = cap[10]
    if (build_ts(cap[3] + 0, mon, cap[1] + 0, cap[4], cap[5], cap[6], ms, tz) == 0) {
      return 0
    }
    parse_prefix(substr(line, 1, RSTART - 1))
    parse_quoted_rest(substr(line, RSTART + RLENGTH))
    return 1
  }
  return 0
}
function emit_record(container, service, task, kind, filename, filepath, raw, class,    sortkey, raw_out) {
  shown++
  count[container SUBSEP service SUBSEP class]++
  if (is_status(g_status)) status_count[g_status]++
  else if (g_level != "") level_count[g_level]++
  seq++
  sortkey = sprintf("%s|%s|%s|%s|%s|%08d", g_ts, container, service, task, filename, seq)
  raw_out = ""
  if (show_raw == 1) raw_out = sanitize(raw)
  printf "%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\n", \
    sortkey, sanitize(g_ts), sanitize(class), sanitize(container), sanitize(service), \
    sanitize(task), sanitize(kind), sanitize(filename), sanitize(filepath), \
    sanitize(g_status), sanitize(g_method), sanitize(g_uri), sanitize(g_proto), \
    sanitize(g_client), sanitize(g_user), sanitize(g_bytes), sanitize(g_referer), \
    sanitize(g_ua), sanitize(g_extra), sanitize(g_message), sanitize(g_orig), \
    sanitize(g_level), raw_out >> records
}
function handle_line(line, container, service, task, kind, filename, filepath,    class) {
  if (parse_line(line) == 0) {
    unparsed++
    if (sample_unparsed == "") sample_unparsed = clip_sample(line)
    return
  }
  records_seen++
  if (g_ts < reflect_key) return
  if (end_key != "" && g_ts > end_key) return
  records_in_time++
  class = decide_class()
  if (accept_record(class, g_status, g_level) == 0) {
    if (class == "UNKNOWN") {
      no_status++
      if (sample_nostatus == "") sample_nostatus = clip_sample(line)
    } else {
      class_excluded++
    }
    return
  }
  if (keyword != "" && index(line, keyword) == 0) {
    keyword_excluded++
    return
  }
  emit_record(container, service, task, kind, filename, filepath, line, class)
}
function read_log(path, container, service, task, kind, filename,    line, err) {
  while (1) {
    err = (getline line < path)
    if (err == 0) break
    if (err < 0) {
      read_errors++
      close(path)
      return
    }
    lines_read++
    sub(/\r$/, "", line)
    if (line ~ /^[[:space:]]*$/) continue
    handle_line(line, container, service, task, kind, filename, path)
  }
  close(path)
}
BEGIN {
  manifest = ENVIRON["MANIFEST"]
  records = ENVIRON["RECORDS"]
  stats = ENVIRON["STATS"]
  reflect_key = ENVIRON["REFLECT_KEY"]
  end_key = ENVIRON["END_KEY"]
  levels = ENVIRON["LEVELS"]
  keyword = ENVIRON["KEYWORD"]
  show_all = ENVIRON["SHOW_ALL"] + 0
  show_raw = ENVIRON["SHOW_RAW"] + 0
  br_re = "\\[([0-9]{2})/([A-Za-z]{3})/([0-9]{4}):" \
          "([0-9]{2}):([0-9]{2}):([0-9]{2})" \
          "([.,]([0-9]{1,6}))?" \
          "([[:space:]]*([+-][0-9]{2}:?[0-9]{2}|Z|JST|UTC|GMT))?\\]"
  iso_re = "^([0-9]{4})-([0-9]{2})-([0-9]{2})[ T]" \
           "([0-9]{2}):([0-9]{2}):([0-9]{2})" \
           "([.,]([0-9]{1,6}))?" \
           "([[:space:]]*([+-][0-9]{2}:?[0-9]{2}|Z|JST|UTC|GMT))?"
  while (1) {
    err = (getline line < manifest)
    if (err == 0) break
    if (err < 0) {
      read_errors++
      break
    }
    n = split(line, f, "\t")
    if (n < 6) continue
    read_log(f[6], f[1], f[2], f[3], f[4], f[5])
  }
  close(manifest)
}
END {
  print "lines_read\t" lines_read + 0 > stats
  print "records_seen\t" records_seen + 0 > stats
  print "records_in_time\t" records_in_time + 0 > stats
  print "class_excluded\t" class_excluded + 0 > stats
  print "no_status\t" no_status + 0 > stats
  print "keyword_excluded\t" keyword_excluded + 0 > stats
  print "shown\t" shown + 0 > stats
  print "unparsed\t" unparsed + 0 > stats
  print "read_errors\t" read_errors + 0 > stats
  print "sample_unparsed\t" sample_unparsed > stats
  print "sample_nostatus\t" sample_nostatus > stats
  for (k in count) {
    split(k, p, SUBSEP)
    print "count\t" p[1] "\t" p[2] "\t" p[3] "\t" count[k] > stats
  }
  for (k in status_count) {
    print "status\t" k "\t" status_count[k] > stats
  }
  for (k in level_count) {
    print "levelonly\t" k "\t" level_count[k] > stats
  }
  close(stats)
  close(records)
}
EXTRACT_AWK

cat > "$format_awk" <<'FORMAT_AWK'
function bar_color(class) {
  if (class == "WARN") return c_bar_yel
  if (class == "ERROR") return c_bar_red
  return c_dim
}
function body_color(class) {
  if (class == "WARN") return c_yel
  if (class == "ERROR") return c_red
  return ""
}
function class_label(class) {
  if (class == "ERROR") return "サーバエラー"
  if (class == "WARN") return "警告"
  if (class == "OK") return "正常"
  if (class == "REDIRECT") return "転送"
  if (class == "INFO") return "情報"
  return "不明"
}
function badge(class, status, level) {
  if (status ~ /^[1-5][0-9][0-9]$/) {
    if (class == "ERROR") return c_bred "[HTTP " status "]" c_rst
    if (class == "WARN") return c_byel "[HTTP " status "]" c_rst
    if (class == "OK") return c_grn "[HTTP " status "]" c_rst
    if (class == "REDIRECT") return c_cya "[HTTP " status "]" c_rst
    return c_dim "[HTTP " status "]" c_rst
  }
  if (level != "") {
    if (class == "ERROR") return c_bred "[" level "]" c_rst
    if (class == "WARN") return c_byel "[" level "]" c_rst
    return c_dim "[" level "]" c_rst
  }
  return c_dim "[不明]" c_rst
}
function clip_to(s, m) {
  if (m < 40) m = 40
  if (length(s) <= m) return s
  return substr(s, 1, m) sprintf(" ...（残り %d 文字）", length(s) - m)
}
function clip(s,    m) {
  m = max_field + 0
  if (m < 80) m = 80
  return clip_to(s, m)
}
function clip_side(s) {
  return clip_to(s, 180)
}
function add_bit(bits, text) {
  if (text == "") return bits
  if (bits == "") return text
  return bits "    " text
}
function emit(class, text) {
  print bar_color(class) "| " c_rst text c_rst
}
BEGIN {
  FS = "\034"
  c_rst = ENVIRON["C_RST"]
  c_bld = ENVIRON["C_BLD"]
  c_dim = ENVIRON["C_DIM"]
  c_red = ENVIRON["C_RED"]
  c_yel = ENVIRON["C_YEL"]
  c_cya = ENVIRON["C_CYA"]
  c_grn = ENVIRON["C_GRN"]
  c_blu = ENVIRON["C_BLU"]
  c_bred = ENVIRON["C_BRED"]
  c_byel = ENVIRON["C_BYEL"]
  c_bar_red = ENVIRON["C_BAR_RED"]
  c_bar_yel = ENVIRON["C_BAR_YEL"]
  max_field = ENVIRON["MAX_FIELD"] + 0
}
{
  class = $3
  ts = $2
  container = $4
  service = $5
  task = $6
  kind = $7
  filename = $8
  filepath = $9
  status = $10
  method = $11
  uri = $12
  proto = $13
  client = $14
  user = $15
  bytes = $16
  referer = $17
  ua = $18
  extra = $19
  message = $20
  orig = $21
  level = $22
  raw = $23
  print ""
  print bar_color(class) "-------- #" NR " --------" c_rst
  emit(class, c_cya ts c_rst "  " badge(class, status, level) "  " \
    c_grn container c_rst " / " c_blu service c_rst "  " \
    body_color(class) class_label(class) c_rst)
  emit(class, "種別: " c_bld kind c_rst "    タスク: " c_bld task c_rst)
  if (method != "" || uri != "") {
    req = ""
    if (method != "") req = c_bld method c_rst
    if (uri != "") {
      if (req != "") req = req "  "
      req = req body_color(class) clip(uri) c_rst
    }
    if (proto != "") req = req "  " c_dim proto c_rst
    emit(class, req)
  }
  if (message != "") emit(class, body_color(class) clip(message) c_rst)
  bits = ""
  if (client != "") bits = add_bit(bits, "クライアント: " client)
  if (user != "" && user != "-") bits = add_bit(bits, "ユーザ: " user)
  if (bytes != "" && bytes != "-") bits = add_bit(bits, "応答バイト: " bytes)
  if (extra ~ /^[0-9]+$/) {
    bits = add_bit(bits, "処理時間: " extra)
    extra = ""
  } else if (extra ~ /^[0-9]+[mM][sS]$/) {
    bits = add_bit(bits, "処理時間: " extra)
    extra = ""
  }
  if (bits != "") emit(class, bits)
  if (referer != "" && referer != "-") emit(class, "Referer: " c_dim clip_side(referer) c_rst)
  if (ua != "" && ua != "-") emit(class, "UA: " c_dim clip_side(ua) c_rst)
  if (extra != "") emit(class, "追加: " c_dim clip_side(extra) c_rst)
  if (orig != "") emit(class, "元の時刻: " c_dim orig c_rst)
  emit(class, "ファイル: " c_dim filename c_rst)
  emit(class, "パス: " c_dim filepath c_rst)
  if (raw != "") emit(class, "生ログ: " c_dim clip(raw) c_rst)
}
END {
  if (NR == 0) {
    print ""
    print "該当するログはありません。"
    print ""
  }
}
FORMAT_AWK

printf '%s\n' \
  "対象 ${#PATHS[@]} ファイルを、${REFLECT_NORM} 以降で読み込んでいます..." >&2
# END 規則のある awk は入力ファイルが無いと標準入力を読む。
# SSH へ貼り付けたスクリプト本体を読み込まないよう、標準入力を閉じる。
awk -f "$extract_awk" </dev/null
load_stats
if [[ "$SHOWN" -gt 0 ]]; then
  hr
  printf '%s\n' " アクセスログ ${SHOWN} 件（JST の昇順）"
  hr
  LC_ALL=C sort -t $'\034' -k1,1 -s -- "$records" \
    | awk -f "$format_awk"
else
  printf '\n%s\n' "該当するログはありません。"
  if [[ "$RECORDS_SEEN" -gt 0 && "$RECORDS_IN_TIME" -eq 0 ]]; then
    printf '%s\n' \
      "ログは ${RECORDS_SEEN} 件ありましたが、反映時刻 ${REFLECT_NORM} より前です。"
  elif [[ "$CLASS_EXCLUDED" -gt 0 ]]; then
    printf '%s\n' \
      "範囲内のリクエストは ${RECORDS_IN_TIME} 件あり、表示条件で ${CLASS_EXCLUDED} 件を除外しました。"
    printf '%s\n' "全部見るときは SHOW_ALL=\"1\" にしてください。"
  fi
  printf '\n'
fi
print_summary
EOS
