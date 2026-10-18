#!/bin/bash
# JBoss EAP gc.log を、反映時刻以降・JST の昇順で表示する。
# RHEL 9.8 の SSH 端末（Tera Term など）へ、このファイルの内容を
# そのまま貼り付けて実行する。
# 長い行は \ で折り返してある。\ の後ろに空白は入れない。
# 終端の EOS 行は消さない。
#
# 検索するファイル:
#   /mnt/logs/コンテナ/logs/ECSサービス/mid/タスクID/gc.log
#   /mnt/logs/コンテナ/logs/ECSサービス/mid/タスクID/gc.log.連番
#   /mnt/logs/コンテナ/logs/ECSサービス/mid/current/gc.log
#   /mnt/logs/コンテナ/logs/ECSサービス/mid/current/gc.log.連番
#
# 連番は gc.log.0、gc.log.1、gc.log.12 のように数字だけの回転ファイル。
# gc.log.YYYY-MM-DD のような日付付きの名前は対象にしない。
# コンテナは front と back。
# ECS サービスは intra-web, intra-api, inter-api, sf-api。
# タスク ID は英数字 32 文字。
#
# エラーは赤、警告は黄。
# エラー: error レベル、OutOfMemoryError、Evacuation Failure、
#         to-space exhausted、promotion failed、concurrent mode failure、
#         停止時間が PAUSE_ERROR_MS 以上。
# 警告: warning レベル、Full GC、System.gc、Metadata GC Threshold、
#       Humongous Allocation、GCLocker、停止時間が PAUSE_WARN_MS 以上。
# 通常の Young GC は出さない。全部見るときは SHOW_ALL=1。
# タイムゾーンが無い時刻は JST として扱う。ある場合は JST に換算する。
#
# 想定する書式:
#   JDK 11 以降の統合ログ（time / uptime / level / tags の並びは前後してよい）
#   JDK 8 の PrintGCDateStamps（複数行の PrintGCDetails も 1 件にまとめる）

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
# 表示する区分。SHOW_ALL=1 のときは、この指定を無視して全件を表示する。
# ERROR は障害と長い停止。WARN は Full GC や warning。
LEVELS="ERROR WARN"
SHOW_ALL="0"
# 空なら区分条件だけ。含む行だけ残す（正規表現ではない）。
KEYWORD=""
BASE_DIR="/mnt/logs"
# このミリ秒以上の Stop-The-World を警告にする。0 で無効。
PAUSE_WARN_MS="1000"
# このミリ秒以上の Stop-The-World をエラーにする。0 で無効。
PAUSE_ERROR_MS="5000"
# 0 なら Eden やフェーズ内訳などの明細は出さない。
# 1 なら明細も出す。SHOW_ALL=1 でも、0 のときは要約だけ残す。
DETAIL="0"
# 1 レコードあたり表示する継続行の上限。
MAX_CONT="40"
# 1 行の表示上限。超えた分は省略する。
MAX_LINE="2000"
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
  local level_text keyword_text end_text color_text detail_text
  local warn_text error_text
  if [[ "$SHOW_ALL" == "1" ]]; then
    level_text="全件（通常の Young GC も含む）"
  else
    level_text="${LEVELS// /, }（通常の Young GC は出さない）"
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
    color_text="${C_BRED}エラー${C_RST}は赤、${C_BYEL}警告${C_RST}は黄"
  else
    color_text="この出力先では色を付けていません（端末へ直接出すと色が付きます）"
  fi
  if [[ "$DETAIL" == "1" ]]; then
    detail_text="出す（Eden やフェーズ内訳も含む）"
  else
    detail_text="出さない（停止の要約と障害だけ）"
  fi
  if [[ "$PAUSE_WARN_MS" == "0" ]]; then
    warn_text="無効"
  else
    warn_text="${PAUSE_WARN_MS} ms 以上"
  fi
  if [[ "$PAUSE_ERROR_MS" == "0" ]]; then
    error_text="無効"
  else
    error_text="${PAUSE_ERROR_MS} ms 以上"
  fi
  hr
  printf '%s\n' " JBoss EAP gc.log 検索"
  hr
  printf '%s\n' "  反映時刻 (JST) : ${REFLECT_NORM} 以降"
  printf '%s\n' "  終了時刻 (JST) : ${end_text}"
  printf '%s\n' "  コンテナ       : $(csv_join "${container_arr[@]}")"
  printf '%s\n' "  ECSサービス    : $(csv_join "${service_arr[@]}")"
  printf '%s\n' "  表示           : ${level_text}"
  printf '%s\n' "  キーワード     : ${keyword_text}"
  printf '%s\n' "  基点           : ${BASE_DIR}"
  printf '%s\n' "  対象ファイル   : gc.log, gc.log.連番（gc.log.0, gc.log.1, ...）"
  printf '%s\n' "  表示順         : JST の昇順"
  printf '%s\n' "  タイムゾーン   : 無い時刻は JST。ある場合は JST に換算"
  printf '%s\n' "  明細           : ${detail_text}"
  printf '%s\n' "  停止の警告     : ${warn_text}"
  printf '%s\n' "  停止のエラー   : ${error_text}"
  printf '%s\n' "  色             : ${color_text}"
  printf '%s\n' "  ローテーション : 数字の連番はすべて読む。時刻で絞り込む"
  hr
}

print_file_list() {
  local i n limit key container service path
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
  local key rest cc ss ll nn
  LINES_READ=0
  RECORDS_SEEN=0
  RECORDS_IN_TIME=0
  LEVEL_EXCLUDED=0
  DETAIL_EXCLUDED=0
  KEYWORD_EXCLUDED=0
  SHOWN=0
  UNPARSED=0
  READ_ERRORS=0
  SAMPLE=""
  CNT=()
  while IFS=$'\t' read -r key rest || [[ -n "${key:-}" ]]; do
    [[ -z "${key:-}" ]] && continue
    case "$key" in
      lines_read) LINES_READ=$rest ;;
      records_seen) RECORDS_SEEN=$rest ;;
      records_in_time) RECORDS_IN_TIME=$rest ;;
      level_excluded) LEVEL_EXCLUDED=$rest ;;
      detail_excluded) DETAIL_EXCLUDED=$rest ;;
      keyword_excluded) KEYWORD_EXCLUDED=$rest ;;
      shown) SHOWN=$rest ;;
      unparsed) UNPARSED=$rest ;;
      read_errors) READ_ERRORS=$rest ;;
      sample) SAMPLE=$rest ;;
      count)
        IFS=$'\t' read -r cc ss ll nn <<< "$rest"
        CNT["${cc}|${ss}|${ll}"]=$nn
        ;;
    esac
  done < "$stats"
}

count_of() {
  local key="$1"
  printf '%s' "${CNT[$key]:-0}"
}

print_summary() {
  local key container service e w info debug trace total row
  local te=0 tw=0 tinfo=0 tdebug=0 ttrace=0
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
      info=$(count_of "${container}|${service}|INFO")
      debug=$(count_of "${container}|${service}|DEBUG")
      trace=$(count_of "${container}|${service}|TRACE")
      total=$((e + w + info + debug + trace))
      te=$((te + e))
      tw=$((tw + w))
      tinfo=$((tinfo + info))
      tdebug=$((tdebug + debug))
      ttrace=$((ttrace + trace))
      row="  コンテナ ${container} / ECSサービス ${service}  エラー ${e}  警告 ${w}"
      if [[ "$SHOW_ALL" == "1" || "$info" -gt 0 ]]; then
        row="${row}  情報 ${info}"
      fi
      if [[ "$debug" -gt 0 ]]; then
        row="${row}  DEBUG ${debug}"
      fi
      if [[ "$trace" -gt 0 ]]; then
        row="${row}  TRACE ${trace}"
      fi
      printf '%s\n' "${row}  合計 ${total}"
    done
  fi
  thin
  row="  合計  エラー ${te}  警告 ${tw}"
  if [[ "$SHOW_ALL" == "1" || "$tinfo" -gt 0 ]]; then
    row="${row}  情報 ${tinfo}"
  fi
  if [[ "$tdebug" -gt 0 ]]; then
    row="${row}  DEBUG ${tdebug}"
  fi
  if [[ "$ttrace" -gt 0 ]]; then
    row="${row}  TRACE ${ttrace}"
  fi
  printf '%s\n' "${row}  表示 ${SHOWN}"
  printf '%s\n' "  読み込んだ行数       : ${LINES_READ}"
  printf '%s\n' "  時刻を読めた行       : ${RECORDS_SEEN}"
  printf '%s\n' "  反映時刻の範囲内     : ${RECORDS_IN_TIME}"
  printf '%s\n' "  区分条件で除外       : ${LEVEL_EXCLUDED}"
  printf '%s\n' "  明細のため除外       : ${DETAIL_EXCLUDED}"
  printf '%s\n' "  キーワードで除外     : ${KEYWORD_EXCLUDED}"
  printf '%s\n' "  表示                 : ${SHOWN}"
  printf '%s\n' "  時刻を読めない行     : ${UNPARSED}"
  if [[ "$UNPARSED" -gt 0 && -n "$SAMPLE" ]]; then
    printf '%s\n' "    例: ${SAMPLE}"
    printf '%s\n' \
      "    想定: [2026-08-26T10:31:02.145+0900][info][gc] GC(1) Pause Young ..."
  fi
  if [[ "$READ_ERRORS" -gt 0 ]]; then
    printf '%s\n' "  読込エラー           : ${READ_ERRORS}"
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
  local base_name="" real="" inode="" idx="" kind=""
  base_name=$(basename -- "$path")
  if [[ "$base_name" != "gc.log" && ! "$base_name" =~ ^gc\.log\.[0-9]+$ ]]; then
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
  # stat はリンク自身ではなく実体を見る。current とタスクの二重読みを防ぐ。
  if ! inode=$(stat -L -c '%d:%i' -- "$path"); then
    return 0
  fi
  if [[ -n "${SEEN_INODE[$inode]+x}" ]]; then
    idx=${SEEN_INODE[$inode]}
    if [[ "$idx" == "unread" ]]; then
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
  local f base
  local -a numbered=()
  local -a ordered=()
  if [[ -e "${dir}/gc.log" || -L "${dir}/gc.log" ]]; then
    ordered+=("gc.log")
  fi
  for f in "${dir}"/gc.log.[0-9]*; do
    base=$(basename -- "$f")
    if [[ "$base" =~ ^gc\.log\.[0-9]+$ ]]; then
      numbered+=("$base")
    fi
  done
  if [[ ${#numbered[@]} -gt 0 ]]; then
    mapfile -t numbered < <(printf '%s\n' "${numbered[@]}" | sort -t. -k3,3n)
    ordered+=("${numbered[@]}")
  fi
  for base in "${ordered[@]}"; do
    add_file "${dir}/${base}" "$container" "$service" "$task" "$is_current"
  done
}

scan_service() {
  local container="$1" service="$2"
  local mid="${BASE_DIR}/${container}/logs/${service}/mid"
  local before name d t
  local before_broken before_unread before_outside
  local -a task_dirs=()
  local -a task_names=()
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
  before_broken=${#BROKEN[@]}
  before_unread=${#UNREADABLE[@]}
  before_outside=${#OUTSIDE[@]}
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
  if [[ ${#PATHS[@]} -eq $before \
    && ${#BROKEN[@]} -eq $before_broken \
    && ${#UNREADABLE[@]} -eq $before_unread \
    && ${#OUTSIDE[@]} -eq $before_outside ]]; then
    EMPTY_PAIRS+=("${container}"$'\t'"${service}"$'\t'"${mid}")
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
if [[ "$DETAIL" != "0" && "$DETAIL" != "1" ]]; then
  die "DETAIL は 0 か 1 です。"
fi
if [[ "$FORCE_COLOR" != "0" && "$FORCE_COLOR" != "1" ]]; then
  die "FORCE_COLOR は 0 か 1 です。"
fi
if [[ ! "$PAUSE_WARN_MS" =~ ^[0-9]+$ ]]; then
  die "PAUSE_WARN_MS は 0 以上の整数です。0 で無効になります。"
fi
if [[ ! "$PAUSE_ERROR_MS" =~ ^[0-9]+$ ]]; then
  die "PAUSE_ERROR_MS は 0 以上の整数です。0 で無効になります。"
fi
if [[ "$PAUSE_WARN_MS" != "0" && "$PAUSE_ERROR_MS" != "0" \
  && "$PAUSE_ERROR_MS" -lt "$PAUSE_WARN_MS" ]]; then
  die "PAUSE_ERROR_MS は PAUSE_WARN_MS 以上にしてください。"
fi
if [[ ! "$MAX_CONT" =~ ^[0-9]+$ ]] || [[ "$MAX_CONT" -lt 1 ]]; then
  die "MAX_CONT は 1 以上の整数です。"
fi
if [[ ! "$MAX_LINE" =~ ^[0-9]+$ ]] || [[ "$MAX_LINE" -lt 80 ]]; then
  die "MAX_LINE は 80 以上の整数です。"
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

export REFLECT_KEY END_KEY LEVELS SHOW_ALL KEYWORD MAX_CONT MAX_LINE
export PAUSE_WARN_MS PAUSE_ERROR_MS DETAIL

setup_color
print_banner

shopt -s nullglob
declare -A SEEN_INODE=()
declare -A OUTSIDE_MARK=()
declare -A BROKEN_MARK=()
declare -A PAIR_MARK=()
declare -A CNT=()
PATHS=()
CONTS=()
SERVS=()
TASKS=()
KINDS=()
NAMES=()
PAIR_ORDER=()
MISSING=()
EMPTY_PAIRS=()
UNREADABLE=()
BROKEN=()
OUTSIDE=()
CURRENT_MID_REAL=""

for container in "${container_arr[@]}"; do
  for service in "${service_arr[@]}"; do
    scan_service "$container" "$service"
  done
done

print_file_list

if [[ ${#PATHS[@]} -eq 0 ]]; then
  printf '\n%s\n\n' \
    "該当するログはありません。読み込む gc.log がありません。"
  exit 0
fi

manifest=$(mktemp)
records=$(mktemp)
stats=$(mktemp)
extract_awk=$(mktemp)
format_awk=$(mktemp)
trap 'rm -f "$manifest" "$records" "$stats" "$extract_awk" "$format_awk"' EXIT
export MANIFEST="$manifest" RECORDS="$records" STATS="$stats"

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
function offset_minutes(tz,    sign, t, hh, mm, u) {
  if (tz == "" || tz == "JST") return 540
  u = toupper(tz)
  if (u == "Z" || u == "UTC" || u == "GMT") return 0
  sign = 1
  if (substr(tz, 1, 1) == "-") sign = -1
  t = tz
  sub(/^[+-]/, "", t)
  gsub(/:/, "", t)
  # 負のオフセットは西半球の正しい値。不正なときだけ -10000 を返す。
  if (length(t) < 4) return -10000
  hh = substr(t, 1, 2) + 0
  mm = substr(t, 3, 2) + 0
  if (hh > 18 || mm > 59) return -10000
  return sign * (hh * 60 + mm)
}
function pad_ms(ms) {
  if (ms == "") return "000"
  if (length(ms) >= 3) return substr(ms, 1, 3)
  if (length(ms) == 2) return ms "0"
  if (length(ms) == 1) return ms "00"
  return "000"
}
function valid_ymd(y, m, d,    leap) {
  if (m < 1 || m > 12 || d < 1) return 0
  if (m == 2) {
    leap = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
    if (leap && d > 29) return 0
    if (!leap && d > 28) return 0
    return 1
  }
  if ((m == 4 || m == 6 || m == 9 || m == 11) && d > 30) return 0
  if (d > 31) return 0
  return 1
}
function build_ts(year, mon, day, hh, mm, ss, ms, tz,    hms, off, shown) {
  year += 0
  mon += 0
  day += 0
  hh += 0
  mm += 0
  ss += 0
  if (valid_ymd(year, mon, day) == 0) return 0
  if (hh > 23 || mm > 59 || ss > 59) return 0
  hms = sprintf("%02d:%02d:%02d", hh, mm, ss)
  if (tz == "") tz = "JST"
  off = offset_minutes(tz)
  if (off < -900) return 0
  if (off != 540) {
    shown = tz
    if (toupper(shown) == "Z") shown = "Z"
    g_orig = sprintf("%04d-%02d-%02d %s.%s %s", year, mon, day, hms, pad_ms(ms), shown)
  } else {
    g_orig = ""
  }
  g_ts = shift_min(sprintf("%04d-%02d-%02d", year, mon, day), hms, pad_ms(ms), 540 - off)
  return 1
}
function epoch_to_stamp(ms, add_hours,    sec, rem, days, sod, h, mi, s, jd0) {
  sec = int(ms / 1000)
  rem = int(ms - sec * 1000)
  if (rem < 0) {
    rem += 1000
    sec--
  }
  days = int(sec / 86400)
  sod = sec - days * 86400
  if (sod < 0) {
    sod += 86400
    days--
  }
  sod += add_hours * 3600
  while (sod >= 86400) {
    sod -= 86400
    days++
  }
  while (sod < 0) {
    sod += 86400
    days--
  }
  h = int(sod / 3600)
  mi = int((sod % 3600) / 60)
  s = sod % 60
  jd0 = ymd_to_jd(1970, 1, 1)
  return sprintf("%s %02d:%02d:%02d.%03d", jd_to_ymd(jd0 + days), h, mi, s, rem)
}
function norm_level_token(token,    s) {
  s = tolower(token)
  gsub(/[[:space:]]/, "", s)
  if (s == "warning") return "WARN"
  if (s == "warn") return "WARN"
  if (s == "error" || s == "fatal" || s == "severe" || s == "emergency") return "ERROR"
  if (s == "info") return "INFO"
  if (s == "debug") return "DEBUG"
  if (s == "trace") return "TRACE"
  return ""
}
function is_level_token(token) {
  return norm_level_token(token) != ""
}
function is_uptime_token(token) {
  if (token ~ /^[0-9]{13,16}ms$/) return 0
  return token ~ /^[0-9]+(\.[0-9]+)?(ms|s)$/
}
function is_epoch_token(token) {
  return token ~ /^[0-9]{13,16}ms$/
}
function reset_parse() {
  g_ts = ""
  g_orig = ""
  g_explicit = ""
  g_tags = ""
  g_msg = ""
  g_show = ""
}
function parse_iso_token(token,    c, re) {
  re = "^([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]"
  re = re "([0-9]{2}):([0-9]{2}):([0-9]{2})"
  re = re "([.,]([0-9]{1,9}))?"
  re = re "([Zz]|[+-][0-9]{2}:?[0-9]{2})?$"
  if (match(token, re, c) == 0) return 0
  return build_ts(c[1], c[2], c[3], c[4], c[5], c[6], c[8], c[9])
}
function apply_epoch_token(token,    n, ms) {
  n = token
  sub(/ms$/, "", n)
  ms = n + 0
  g_ts = epoch_to_stamp(ms, 9)
  g_orig = epoch_to_stamp(ms, 0) " Z"
  return 1
}
function append_deco(token,    shown) {
  shown = token
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", shown)
  if (shown == "") return
  if (g_deco == "") g_deco = "[" shown "]"
  else g_deco = g_deco "[" shown "]"
  if (g_tags == "") g_tags = shown
  else g_tags = g_tags "," shown
}
function parse_unified(line,    rest, token, toklen, dcap, saw_iso, level) {
  if (substr(line, 1, 1) != "[") return 0
  rest = line
  saw_iso = 0
  g_deco = ""
  while (match(rest, /^\[([^]]*)\]/, dcap)) {
    token = dcap[1]
    toklen = RLENGTH
    if (parse_iso_token(token)) {
      saw_iso = 1
    } else if (!saw_iso && is_epoch_token(token)) {
      apply_epoch_token(token)
    } else if (is_level_token(token)) {
      level = norm_level_token(token)
      if (g_explicit == "" || level == "ERROR" || (level == "WARN" && g_explicit != "ERROR")) {
        g_explicit = level
      }
      append_deco(token)
    } else if (is_uptime_token(token)) {
      # 起動後経過は表示時刻と混ざるので、装飾からは落とす。
    } else {
      append_deco(token)
    }
    rest = substr(rest, toklen + 1)
    if (substr(rest, 1, 1) != "[") break
  }
  if (g_ts == "") return 0
  sub(/^[[:space:]]+/, "", rest)
  g_msg = rest
  if (g_deco != "") g_show = g_deco " " g_msg
  else g_show = g_msg
  return 1
}
function parse_jdk8(line,    c, rest, re) {
  re = "^([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]"
  re = re "([0-9]{2}):([0-9]{2}):([0-9]{2})"
  re = re "([.,]([0-9]{1,9}))?"
  re = re "([Zz]|[+-][0-9]{2}:?[0-9]{2})?:[[:space:]]*"
  if (match(line, re, c) == 0) return 0
  if (build_ts(c[1], c[2], c[3], c[4], c[5], c[6], c[8], c[9]) == 0) return 0
  rest = substr(line, RLENGTH + 1)
  if (match(rest, /^[0-9]+(\.[0-9]+)?[[:space:]]*:[[:space:]]*/)) {
    rest = substr(rest, RLENGTH + 1)
  }
  g_msg = rest
  g_show = rest
  g_explicit = ""
  g_tags = ""
  return 1
}
function parse_line(line) {
  reset_parse()
  if (substr(line, 1, 1) == "[") {
    if (parse_unified(line)) return 1
    reset_parse()
  }
  if (parse_jdk8(line)) return 1
  reset_parse()
  return 0
}
function looks_like_ts(line) {
  if (line ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}/) return 1
  if (line ~ /^\[[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}/) return 1
  if (line ~ /^\[[^]]{0,40}\]\[[0-9]{4}-[0-9]{2}-[0-9]{2}[T ]/) return 1
  if (line ~ /^\[[0-9]{13,16}ms\]/) return 1
  return 0
}
function sanitize(s) {
  if (s == "") return ""
  gsub(/\t/, " ", s)
  gsub(/\034/, " ", s)
  gsub(/\036/, " ", s)
  gsub(/\r/, "", s)
  gsub(/[\001-\010\013\014\016-\037\177]/, "", s)
  return s
}
function clip_text(s,    n) {
  n = max_line + 0
  if (n < 80) n = 2000
  if (length(s) > n) return substr(s, 1, n) "..."
  return s
}
function clip_sample(s) {
  s = sanitize(s)
  if (length(s) > 180) s = substr(s, 1, 180) "..."
  return s
}
function lower(s) {
  return tolower(s)
}
function has_failure(msg,    u) {
  u = lower(msg)
  if (u ~ /outofmemoryerror/) return 1
  if (u ~ /overhead limit exceeded/) return 1
  if (u ~ /evacuation failure/) return 1
  if (u ~ /to-space exhausted/) return 1
  if (u ~ /to space exhausted/) return 1
  if (u ~ /promotion failed/) return 1
  if (u ~ /concurrent mode failure/) return 1
  if (u ~ /failed to allocate/) return 1
  if (u ~ /allocation request failed/) return 1
  return 0
}
function is_full(msg,    u) {
  u = lower(msg)
  if (u ~ /pause full/) return 1
  if (u ~ /\[full gc/) return 1
  if (u ~ /(^|[^a-z])full gc([^a-z]|$)/) return 1
  return 0
}
function has_warning_event(msg,    u) {
  u = lower(msg)
  if (is_full(msg)) return 1
  if (u ~ /system\.gc/) return 1
  if (u ~ /metadata gc threshold/) return 1
  if (u ~ /humongous allocation/) return 1
  if (u ~ /g1 humongous allocation/) return 1
  if (u ~ /gclocker initiated gc/) return 1
  if (u ~ /gc locker/) return 1
  if (u ~ /last ditch collection/) return 1
  return 0
}
function is_stw_text(msg,    u) {
  u = lower(msg)
  if (u ~ /pause young|pause mixed|pause full|pause remark|pause cleanup|pause initial/) return 1
  if (u ~ /\[full gc/) return 1
  if (u ~ /\[gc pause/) return 1
  if (u ~ /\[gc \(/) return 1
  if (u ~ /\[gc /) return 1
  return 0
}
function measure_pause_ms(msg,    rest, best, num, unit) {
  rest = msg
  best = -1
  while (match(rest, /([0-9]+(\.[0-9]+)?)[[:space:]]*(ms|secs|sec|s)([^A-Za-z]|$)/, pcap)) {
    num = pcap[1] + 0
    unit = pcap[3]
    if (unit == "ms") best = num
    else best = num * 1000
    if (RSTART + RLENGTH <= 1) break
    rest = substr(rest, RSTART + RLENGTH)
    if (rest == "") break
  }
  return best
}
function format_pause(ms) {
  if (ms < 0) return ""
  if (ms >= 1000) return sprintf("%.3fs", ms / 1000)
  return sprintf("%.3fms", ms)
}
function extract_heap(msg,    rest, re, plain) {
  heap_before = ""
  heap_after = ""
  heap_max = ""
  rest = msg
  re = "([0-9]+(\\.[0-9]+)?)([BKMGTP])[[:space:]]*->"
  re = re "[[:space:]]*([0-9]+(\\.[0-9]+)?)([BKMGTP])"
  re = re "[[:space:]]*\\([[:space:]]*"
  re = re "([0-9]+(\\.[0-9]+)?)([BKMGTP])[[:space:]]*\\)"
  while (match(rest, re, hcap)) {
    heap_before = hcap[1] hcap[3]
    heap_after = hcap[4] hcap[6]
    heap_max = hcap[7] hcap[9]
    rest = substr(rest, RSTART + RLENGTH)
    if (rest == "") break
  }
  if (heap_before != "") return
  rest = msg
  plain = "([0-9]+(\\.[0-9]+)?)([BKMGTP])[[:space:]]*->"
  plain = plain "[[:space:]]*([0-9]+(\\.[0-9]+)?)([BKMGTP])"
  while (match(rest, plain, hcap)) {
    heap_before = hcap[1] hcap[3]
    heap_after = hcap[4] hcap[6]
    heap_max = ""
    rest = substr(rest, RSTART + RLENGTH)
    if (rest == "") break
  }
}
function heap_text() {
  if (heap_before == "") return ""
  if (heap_max != "") {
    return heap_before " -> " heap_after " (上限 " heap_max ")"
  }
  return heap_before " -> " heap_after
}
function extract_cause(msg,    i, n, c, depth, start, last, prev, inner) {
  n = length(msg)
  last = ""
  prev = ""
  i = 1
  while (i <= n) {
    c = substr(msg, i, 1)
    if (c == "(") {
      start = i
      depth = 1
      i++
      while (i <= n && depth > 0) {
        c = substr(msg, i, 1)
        if (c == "(") depth++
        else if (c == ")") depth--
        i++
      }
      inner = substr(msg, start + 1, i - start - 2)
      if (inner ~ /^[0-9]+(\.[0-9]+)?[BKMGTP%]?$/) continue
      if (inner ~ /^[0-9]+(\.[0-9]+)?[[:space:]]*secs?$/) continue
      prev = last
      last = inner
    } else {
      i++
    }
  }
  if (last == "") return ""
  if (last ~ /^(Normal|normal|young|Young|mixed|Mixed|full|Full)$/ && prev != "") {
    return prev
  }
  return last
}
function extract_gc_id(msg,    c) {
  if (match(msg, /GC\(([0-9]+)\)/, c)) return c[1]
  return ""
}
function event_kind(msg,    u) {
  u = lower(msg)
  if (is_full(msg)) return "Full GC"
  if (u ~ /pause young \(mixed\)|pause mixed/) return "Mixed GC"
  if (u ~ /pause young \(prepare mixed\)/) return "Prepare Mixed"
  if (u ~ /pause young \(concurrent start\)|initial-mark|pause initial/) return "Initial Mark"
  if (u ~ /pause remark/) return "Remark"
  if (u ~ /pause cleanup/) return "Cleanup"
  if (u ~ /pause young/) return "Young GC"
  if (u ~ /\[gc pause/) return "GC Pause"
  if (u ~ /\[gc \(|\[gc /) return "Young GC"
  if (u ~ /concurrent cycle|concurrent mark|concurrent undo|concurrent rebuild/) return "Concurrent"
  if (has_failure(msg)) return "GC Failure"
  return "GC"
}
function is_detail(msg, tags,    u, t) {
  if (has_failure(msg)) return 0
  if (has_warning_event(msg)) return 0
  u = lower(msg)
  t = lower(tags)
  if (is_stw_text(msg) && measure_pause_ms(msg) >= 0) return 0
  if (u ~ /concurrent cycle [0-9]/) return 0
  if (u ~ /eden regions:|survivor regions:|old regions:|humongous regions:/) return 1
  if (u ~ /metaspace:|nonclass:|class space|gc workers|using worker/) return 1
  if (u ~ /user=[0-9].*sys=[0-9].*real=[0-9]/) return 1
  if (u ~ /heap region size|large page|cpus:|memory:|version:|parallel workers|times: user=/) return 1
  if (t ~ /(^|,)[[:space:]]*(phases|cpu|heap|metaspace|init|age|marking|task|mmu|stringtable|stats)([[:space:]]|,|$)/) {
    return 1
  }
  if (u ~ /:[[:space:]]*[0-9]+(\.[0-9]+)?ms$/ && is_stw_text(msg) == 0) return 1
  if (is_stw_text(msg) && measure_pause_ms(msg) < 0) return 1
  return 0
}
function classify(explicit, msg, pause_ms,    base) {
  base = explicit
  if (base == "") base = "INFO"
  if (has_failure(msg)) return "ERROR"
  if (base == "ERROR") return "ERROR"
  if (is_stw_text(msg) && pause_ms >= 0 && pause_error_ms > 0 && pause_ms >= pause_error_ms) {
    return "ERROR"
  }
  if (base == "WARN") return "WARN"
  if (has_warning_event(msg)) return "WARN"
  if (is_stw_text(msg) && pause_ms >= 0 && pause_warn_ms > 0 && pause_ms >= pause_warn_ms) {
    return "WARN"
  }
  return base
}
function accept_level(level,    i, n, x, list) {
  if (show_all == 1) return 1
  n = split(levels, list, /[[:space:],]+/)
  for (i = 1; i <= n; i++) {
    x = toupper(list[i])
    if (x == "WARNING") x = "WARN"
    if (x == "") continue
    if (x == level) return 1
  }
  return 0
}
function flush_record(container, service, task, kind, filename, filepath, \
    raw, n, i, body, cont, line, limit, omitted, note, level, \
    pause_ms, pause_txt, event, cause, gid, heap, analysis, sortkey) {
  if (buf == "") return
  raw = buf
  buf = ""
  n = split(raw, lines, "\n")
  if (parse_line(lines[1]) == 0) {
    unparsed++
    if (sample == "") sample = clip_sample(lines[1])
    return
  }
  records_seen++
  if (g_ts < reflect_key) return
  if (end_key != "" && g_ts > end_key) return
  records_in_time++
  body = g_msg
  cont = ""
  limit = n - 1
  omitted = g_omitted
  if (limit > max_cont) {
    omitted += limit - max_cont
    limit = max_cont
  }
  for (i = 2; i <= limit + 1; i++) {
    line = lines[i]
    if (body == "") body = line
    else body = body "\n" line
    line = sanitize(line)
    if (cont == "") cont = line
    else cont = cont "\036" line
  }
  if (omitted > 0) {
    note = sprintf("... 残り %d 行は省略しました (MAX_CONT=%d)", omitted, max_cont)
    if (cont == "") cont = note
    else cont = cont "\036" note
  }
  analysis = body
  if (g_tags != "") analysis = g_tags "\n" analysis
  pause_ms = -1
  if (is_stw_text(analysis)) pause_ms = measure_pause_ms(analysis)
  level = classify(g_explicit, analysis, pause_ms)
  if (accept_level(level) == 0) {
    level_excluded++
    return
  }
  if (detail_flag == 0 && level == "INFO" && is_detail(analysis, g_tags)) {
    detail_excluded++
    return
  }
  if (keyword != "" && index(raw, keyword) == 0) {
    keyword_excluded++
    return
  }
  shown++
  count[container SUBSEP service SUBSEP level]++
  extract_heap(analysis)
  heap = heap_text()
  cause = extract_cause(analysis)
  gid = extract_gc_id(analysis)
  event = event_kind(analysis)
  if (pause_ms >= 0) pause_txt = format_pause(pause_ms)
  else pause_txt = ""
  seq++
  sortkey = sprintf("%s|%s|%s|%s|%s|%08d", g_ts, container, service, task, filename, seq)
  printf "%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\n", \
    sortkey, sanitize(g_ts), sanitize(level), sanitize(container), sanitize(service), \
    sanitize(task), sanitize(kind), sanitize(filename), sanitize(filepath), \
    sanitize(event), sanitize(gid), sanitize(cause), sanitize(heap), sanitize(pause_txt), \
    sanitize(g_orig), clip_text(sanitize(g_show)), cont >> records
}
function start_record(line) {
  buf = line
  g_cont_n = 0
  g_omitted = 0
}
function append_cont(line) {
  g_cont_n++
  if (g_cont_n <= store_limit) buf = buf "\n" line
  else g_omitted++
}
function read_log(path, container, service, task, kind, filename,    line, err) {
  buf = ""
  g_cont_n = 0
  g_omitted = 0
  while (1) {
    err = (getline line < path)
    if (err == 0) break
    if (err < 0) {
      read_errors++
      flush_record(container, service, task, kind, filename, path)
      close(path)
      return
    }
    lines_read++
    sub(/\r$/, "", line)
    if (looks_like_ts(line) && parse_line(line)) {
      flush_record(container, service, task, kind, filename, path)
      start_record(line)
    } else if (buf != "") {
      append_cont(line)
    } else if (looks_like_ts(line)) {
      unparsed++
      if (sample == "") sample = clip_sample(line)
    }
  }
  close(path)
  flush_record(container, service, task, kind, filename, path)
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
  detail_flag = ENVIRON["DETAIL"] + 0
  max_cont = ENVIRON["MAX_CONT"] + 0
  max_line = ENVIRON["MAX_LINE"] + 0
  pause_warn_ms = ENVIRON["PAUSE_WARN_MS"] + 0
  pause_error_ms = ENVIRON["PAUSE_ERROR_MS"] + 0
  if (max_cont < 1) max_cont = 40
  if (max_line < 80) max_line = 2000
  store_limit = max_cont
  if (store_limit < 400) store_limit = 400
  buf = ""
  while ((getline line < manifest) > 0) {
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
  print "level_excluded\t" level_excluded + 0 > stats
  print "detail_excluded\t" detail_excluded + 0 > stats
  print "keyword_excluded\t" keyword_excluded + 0 > stats
  print "shown\t" shown + 0 > stats
  print "unparsed\t" unparsed + 0 > stats
  print "read_errors\t" read_errors + 0 > stats
  gsub(/\t/, " ", sample)
  print "sample\t" sample > stats
  for (k in count) {
    split(k, p, SUBSEP)
    print "count\t" p[1] "\t" p[2] "\t" p[3] "\t" count[k] > stats
  }
  close(stats)
  close(records)
}
EXTRACT_AWK

cat > "$format_awk" <<'FORMAT_AWK'
function is_err(level) {
  return level == "ERROR"
}
function bar_color(level) {
  if (level == "WARN") return c_bar_yel
  if (is_err(level)) return c_bar_red
  return c_dim
}
function body_color(level) {
  if (level == "WARN") return c_yel
  if (is_err(level)) return c_red
  return ""
}
function badge(level) {
  if (level == "WARN") return c_byel "[WARN]" c_rst
  if (is_err(level)) return c_bred "[ERROR]" c_rst
  if (level == "INFO") return c_dim "[INFO]" c_rst
  return c_dim "[" level "]" c_rst
}
function paint_plain(line,    s) {
  s = line
  if (c_rst == "") return s
  gsub(/OutOfMemoryError|Evacuation Failure|to-space exhausted/, \
    c_red "&" c_rst, s)
  gsub(/promotion failed|concurrent mode failure/, c_red "&" c_rst, s)
  gsub(/Pause Full|Full GC|System\.gc\(\)|Metadata GC Threshold/, \
    c_yel "&" c_rst, s)
  gsub(/Humongous Allocation|GCLocker/, c_yel "&" c_rst, s)
  gsub(/ERROR/, c_red "&" c_rst, s)
  gsub(/WARNING|WARN/, c_yel "&" c_rst, s)
  return s
}
function show_text(level, text) {
  if (is_err(level) || level == "WARN") return body_color(level) text c_rst
  return paint_plain(text)
}
function emit(level, text) {
  print bar_color(level) "| " c_rst text c_rst
}
function add_part(base, text) {
  if (text == "") return base
  if (base == "") return text
  return base "    " text
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
}
{
  level = $3
  ts = $2
  container = $4
  service = $5
  task = $6
  kind = $7
  filename = $8
  filepath = $9
  event = $10
  gid = $11
  cause = $12
  heap = $13
  pause = $14
  orig = $15
  message = $16
  cont = $17
  if (event == "GC") event = ""
  print ""
  print bar_color(level) "-------- #" NR " --------" c_rst
  headline = c_cya ts c_rst "  " badge(level)
  if (event != "") headline = headline "  " c_bld event c_rst
  if (pause != "") headline = headline "  停止 " c_bld pause c_rst
  if (heap != "") headline = headline "  ヒープ " heap
  headline = headline "  " c_grn container c_rst " / " c_blu service c_rst
  emit(level, headline)
  emit(level, "コンテナ: " c_grn container c_rst \
    "    ECSサービス: " c_blu service c_rst \
    "    種別: " c_bld kind c_rst \
    "    タスク: " c_bld task c_rst)
  meta = ""
  if (cause != "") meta = add_part(meta, "原因: " cause)
  if (gid != "") meta = add_part(meta, "GC番号: " gid)
  meta = add_part(meta, "ファイル: " filename)
  emit(level, meta)
  if (orig != "") emit(level, "元時刻: " orig "（表示時刻は JST）")
  emit(level, "パス: " c_dim filepath c_rst)
  if (message != "") emit(level, "ログ: " show_text(level, message))
  if (cont != "") {
    m = split(cont, stack, "\036")
    for (i = 1; i <= m; i++) {
      line = stack[i]
      if (line ~ /^[[:space:]]*$/) continue
      emit(level, show_text(level, "  " line))
    }
  }
}
END {
  if (NR == 0) {
    print ""
    print "該当するログはありません。"
    print ""
  }
}
FORMAT_AWK

echo "対象 ${#PATHS[@]} ファイルを読み込んでいます..." >&2
# END 規則のある awk は入力ファイルが無いと標準入力を読む。
# SSH へ貼り付けたスクリプト本体を読み込まないよう、標準入力を閉じる。
awk -f "$extract_awk" </dev/null
load_stats
if [[ "$SHOWN" -gt 0 ]]; then
  LC_ALL=C sort -t $'\034' -k1,1 -s -- "$records" \
    | awk -f "$format_awk"
else
  printf '\n%s\n\n' "該当するログはありません。"
fi
print_summary
EOS
