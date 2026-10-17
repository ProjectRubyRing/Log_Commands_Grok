#!/bin/bash
# JBoss EAP server.log を、反映時刻以降・JST の昇順で表示する。
# RHEL 9.8 の SSH 端末へ、このファイルの内容をそのまま貼り付けて実行する。
# 長い行は \ で折り返してある。\ の後ろに空白は入れない。
# 終端の EOS 行は消さない。

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
# 表示するレベル。SHOW_ALL=1 のときは、この指定を無視して全レベルを表示する。
LEVELS="ERROR WARN FATAL SEVERE EMERGENCY"
SHOW_ALL="0"
# 空ならレベル条件だけ。指定した文字列を含むレコードだけ残す（正規表現ではない）。
KEYWORD=""
BASE_DIR="/mnt/logs"
# 1 レコードあたり表示する継続行（スタックトレース）の上限。
MAX_STACK="80"
# 1 にすると、リダイレクト先でも色を付ける。
FORCE_COLOR="0"
# ======================================================

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

hr() {
  printf '%s\n' "=============================================================================="
}

thin() {
  printf '%s\n' "------------------------------------------------------------------------------"
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
  if [[ ! "$cleaned" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}(:[0-9]{2})?$ ]]; then
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
    level_text="全レベル（INFO なども含む）"
  else
    level_text="${LEVELS// /, }"
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
  hr
  printf '%s\n' " JBoss EAP server.log 検索"
  hr
  printf '%s\n' "  反映時刻 (JST) : ${REFLECT_NORM} 以降"
  printf '%s\n' "  終了時刻 (JST) : ${end_text}"
  printf '%s\n' "  コンテナ       : $(csv_join "${container_arr[@]}")"
  printf '%s\n' "  ECSサービス    : $(csv_join "${service_arr[@]}")"
  printf '%s\n' "  レベル         : ${level_text}"
  printf '%s\n' "  キーワード     : ${keyword_text}"
  printf '%s\n' "  基点           : ${BASE_DIR}"
  printf '%s\n' "  対象ファイル   : server.log, server.log.YYYY-MM-DD"
  printf '%s\n' "  表示順         : JST の昇順"
  printf '%s\n' "  色             : ${color_text}"
  printf '%s\n' "  ローテーション : 反映日の前日より古い日付ファイルは読まない"
  hr
}

print_file_list() {
  local i n shown_files limit key container service count path
  thin
  printf '%s\n' " 対象ファイル ${#PATHS[@]} 件"
  if [[ ${#PATHS[@]} -gt 0 ]]; then
    thin
    n=0
    limit=40
    shown_files=0
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
    printf '%s\n' "  読み飛ばした古いローテーション: ${SKIPPED} 件（反映日の前日より前）"
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
    printf '%s\n' " 古いローテーションだけで、反映時刻の範囲には入らないサービス:"
    for key in "${OLD_ONLY_PAIRS[@]}"; do
      IFS=$'\t' read -r container service path count <<< "$key"
      printf '%s\n' "  コンテナ: ${container}  ECSサービス: ${service}  読み飛ばし: ${count} 件"
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
  local key container service e w f sev em info debug trace total row
  local te=0 tw=0 tf=0 tsev=0 tem=0 tinfo=0
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
      f=$(count_of "${container}|${service}|FATAL")
      sev=$(count_of "${container}|${service}|SEVERE")
      em=$(count_of "${container}|${service}|EMERGENCY")
      info=$(count_of "${container}|${service}|INFO")
      debug=$(count_of "${container}|${service}|DEBUG")
      trace=$(count_of "${container}|${service}|TRACE")
      total=$((e + w + f + sev + em + info + debug + trace))
      te=$((te + e))
      tw=$((tw + w))
      tf=$((tf + f))
      tsev=$((tsev + sev))
      tem=$((tem + em))
      tinfo=$((tinfo + info))
      row="  コンテナ ${container} / ECSサービス ${service}  ERROR ${e}  WARN ${w}  FATAL ${f}  SEVERE ${sev}  EMERGENCY ${em}"
      if [[ "$SHOW_ALL" == "1" ]]; then
        row="${row}  INFO ${info}  DEBUG ${debug}  TRACE ${trace}"
      fi
      printf '%s\n' "${row}  合計 ${total}"
    done
  fi
  thin
  row="  合計  ERROR ${te}  WARN ${tw}  FATAL ${tf}  SEVERE ${tsev}  EMERGENCY ${tem}"
  if [[ "$SHOW_ALL" == "1" ]]; then
    row="${row}  INFO ${tinfo}"
  fi
  printf '%s\n' "${row}  表示 ${SHOWN}"
  printf '%s\n' "  読み込んだ行数     : ${LINES_READ}"
  printf '%s\n' "  ログレコード       : ${RECORDS_SEEN}"
  printf '%s\n' "  反映時刻の範囲内   : ${RECORDS_IN_TIME}"
  printf '%s\n' "  レベル条件で除外   : ${LEVEL_EXCLUDED}"
  printf '%s\n' "  キーワードで除外   : ${KEYWORD_EXCLUDED}"
  printf '%s\n' "  表示               : ${SHOWN}"
  printf '%s\n' "  レベル不明の時刻行 : ${UNPARSED}"
  if [[ "$UNPARSED" -gt 0 && -n "$SAMPLE" ]]; then
    if [[ ${#SAMPLE} -gt 180 ]]; then
      SAMPLE="${SAMPLE:0:180}..."
    fi
    printf '%s\n' "    例: ${SAMPLE}"
    printf '%s\n' "    想定: 2026-08-26 10:31:02,145 ERROR [category] (thread) message"
  fi
  if [[ "$READ_ERRORS" -gt 0 ]]; then
    printf '%s\n' "  読込エラー         : ${READ_ERRORS}"
  fi
  hr
}

add_file() {
  local path="$1" container="$2" service="$3" task="$4" is_current="$5"
  local base_name file_date real inode idx kind
  base_name=$(basename -- "$path")
  if [[ "$base_name" =~ ^server\.log\.([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then
    file_date="${BASH_REMATCH[1]}"
    if [[ "$file_date" < "$skip_before" ]]; then
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
    if [[ -n "$skip_after" && "$file_date" > "$skip_after" ]]; then
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi
  elif [[ "$base_name" != "server.log" ]]; then
    return 0
  fi
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  if [[ ! -r "$path" ]]; then
    UNREADABLE+=("$path")
    return 0
  fi
  if ! real=$(readlink -f -- "$path"); then
    return 0
  fi
  case "$real" in
    "$CURRENT_MID_REAL"/*) ;;
    *)
      OUTSIDE+=("${path} -> ${real}")
      return 0
      ;;
  esac
  if ! inode=$(stat -c '%d:%i' -- "$path"); then
    return 0
  fi
  if [[ "$is_current" == "1" ]]; then
    kind="current"
  else
    kind="task"
  fi
  if [[ -n "${INODE_INDEX[$inode]+x}" ]]; then
    idx=${INODE_INDEX[$inode]}
    if [[ "$is_current" == "1" ]]; then
      KINDS[$idx]="current"
    fi
    if [[ "$task" =~ ^[0-9A-Za-z]{32}$ ]]; then
      TASKS[$idx]=$task
    fi
    return 0
  fi
  idx=${#PATHS[@]}
  INODE_INDEX[$inode]=$idx
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
  local candidates=()
  candidates+=("${dir}/server.log")
  dated=("${dir}"/server.log.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
  if [[ ${#dated[@]} -gt 0 ]]; then
    candidates+=("${dated[@]}")
  fi
  for f in "${candidates[@]}"; do
    if [[ -e "$f" || -L "$f" ]]; then
      add_file "$f" "$container" "$service" "$task" "$is_current"
    fi
  done
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
    BROKEN+=("${mid}/current")
  elif [[ -d "${mid}/current" ]]; then
    scan_one_dir "${mid}/current" "$container" "$service" "-" "1"
  fi
  if [[ ${#PATHS[@]} -eq $before ]]; then
    if [[ "$SKIPPED" -gt "$skipped_before" ]]; then
      OLD_ONLY_PAIRS+=("${container}"$'\t'"${service}"$'\t'"${mid}"$'\t'"$((SKIPPED - skipped_before))")
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
if [[ ! "$MAX_STACK" =~ ^[0-9]+$ ]] || [[ "$MAX_STACK" -lt 1 ]]; then
  die "MAX_STACK は 1 以上の整数です。"
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

export REFLECT_KEY END_KEY LEVELS SHOW_ALL KEYWORD MAX_STACK

setup_color
print_banner

shopt -s nullglob
declare -A INODE_INDEX=()
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
  printf '\n%s\n\n' "該当するログはありません。読み込む server.log がありません。"
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
function to_jst(date, hms, ms, tz) {
  return shift_min(date, hms, pad_ms(ms), 540 - offset_minutes(tz))
}
function norm_level(level) {
  level = toupper(level)
  if (level == "WARNING") return "WARN"
  return level
}
function accept_level(level,    i, n, x, list) {
  if (show_all == 1) return 1
  n = split(levels, list, /[[:space:],]+/)
  for (i = 1; i <= n; i++) {
    x = norm_level(list[i])
    if (x == "") continue
    if (x == level) return 1
  }
  return 0
}
function is_ts(line) {
  return line ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}/
}
function parse_line(line,    ms) {
  if (match(line, ts_re, a) == 0) return 0
  ms = pad_ms(a[4])
  g_ts = to_jst(a[1], a[2], ms, a[6])
  g_level = a[8]
  g_rest = substr(line, RLENGTH + 1)
  sub(/^[[:space:]]+/, "", g_rest)
  gsub(/\034/, " ", g_rest)
  gsub(/\036/, " ", g_rest)
  return 1
}
function flush_record(container, service, task, kind, filename, filepath,    raw, n, i, level, cont, line, limit, omitted, sortkey, note) {
  if (buf == "") return
  raw = buf
  buf = ""
  n = split(raw, lines, "\n")
  if (parse_line(lines[1]) == 0) {
    unparsed++
    if (sample == "") sample = lines[1]
    return
  }
  records_seen++
  if (g_ts < reflect_key) return
  if (end_key != "" && g_ts > end_key) return
  records_in_time++
  level = norm_level(g_level)
  if (accept_level(level) == 0) {
    level_excluded++
    return
  }
  if (keyword != "" && index(raw, keyword) == 0) {
    keyword_excluded++
    return
  }
  shown++
  count[container SUBSEP service SUBSEP level]++
  cont = ""
  limit = n - 1
  omitted = g_omitted
  if (limit > max_stack) {
    omitted += limit - max_stack
    limit = max_stack
  }
  for (i = 2; i <= limit + 1; i++) {
    line = lines[i]
    gsub(/\034/, " ", line)
    gsub(/\036/, " ", line)
    if (cont == "") cont = line
    else cont = cont "\036" line
  }
  if (omitted > 0) {
    note = sprintf("... 残り %d 行は省略しました (MAX_STACK=%d)", omitted, max_stack)
    if (cont == "") cont = note
    else cont = cont "\036" note
  }
  seq++
  sortkey = sprintf("%s|%s|%s|%s|%s|%08d", g_ts, container, service, task, filename, seq)
  printf "%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\n", \
    sortkey, g_ts, level, container, service, task, kind, filename, filepath, g_rest, cont >> records
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
    if (is_ts(line)) {
      flush_record(container, service, task, kind, filename, path)
      start_record(line)
    } else if (buf != "") {
      append_cont(line)
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
  max_stack = ENVIRON["MAX_STACK"] + 0
  if (max_stack < 1) max_stack = 80
  store_limit = max_stack
  if (store_limit < 400) store_limit = 400
  ts_re = "^([0-9]{4}-[0-9]{2}-[0-9]{2})[ T]([0-9]{2}:[0-9]{2}:[0-9]{2})([,.]([0-9]{1,3}))?([[:space:]]*(Z|[+-][0-9]{2}:?[0-9]{2}|JST|UTC|GMT))?([[:space:]]+)(FATAL|SEVERE|EMERGENCY|ERROR|WARNING|WARN|INFO|DEBUG|TRACE)([^A-Za-z]|$)"
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
  return level == "ERROR" || level == "FATAL" || level == "SEVERE" || level == "EMERGENCY"
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
  if (is_err(level)) return c_bred "[" level "]" c_rst
  return c_dim "[" level "]" c_rst
}
function paint_plain(line,    s) {
  s = line
  if (c_rst == "") return s
  gsub(/EMERGENCY|SEVERE|FATAL|ERROR/, c_red "&" c_rst, s)
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
  rest = $10
  cont = $11
  print ""
  print bar_color(level) "-------- #" NR " --------" c_rst
  emit(level, c_cya ts c_rst "  " badge(level) "  " c_dim filename c_rst)
  emit(level, "コンテナ: " c_grn container c_rst "    ECSサービス: " c_blu service c_rst "    種別: " c_bld kind c_rst)
  emit(level, "タスク: " c_bld task c_rst)
  emit(level, "パス: " c_dim filepath c_rst)
  if (rest != "") emit(level, show_text(level, rest))
  if (cont != "") {
    m = split(cont, stack, "\036")
    for (i = 1; i <= m; i++) {
      line = stack[i]
      if (line ~ /^[[:space:]]*$/) continue
      sub(/^\t/, "", line)
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
