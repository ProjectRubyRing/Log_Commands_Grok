#!/bin/bash
# JBoss EAP の server.log / access_log / gc.log 検索結果が
# 入った Tera Term ログを読み、Excel レポート (.xlsx) を作る。
#
# 検索スクリプトの画面出力を、そのまま Tera Term のログに残してある
# 前提。ログをこのスクリプトへ渡すと、出力項目をヘッダにした
# 1 行 1 件の表にする。フォントは Meiryo UI、色は灰色だけ。
#
# RHEL 9.8 で実行する。python3 の標準ライブラリだけを使う。
# Windows 11 では jboss-eap-teraterm-log-report.ps1 を使う。
#   bash jboss-eap-teraterm-log-report.sh -o report.xlsx teraterm.log
#   bash jboss-eap-teraterm-log-report.sh -o report.xlsx ./logs
#
# 検索結果の見出しが無いときは、表紙だけ書いた xlsx を残して終了コード 2。

set -euo pipefail
umask 077

py=""
if command -v python3 >/dev/null 2>&1; then
  py=$(command -v python3)
elif [[ -x /usr/libexec/platform-python ]]; then
  py=/usr/libexec/platform-python
else
  printf '%s\n' "python3 が見つかりません。RHEL 9.8 では次で入れられます: sudo dnf install -y python3" >&2
  exit 1
fi

export PYTHONUTF8=1
exec "$py" - "$@" <<'PY'
import argparse
import math
import os
import re
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

KIND_ORDER = ("server", "access", "gc")
KIND_NAME = {
    "server": "server.log",
    "access": "access_log",
    "gc": "gc.log",
}
ERROR_WORDS = {"ERROR", "FATAL", "SEVERE", "EMERGENCY", "サーバエラー"}
WARN_WORDS = {"WARN", "WARNING", "警告"}
SERVER_METRICS = ["ERROR", "WARN", "FATAL", "SEVERE", "EMERGENCY", "INFO", "DEBUG", "TRACE"]
ACCESS_METRICS = ["エラー", "警告", "正常", "転送", "情報", "不明"]
GC_METRICS = ["エラー", "警告", "情報", "DEBUG", "TRACE"]
METRICS = {"server": SERVER_METRICS, "access": ACCESS_METRICS, "gc": GC_METRICS}

TITLE_RE = re.compile(r"^ JBoss EAP (server\.log|access_log|gc\.log) 検索$")
FIELD_RE = re.compile(r"^ {2}(.+?)\s+:\s(.*)$")
FILE_RE = re.compile(
    r"^ {2}(\d+)\. コンテナ: (\S+) {2}ECSサービス: (\S+) {2}種別: (\S+) {2}タスク: (.*)$"
)
NAME_RE = re.compile(r"^ {5}ファイル: (.*)$")
PATH_RE = re.compile(r"^ {5}パス: (.*)$")
MORE_RE = re.compile(r"^ {2}\.\.\. 他 (\d+) 件$")
SKIP_RE = re.compile(r"^ {2}読み飛ばした古いローテーション: (\d+) 件（(.*)）$")
COUNT_RE = re.compile(r"^ 対象ファイル (\d+) 件$")
PAIR_RE = re.compile(r"^ {2}コンテナ: (\S+) {2}ECSサービス: (\S+)$")
OLD_RE = re.compile(
    r"^ {2}コンテナ: (\S+) {2}ECSサービス: (\S+) {2}読み飛ばし: (\d+) 件$"
)
REC_RE = re.compile(r"^-------- #([0-9]+) --------$")
ACC_HEAD_RE = re.compile(r"^ アクセスログ (\d+) 件（JST の昇順）$")
NOISE_RE = re.compile(r"^対象 \d+ ファイルを.*読み込んでいます\.\.\.$")
SUM_RE = re.compile(r"^ {2}コンテナ (\S+) / ECSサービス (\S+) {2}(.+) {2}合計 (\d+)$")
TOTAL_RE = re.compile(r"^ {2}合計 {2}(.+) {2}表示 (\d+)$")
KV_RE = re.compile(r"^ {2,}(.+?)\s*:\s(.*)$")
HTTP_RE = re.compile(r"^ {4}HTTP (\S+) × (\d+)$")
LEVEL_RE = re.compile(r"^ {4}レベル (\S+) × (\d+)$")
METRIC_RE = re.compile(
    r"(EMERGENCY|SEVERE|ERROR|TRACE|DEBUG|FATAL|WARN|INFO|エラー|警告|正常|転送|情報|不明) (\d+)"
)
TS_PREFIX_RE = re.compile(
    r"^(?:"
    r"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d{1,3})?"
    r"|\[[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[.,]\d{1,3})?\]"
    r")[ \t]"
)
ANSI_RE = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"
    r"|\x1b\][^\x07]*(?:\x07|\x1b\\)"
    r"|\x1b[@-Z\\-_]"
    r"|\x1b\([ -~]"
)
ISSUE_HEADERS = {
    "ディレクトリなし:": "ディレクトリなし",
    "ログファイルなし:": "ログファイルなし",
    "古いローテーションだけで、反映時刻の範囲には入らないサービス:": "古いローテーションのみ",
    "読めないパス:": "読めないパス",
    "切れたシンボリックリンク:": "切れたシンボリックリンク",
    "基点の外を指していたため除外:": "基点の外",
}
CLASS_BY_LABEL = {
    "サーバエラー": "ERROR",
    "警告": "WARN",
    "正常": "OK",
    "転送": "REDIRECT",
    "情報": "INFO",
    "不明": "UNKNOWN",
}

# name, align, wrap, number, width
SERVER_COLS = [
    ("No", "center", False, True, 8),
    ("時刻 (JST)", "left", False, False, 23),
    ("レベル", "center", False, False, 14),
    ("コンテナ", "center", False, False, 14),
    ("ECSサービス", "center", False, False, 16),
    ("種別", "center", False, False, 12),
    ("タスク", "left", False, False, 36),
    ("ファイル", "left", False, False, 28),
    ("パス", "left", True, False, 64),
    ("メッセージ", "left", True, False, 78),
    ("スタックトレース", "left", True, False, 78),
]
ACCESS_COLS = [
    ("No", "center", False, True, 8),
    ("時刻 (JST)", "left", False, False, 23),
    ("区分", "center", False, False, 14),
    ("HTTPステータス", "center", False, True, 16),
    ("レベル", "center", False, False, 12),
    ("コンテナ", "center", False, False, 14),
    ("ECSサービス", "center", False, False, 16),
    ("種別", "center", False, False, 12),
    ("タスク", "left", False, False, 36),
    ("メソッド", "center", False, False, 12),
    ("URI", "left", True, False, 64),
    ("プロトコル", "center", False, False, 14),
    ("メッセージ", "left", True, False, 56),
    ("クライアント", "left", False, False, 18),
    ("ユーザ", "left", False, False, 16),
    ("応答バイト", "right", False, True, 14),
    ("処理時間", "right", False, False, 14),
    ("Referer", "left", True, False, 42),
    ("UA", "left", True, False, 42),
    ("追加", "left", True, False, 36),
    ("元の時刻", "left", False, False, 28),
    ("ファイル", "left", False, False, 28),
    ("パス", "left", True, False, 64),
    ("生ログ", "left", True, False, 64),
]
GC_COLS = [
    ("No", "center", False, True, 8),
    ("時刻 (JST)", "left", False, False, 23),
    ("レベル", "center", False, False, 12),
    ("イベント", "center", False, False, 16),
    ("停止", "right", False, False, 12),
    ("ヒープ", "left", False, False, 34),
    ("コンテナ", "center", False, False, 14),
    ("ECSサービス", "center", False, False, 16),
    ("種別", "center", False, False, 12),
    ("タスク", "left", False, False, 36),
    ("原因", "left", True, False, 28),
    ("GC番号", "center", False, True, 12),
    ("ファイル", "left", False, False, 22),
    ("元時刻", "left", False, False, 36),
    ("パス", "left", True, False, 64),
    ("ログ", "left", True, False, 72),
    ("継続行", "left", True, False, 72),
]
COLS = {"server": SERVER_COLS, "access": ACCESS_COLS, "gc": GC_COLS}
EXTRA_COLS = [
    ("実行", "center", False, True, 8),
    ("入力ファイル", "left", False, False, 32),
]
LONG_TEXT = 32000


def die(message, code=1):
    print(message, file=sys.stderr)
    raise SystemExit(code)


def clean_text(value):
    if value is None:
        return ""
    out = []
    for ch in str(value):
        code = ord(ch)
        if code in (9, 10) or code >= 32:
            if code not in (0xFFFE, 0xFFFF) and not (0xD800 <= code <= 0xDFFF):
                out.append(ch)
    text = "".join(out)
    if len(text) > LONG_TEXT:
        text = text[:LONG_TEXT] + "...（Excelのセル上限のため省略）"
    return text


def decode_bytes(data):
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8"), "utf-8"
    if data.startswith(b"\xff\xfe"):
        return data[2:].decode("utf-16-le"), "utf-16-le"
    if data.startswith(b"\xfe\xff"):
        return data[2:].decode("utf-16-be"), "utf-16-be"
    if data[:200].count(b"\x00") > 8:
        try:
            return data.decode("utf-16"), "utf-16"
        except UnicodeDecodeError:
            pass
    try:
        return data.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        pass
    cp = None
    try:
        cp = data.decode("cp932")
    except UnicodeDecodeError:
        cp = data.decode("cp932", errors="replace")
    replaced = data.decode("utf-8", errors="replace")
    if "JBoss EAP" in cp or "検索" in cp:
        if "JBoss EAP" not in replaced and "検索" not in replaced:
            return cp, "cp932"
    if replaced.count("\ufffd") > cp.count("\ufffd"):
        return cp, "cp932"
    return replaced, "utf-8"


def strip_timestamp_prefix(line):
    # Tera Term の「時刻を付ける」は、出力の各行の先頭に時刻を足す。
    match = TS_PREFIX_RE.match(line)
    if not match:
        return line
    return line[match.end():]


def normalize(text):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    text = ANSI_RE.sub("", text)
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", text)
    lines = []
    for line in text.split("\n"):
        lines.append(strip_timestamp_prefix(line.rstrip()))
    if lines and lines[0].startswith("\ufeff"):
        lines[0] = lines[0].lstrip("\ufeff")
    return lines


def is_hr(line):
    return len(line) >= 20 and set(line) == {"="}


def is_thin(line):
    return len(line) >= 20 and set(line) == {"-"}


def kind_of_title(title):
    match = TITLE_RE.match(title)
    if not match:
        return None
    name = match.group(1)
    if name == "server.log":
        return "server"
    if name == "access_log":
        return "access"
    return "gc"


def blank_issue():
    return {"区分": "", "コンテナ": "", "ECSサービス": "", "内容": "", "パス": ""}


def parse_metrics(text):
    found = {}
    for name, count in METRIC_RE.findall(text):
        found[name] = int(count)
    return found


def parse_preface(lines):
    files = []
    issues = []
    notes = []
    declared = None
    header_count = None
    idx = 0
    while idx < len(lines) and not lines[idx].startswith(" 対象ファイル "):
        idx += 1
    if idx == len(lines):
        for line in lines:
            if is_hr(line) or is_thin(line) or line == "" or NOISE_RE.match(line):
                continue
            notes.append(line.strip())
        return files, issues, notes, declared, header_count

    count_match = COUNT_RE.match(lines[idx])
    if count_match:
        declared = int(count_match.group(1))
    idx += 1
    current = None
    section = None
    pending = None
    while idx < len(lines) and not is_hr(lines[idx]):
        line = lines[idx]
        idx += 1
        if line == "" or is_thin(line):
            continue
        match = FILE_RE.match(line)
        if match:
            current = {
                "No": int(match.group(1)),
                "コンテナ": match.group(2),
                "ECSサービス": match.group(3),
                "種別": match.group(4),
                "タスク": match.group(5),
                "ファイル": "",
                "パス": "",
            }
            files.append(current)
            section = None
            pending = None
            continue
        match = NAME_RE.match(line)
        if match and current is not None and section is None:
            current["ファイル"] = match.group(1)
            continue
        match = PATH_RE.match(line)
        if match and current is not None and section is None:
            current["パス"] = match.group(1)
            continue
        match = MORE_RE.match(line)
        if match:
            item = blank_issue()
            item["区分"] = "対象ファイルの省略"
            item["内容"] = "他 %s 件は、このログには出ていません" % match.group(1)
            issues.append(item)
            continue
        match = SKIP_RE.match(line)
        if match:
            item = blank_issue()
            item["区分"] = "読み飛ばした古いローテーション"
            item["内容"] = "%s 件（%s）" % (match.group(1), match.group(2))
            issues.append(item)
            continue
        stripped = line.strip()
        if stripped in ISSUE_HEADERS:
            section = ISSUE_HEADERS[stripped]
            current = None
            pending = None
            continue
        if section == "ログファイルなし":
            match = PAIR_RE.match(line)
            if match:
                pending = blank_issue()
                pending["区分"] = section
                pending["コンテナ"] = match.group(1)
                pending["ECSサービス"] = match.group(2)
                continue
            if pending is not None and line.startswith("  "):
                pending["パス"] = line.strip()
                issues.append(pending)
                pending = None
                continue
        if section == "古いローテーションのみ":
            match = OLD_RE.match(line)
            if match:
                pending = blank_issue()
                pending["区分"] = section
                pending["コンテナ"] = match.group(1)
                pending["ECSサービス"] = match.group(2)
                pending["内容"] = "読み飛ばし %s 件" % match.group(3)
                continue
            if pending is not None and line.startswith("  "):
                pending["パス"] = line.strip()
                issues.append(pending)
                pending = None
                continue
        if section and line.startswith("  "):
            item = blank_issue()
            item["区分"] = section
            item["パス"] = line.strip()
            issues.append(item)
            continue
        if stripped and not NOISE_RE.match(stripped):
            notes.append(stripped)
    if idx < len(lines) and is_hr(lines[idx]):
        idx += 1
    while idx < len(lines):
        line = lines[idx]
        idx += 1
        if line == "" or is_hr(line) or is_thin(line) or NOISE_RE.match(line):
            continue
        match = ACC_HEAD_RE.match(line)
        if match:
            header_count = int(match.group(1))
            continue
        notes.append(line.strip())
    if declared is not None:
        omitted = 0
        for item in issues:
            if item["区分"] == "対象ファイルの省略":
                number = re.search(r"(\d+)", item["内容"])
                if number:
                    omitted = int(number.group(1))
        if len(files) + omitted != declared:
            item = blank_issue()
            item["区分"] = "対象ファイル件数"
            item["内容"] = "見出しは %s 件、読み取れた一覧は %s 件" % (declared, len(files))
            issues.append(item)
    return files, issues, notes, declared, header_count


def parse_summary(lines):
    rows = []
    total = None
    stats = []
    statuses = []
    notes = []
    idx = 0
    while idx < len(lines) and not lines[idx].startswith(" 件数（コンテナ"):
        idx += 1
    if idx == len(lines):
        return rows, total, stats, statuses, notes
    idx += 1
    while idx < len(lines) and not is_hr(lines[idx]):
        line = lines[idx]
        idx += 1
        if line == "" or is_thin(line):
            continue
        match = SUM_RE.match(line)
        if match:
            item = parse_metrics(match.group(3))
            item["コンテナ"] = match.group(1)
            item["ECSサービス"] = match.group(2)
            item["合計"] = int(match.group(4))
            rows.append(item)
            continue
        match = TOTAL_RE.match(line)
        if match:
            total = parse_metrics(match.group(1))
            total["コンテナ"] = "合計"
            total["ECSサービス"] = ""
            total["表示"] = int(match.group(2))
            present = [total[name] for name in total if isinstance(total[name], int) and name != "表示"]
            total["合計"] = sum(present) if present else 0
            continue
        match = HTTP_RE.match(line)
        if match:
            statuses.append(("HTTP", match.group(1), int(match.group(2))))
            continue
        match = LEVEL_RE.match(line)
        if match:
            statuses.append(("レベル", match.group(1), int(match.group(2))))
            continue
        stripped = line.strip()
        if stripped in ("ステータス内訳",):
            continue
        if stripped == "集計するファイルがありません。":
            notes.append(stripped)
            continue
        match = KV_RE.match(line)
        if match:
            stats.append((match.group(1).strip(), match.group(2).strip()))
            continue
        if stripped:
            notes.append(stripped)
    return rows, total, stats, statuses, notes


def empty_record(columns):
    return {name: "" for name, _align, _wrap, _num, _width in columns}


def parse_server_body(body):
    record = empty_record(SERVER_COLS)
    if len(body) < 4:
        record["メッセージ"] = "\n".join(body)
        return record, "server.log の明細が4行未満です"
    head, meta, task, path = body[0], body[1], body[2], body[3]
    head_m = re.match(
        r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) {2}\[([A-Za-z]+)\] {2}(.*)$",
        head,
    )
    meta_m = re.match(r"^コンテナ: (\S+)\s{2,}ECSサービス: (\S+)\s{2,}種別: (\S+)$", meta)
    task_m = re.match(r"^タスク: (.*)$", task)
    path_m = re.match(r"^パス: (.*)$", path)
    if not (head_m and meta_m and task_m and path_m):
        record["メッセージ"] = "\n".join(body)
        return record, "server.log の明細の並びを読めませんでした"
    record["時刻 (JST)"] = head_m.group(1)
    record["レベル"] = head_m.group(2)
    record["ファイル"] = head_m.group(3).strip()
    record["コンテナ"] = meta_m.group(1)
    record["ECSサービス"] = meta_m.group(2)
    record["種別"] = meta_m.group(3)
    record["タスク"] = task_m.group(1)
    record["パス"] = path_m.group(1)
    messages = []
    stacks = []
    for line in body[4:]:
        if line.startswith("  "):
            stacks.append(line[2:])
        else:
            messages.append(line)
    record["メッセージ"] = "\n".join(messages)
    record["スタックトレース"] = "\n".join(stacks)
    return record, None


def parse_request_line(line, record):
    proto = ""
    match = re.match(r"^(.*) {2}(HTTP/[0-9.]+)$", line)
    if match:
        line = match.group(1)
        proto = match.group(2)
    method_m = re.match(
        r"^(GET|HEAD|POST|PUT|DELETE|CONNECT|OPTIONS|TRACE|PATCH)(?: {2}(.*))?$",
        line,
    )
    if method_m:
        record["メソッド"] = method_m.group(1)
        record["URI"] = method_m.group(2) or ""
    else:
        record["URI"] = line
    record["プロトコル"] = proto


def is_request_line(line):
    if re.match(r"^(GET|HEAD|POST|PUT|DELETE|CONNECT|OPTIONS|TRACE|PATCH)( {2}|$)", line):
        return True
    if re.search(r" {2}HTTP/[0-9.]+$", line):
        return True
    if line.startswith("/") or line.startswith("http://") or line.startswith("https://"):
        return True
    return False


def is_bits_line(line):
    parts = re.split(r" {4}", line)
    keys = ("クライアント: ", "ユーザ: ", "応答バイト: ", "処理時間: ")
    if not parts:
        return False
    return all(any(part.startswith(key) for key in keys) for part in parts)


def parse_bits(line, record):
    for part in re.split(r" {4}", line):
        if part.startswith("クライアント: "):
            record["クライアント"] = part[len("クライアント: "):]
        elif part.startswith("ユーザ: "):
            record["ユーザ"] = part[len("ユーザ: "):]
        elif part.startswith("応答バイト: "):
            record["応答バイト"] = part[len("応答バイト: "):]
        elif part.startswith("処理時間: "):
            record["処理時間"] = part[len("処理時間: "):]


def parse_access_body(body):
    record = empty_record(ACCESS_COLS)
    if len(body) < 2:
        record["メッセージ"] = "\n".join(body)
        return record, "access_log の明細が2行未満です"
    parts = re.split(r" {2,}", body[0])
    meta_m = re.match(r"^種別: (\S+)\s{2,}タスク: (.*)$", body[1])
    if len(parts) < 4 or not meta_m:
        record["メッセージ"] = "\n".join(body)
        return record, "access_log の明細の並びを読めませんでした"
    ts, badge, pair, label = parts[0], parts[1], parts[2], parts[3]
    pair_m = re.match(r"^(\S+) / (\S+)$", pair)
    ts_m = re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$", ts)
    if not (pair_m and ts_m and label in CLASS_BY_LABEL):
        record["メッセージ"] = "\n".join(body)
        return record, "access_log の見出し行を読めませんでした"
    record["時刻 (JST)"] = ts
    record["区分"] = label
    record["コンテナ"] = pair_m.group(1)
    record["ECSサービス"] = pair_m.group(2)
    http_m = re.match(r"^\[HTTP ([1-5][0-9]{2})\]$", badge)
    level_m = re.match(r"^\[([A-Za-z]+)\]$", badge)
    if http_m:
        record["HTTPステータス"] = http_m.group(1)
    elif level_m and level_m.group(1) != "不明":
        record["レベル"] = level_m.group(1)
    record["種別"] = meta_m.group(1)
    record["タスク"] = meta_m.group(2)
    unlabeled = []
    for line in body[2:]:
        if line.startswith("Referer: "):
            record["Referer"] = line[len("Referer: "):]
        elif line.startswith("UA: "):
            record["UA"] = line[len("UA: "):]
        elif line.startswith("追加: "):
            record["追加"] = line[len("追加: "):]
        elif line.startswith("元の時刻: "):
            record["元の時刻"] = line[len("元の時刻: "):]
        elif line.startswith("ファイル: "):
            record["ファイル"] = line[len("ファイル: "):]
        elif line.startswith("パス: "):
            record["パス"] = line[len("パス: "):]
        elif line.startswith("生ログ: "):
            record["生ログ"] = line[len("生ログ: "):]
        elif is_bits_line(line):
            parse_bits(line, record)
        else:
            unlabeled.append(line)
    for line in unlabeled:
        if record["メソッド"] == "" and record["URI"] == "" and is_request_line(line):
            parse_request_line(line, record)
        elif record["メッセージ"] == "":
            record["メッセージ"] = line
        else:
            record["メッセージ"] = record["メッセージ"] + "\n" + line
    return record, None


def parse_gc_meta(line, record):
    for part in re.split(r" {4}", line):
        if part.startswith("原因: "):
            record["原因"] = part[len("原因: "):]
        elif part.startswith("GC番号: "):
            record["GC番号"] = part[len("GC番号: "):]
        elif part.startswith("ファイル: "):
            record["ファイル"] = part[len("ファイル: "):]


def parse_gc_body(body):
    record = empty_record(GC_COLS)
    if not body:
        return record, "gc.log の明細が空です"
    parts = re.split(r" {2,}", body[0])
    if len(parts) < 3:
        record["ログ"] = "\n".join(body)
        return record, "gc.log の見出し行を読めませんでした"
    ts = parts[0]
    badge = parts[1]
    pair = parts[-1]
    ts_m = re.match(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$", ts)
    badge_m = re.match(r"^\[([A-Za-z]+)\]$", badge)
    pair_m = re.match(r"^(\S+) / (\S+)$", pair)
    if not (ts_m and badge_m and pair_m):
        record["ログ"] = "\n".join(body)
        return record, "gc.log の見出し行を読めませんでした"
    record["時刻 (JST)"] = ts
    record["レベル"] = badge_m.group(1)
    record["コンテナ"] = pair_m.group(1)
    record["ECSサービス"] = pair_m.group(2)
    for token in parts[2:-1]:
        if token.startswith("停止 "):
            record["停止"] = token[len("停止 "):]
        elif token.startswith("ヒープ "):
            record["ヒープ"] = token[len("ヒープ "):]
        elif record["イベント"] == "":
            record["イベント"] = token
        else:
            record["イベント"] = record["イベント"] + " " + token
    cont = []
    for line in body[1:]:
        if re.match(r"^コンテナ: \S+\s{2,}ECSサービス: ", line):
            meta_m = re.match(
                r"^コンテナ: (\S+)\s{2,}ECSサービス: (\S+)\s{2,}種別: (\S+)\s{2,}タスク: (.*)$",
                line,
            )
            if meta_m:
                record["コンテナ"] = meta_m.group(1)
                record["ECSサービス"] = meta_m.group(2)
                record["種別"] = meta_m.group(3)
                record["タスク"] = meta_m.group(4)
            continue
        if (
            line.startswith("原因: ")
            or line.startswith("GC番号: ")
            or line.startswith("ファイル: ")
            or "    ファイル: " in line
            or "    原因: " in line
            or "    GC番号: " in line
        ):
            parse_gc_meta(line, record)
            continue
        if line.startswith("元時刻: "):
            record["元時刻"] = line[len("元時刻: "):]
            continue
        if line.startswith("パス: "):
            record["パス"] = line[len("パス: "):]
            continue
        if line.startswith("ログ: "):
            record["ログ"] = line[len("ログ: "):]
            continue
        if line.startswith("  "):
            cont.append(line[2:])
            continue
        if record["ログ"] == "":
            record["ログ"] = line
        else:
            cont.append(line)
    record["継続行"] = "\n".join(cont)
    return record, None


PARSERS = {
    "server": parse_server_body,
    "access": parse_access_body,
    "gc": parse_gc_body,
}


def collect_body(lines, index, end):
    body = []
    while index < end:
        line = lines[index]
        if REC_RE.match(line) or line.startswith(" 件数（コンテナ"):
            break
        if is_hr(line):
            nxt = index + 1
            while nxt < end and lines[nxt] == "":
                nxt += 1
            if nxt < end and lines[nxt].startswith(" 件数（コンテナ"):
                break
            index += 1
            continue
        if line == "" or NOISE_RE.match(line):
            index += 1
            continue
        if line.startswith("| "):
            body.append(line[2:])
        elif line == "|":
            body.append("")
        elif body:
            body[-1] = body[-1] + line.strip()
        index += 1
        continue
    return body, index


def parse_report(lines, start, end, source_name, run):
    kind = kind_of_title(lines[start + 1])
    report = {
        "kind": kind,
        "source": source_name,
        "run": run,
        "conditions": [],
        "declared_files": None,
        "files": [],
        "issues": [],
        "notes": [],
        "warnings": [],
        "records": [],
        "summary_rows": [],
        "summary_total": None,
        "stats": [],
        "statuses": [],
        "header_count": None,
    }
    idx = start + 3
    while idx < end and not is_hr(lines[idx]):
        match = FIELD_RE.match(lines[idx])
        if match:
            report["conditions"].append((match.group(1).strip(), match.group(2).strip()))
        idx += 1
    if idx < end and is_hr(lines[idx]):
        idx += 1
    preface_end = idx
    while preface_end < end:
        if REC_RE.match(lines[preface_end]) or lines[preface_end].startswith(" 件数（コンテナ"):
            break
        preface_end += 1
    files, issues, notes, declared, header_count = parse_preface(lines[idx:preface_end])
    report["files"] = files
    report["issues"] = issues
    report["notes"] = notes
    report["declared_files"] = declared
    report["header_count"] = header_count
    idx = preface_end
    while idx < end and not lines[idx].startswith(" 件数（コンテナ"):
        match = REC_RE.match(lines[idx])
        if match:
            number = int(match.group(1))
            body, idx = collect_body(lines, idx + 1, end)
            record, warning = PARSERS[kind](body)
            record["No"] = number
            record["実行"] = run
            record["入力ファイル"] = source_name
            report["records"].append(record)
            if warning:
                report["warnings"].append("#%s %s" % (number, warning))
            continue
        idx += 1
    rows, total, stats, statuses, summary_notes = parse_summary(lines[idx:end])
    report["summary_rows"] = rows
    report["summary_total"] = total
    report["stats"] = stats
    report["statuses"] = statuses
    report["notes"].extend(summary_notes)
    if header_count is not None and header_count != len(report["records"]):
        report["warnings"].append(
            "アクセスログ見出しは %s 件、読み取った明細は %s 件です"
            % (header_count, len(report["records"]))
        )
    return report


def find_reports(lines, source_name, counters):
    starts = []
    for index in range(len(lines) - 2):
        if is_hr(lines[index]) and TITLE_RE.match(lines[index + 1]) and is_hr(lines[index + 2]):
            starts.append(index)
    reports = []
    for pos, start in enumerate(starts):
        end = starts[pos + 1] if pos + 1 < len(starts) else len(lines)
        kind = kind_of_title(lines[start + 1])
        counters[kind] += 1
        reports.append(parse_report(lines, start, end, source_name, counters[kind]))
    return reports


def source_label(path, paths):
    same = [item for item in paths if item.name == path.name]
    if len(same) > 1:
        return path.parent.name + "/" + path.name
    return path.name


def expand_inputs(raw_paths):
    found = []
    for raw in raw_paths:
        path = Path(raw)
        if path.is_dir():
            children = sorted(
                [item for item in path.iterdir() if item.is_file() and item.suffix.lower() in (".log", ".txt")]
            )
            if not children:
                die("ログファイルがありません: %s" % path)
            found.extend(children)
        elif path.is_file():
            if path.suffix.lower() == ".xlsx":
                die("xlsx は入力にできません: %s" % path)
            found.append(path)
        else:
            die("見つかりません: %s" % path)
    if not found:
        die("ログファイルを指定してください。")
    return found


def load_sources(paths):
    sources = []
    counters = {kind: 0 for kind in KIND_ORDER}
    for path in paths:
        data = path.read_bytes()
        text, encoding = decode_bytes(data)
        label = source_label(path, paths)
        lines = normalize(text)
        reports = find_reports(lines, label, counters)
        sources.append({
            "path": path,
            "label": label,
            "encoding": encoding,
            "size": len(data),
            "reports": reports,
        })
    return sources


def condition_value(report, label):
    for key, value in report["conditions"]:
        if key == label:
            return value
    return ""


def severity(kind, record):
    word = record.get("区分", "") if kind == "access" else record.get("レベル", "")
    if word in ERROR_WORDS:
        return "error"
    if word in WARN_WORDS:
        return "warn"
    return "normal"


def count_severity(kind, records, level):
    return sum(1 for record in records if severity(kind, record) == level)


def needs_extra(reports):
    if len(reports) > 1:
        return True
    sources = {report["source"] for report in reports}
    return len(sources) > 1


def detail_columns(kind, extra):
    cols = list(COLS[kind])
    if extra:
        cols = [cols[0]] + list(EXTRA_COLS) + cols[1:]
    return cols


def col_letter(number):
    letters = ""
    while number:
        number, rem = divmod(number - 1, 26)
        letters = chr(65 + rem) + letters
    return letters


def row_height(values, columns):
    lines = 1
    for value, column in zip(values, columns):
        _name, _align, wrap, _num, width = column
        if not wrap or value is None or value == "":
            continue
        needed = 0
        for part in str(value).split("\n"):
            weight = 0
            for ch in part:
                weight += 2 if ord(ch) > 127 else 1
            needed += max(1, int(math.ceil(weight / float(max(width - 1, 4)))))
        lines = max(lines, needed)
    return min(120, max(18, lines * 15))


class StyleBook(object):
    def __init__(self):
        self.fonts = []
        self.fills = [("none", None), ("gray125", None)]
        self.borders = ["none"]
        self.xfs = []
        self.font_cache = {}
        self.fill_cache = {}
        self.border_cache = {"none": 0}
        self.xf_cache = {}
        self._add_font(10, False, "FF1F1F1F", False)
        self._add_fill(None)
        self.xfs.append(self._xf(0, 0, 0, "left", "center", False, 0, False))

    def _add_font(self, size, bold, color, italic):
        key = (size, bold, color, italic)
        if key in self.font_cache:
            return self.font_cache[key]
        index = len(self.fonts)
        self.fonts.append(key)
        self.font_cache[key] = index
        return index

    def _add_fill(self, rgb):
        key = rgb or ""
        if key in self.fill_cache:
            return self.fill_cache[key]
        if rgb is None and len(self.fills) > 2:
            index = 0
        else:
            index = len(self.fills)
            self.fills.append(("solid" if rgb else "none", rgb))
        self.fill_cache[key] = index
        return index

    def _add_border(self, kind):
        if kind in self.border_cache:
            return self.border_cache[kind]
        index = len(self.borders)
        self.borders.append(kind)
        self.border_cache[kind] = index
        return index

    def _xf(self, font_id, fill_id, border_id, align, valign, wrap, num, apply_num):
        return (font_id, fill_id, border_id, align, valign, wrap, num, apply_num)

    def style(self, size=10, bold=False, color="FF1F1F1F", fill=None, border="thin",
              align="left", valign="center", wrap=False, num=0, italic=False):
        key = (size, bold, color, fill, border, align, valign, wrap, num, italic)
        if key in self.xf_cache:
            return self.xf_cache[key]
        font_id = self._add_font(size, bold, color, italic)
        fill_id = self._add_fill(fill)
        border_id = self._add_border(border)
        index = len(self.xfs)
        self.xfs.append(self._xf(font_id, fill_id, border_id, align, valign, wrap, num, num != 0))
        self.xf_cache[key] = index
        return index

    def xml(self):
        font_xml = []
        for size, bold, color, italic in self.fonts:
            parts = ["<sz val=\"%s\"/>" % size, "<color rgb=\"%s\"/>" % color]
            if bold:
                parts.insert(0, "<b/>")
            if italic:
                parts.append("<i/>")
            parts.append("<name val=\"Meiryo UI\"/>")
            parts.append("<family val=\"2\"/>")
            parts.append("<charset val=\"128\"/>")
            font_xml.append("<font>%s</font>" % "".join(parts))
        fill_xml = []
        for pattern, rgb in self.fills:
            if pattern == "gray125":
                fill_xml.append("<fill><patternFill patternType=\"gray125\"/></fill>")
            elif pattern == "solid" and rgb:
                fill_xml.append(
                    "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"%s\"/>"
                    "<bgColor indexed=\"64\"/></patternFill></fill>" % rgb
                )
            else:
                fill_xml.append("<fill><patternFill patternType=\"none\"/></fill>")
        border_xml = []
        for kind in self.borders:
            if kind == "none":
                border_xml.append("<border><left/><right/><top/><bottom/><diagonal/></border>")
            elif kind == "header":
                color = "<color rgb=\"FFB5B5B5\"/>"
                bottom = "<color rgb=\"FF4A4A4A\"/>"
                border_xml.append(
                    "<border><left style=\"thin\">%s</left><right style=\"thin\">%s</right>"
                    "<top style=\"thin\">%s</top><bottom style=\"medium\">%s</bottom><diagonal/></border>"
                    % (color, color, color, bottom)
                )
            else:
                color = "<color rgb=\"FFB5B5B5\"/>"
                border_xml.append(
                    "<border><left style=\"thin\">%s</left><right style=\"thin\">%s</right>"
                    "<top style=\"thin\">%s</top><bottom style=\"thin\">%s</bottom><diagonal/></border>"
                    % (color, color, color, color)
                )
        xf_xml = []
        for font_id, fill_id, border_id, align, valign, wrap, num, apply_num in self.xfs:
            apply_font = 1 if font_id else 1
            apply_fill = 1 if fill_id else 0
            apply_border = 1 if border_id else 0
            align_xml = (
                "<alignment horizontal=\"%s\" vertical=\"%s\" wrapText=\"%d\"/>"
                % (align, valign, 1 if wrap else 0)
            )
            xf_xml.append(
                "<xf numFmtId=\"%d\" fontId=\"%d\" fillId=\"%d\" borderId=\"%d\" xfId=\"0\" "
                "applyFont=\"%d\" applyFill=\"%d\" applyBorder=\"%d\" applyAlignment=\"1\" "
                "applyNumberFormat=\"%d\">%s</xf>"
                % (num, font_id, fill_id, border_id, apply_font, apply_fill, apply_border,
                   1 if apply_num else 0, align_xml)
            )
        return (
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            "<fonts count=\"%d\">%s</fonts>"
            "<fills count=\"%d\">%s</fills>"
            "<borders count=\"%d\">%s</borders>"
            "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
            "<cellXfs count=\"%d\">%s</cellXfs>"
            "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
            "</styleSheet>"
            % (
                len(self.fonts), "".join(font_xml),
                len(self.fills), "".join(fill_xml),
                len(self.borders), "".join(border_xml),
                len(self.xfs), "".join(xf_xml),
            )
        )


def needs_preserve(text):
    if text is None:
        return False
    value = str(text)
    return (
        value.startswith(" ")
        or value.endswith(" ")
        or "\n" in value
        or "  " in value
    )


def cell_xml(ref, value, style, numeric):
    if numeric and value != "" and value is not None:
        return "<c r=\"%s\" s=\"%d\"><v>%s</v></c>" % (ref, style, int(value))
    if value is None or value == "":
        return "<c r=\"%s\" s=\"%d\"/>" % (ref, style)
    text = clean_text(value)
    space = " xml:space=\"preserve\"" if needs_preserve(text) else ""
    escaped = xml_escape(text).replace("\n", "&#10;")
    return "<c r=\"%s\" t=\"inlineStr\" s=\"%d\"><is><t%s>%s</t></is></c>" % (ref, style, space, escaped)


def sheet_xml(sheet, selected):
    cols = []
    for index, width in enumerate(sheet["widths"], 1):
        cols.append("<col min=\"%d\" max=\"%d\" width=\"%s\" customWidth=\"1\"/>" % (index, index, width))
    rows = []
    for r_index, row in enumerate(sheet["rows"], 1):
        cells = []
        for c_index, cell in enumerate(row, 1):
            ref = "%s%d" % (col_letter(c_index), r_index)
            cells.append(cell_xml(ref, cell["value"], cell["style"], cell["numeric"]))
        height = sheet["heights"].get(r_index)
        height_xml = " ht=\"%s\" customHeight=\"1\"" % height if height else ""
        rows.append("<row r=\"%d\"%s>%s</row>" % (r_index, height_xml, "".join(cells)))
    merges = ""
    if sheet["merges"]:
        items = "".join("<mergeCell ref=\"%s\"/>" % ref for ref in sheet["merges"])
        merges = "<mergeCells count=\"%d\">%s</mergeCells>" % (len(sheet["merges"]), items)
    auto = "<autoFilter ref=\"%s\"/>" % sheet["filter"] if sheet["filter"] else ""
    freeze = ""
    if sheet["freeze"]:
        freeze = (
            "<pane ySplit=\"%d\" topLeftCell=\"A%d\" activePane=\"bottomLeft\" state=\"frozen\"/>"
            "<selection pane=\"bottomLeft\" activeCell=\"A%d\" sqref=\"A%d\"/>"
            % (sheet["freeze"], sheet["freeze"] + 1, sheet["freeze"] + 1, sheet["freeze"] + 1)
        )
    selected_xml = " tabSelected=\"1\"" if selected else ""
    last_col = col_letter(max(1, len(sheet["widths"])))
    last_row = max(1, len(sheet["rows"]))
    header = (
        "&amp;L&amp;&quot;Meiryo UI,Standard&quot;&amp;9JBoss EAP ログ検索レポート"
        "&amp;C&amp;A&amp;R&amp;D &amp;T"
    )
    footer = "&amp;L&amp;F&amp;C&amp;P / &amp;N&amp;R&amp;&quot;Meiryo UI,Standard&quot;&amp;9モノトーン"
    paper = sheet.get("paper", "8")
    return (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        "<sheetPr><tabColor rgb=\"%s\"/><pageSetUpPr fitToPage=\"1\"/></sheetPr>"
        "<dimension ref=\"A1:%s%d\"/>"
        "<sheetViews><sheetView workbookViewId=\"0\" showGridLines=\"0\" zoomScale=\"100\"%s>%s</sheetView></sheetViews>"
        "<sheetFormatPr defaultRowHeight=\"18\" customHeight=\"1\"/>"
        "<cols>%s</cols>"
        "<sheetData>%s</sheetData>"
        "%s%s"
        "<printOptions horizontalCentered=\"0\"/>"
        "<pageMargins left=\"0.4\" right=\"0.4\" top=\"0.65\" bottom=\"0.5\" header=\"0.28\" footer=\"0.28\"/>"
        "<pageSetup orientation=\"landscape\" paperSize=\"%s\" fitToWidth=\"1\" fitToHeight=\"0\" pageOrder=\"down\"/>"
        "<headerFooter>"
        "<oddHeader>%s</oddHeader><oddFooter>%s</oddFooter>"
        "</headerFooter>"
        "</worksheet>"
        % (
            sheet["tab"],
            last_col,
            last_row,
            selected_xml,
            freeze,
            "".join(cols),
            "".join(rows),
            auto,
            merges,
            paper,
            header,
            footer,
        )
    )


def new_sheet(name, tab, widths, paper="8"):
    return {
        "name": name,
        "tab": tab,
        "widths": widths,
        "rows": [],
        "heights": {},
        "merges": [],
        "filter": None,
        "freeze": 0,
        "repeat": None,
        "paper": paper,
    }


def add_row(sheet, cells, height=None):
    sheet["rows"].append(cells)
    if height:
        sheet["heights"][len(sheet["rows"])] = height
    return len(sheet["rows"])


def merge(sheet, row, start_col, end_col):
    if end_col > start_col:
        sheet["merges"].append("%s%d:%s%d" % (col_letter(start_col), row, col_letter(end_col), row))


def fill_color(kind):
    return {
        "normal": "FFFFFFFF",
        "alt": "FFF4F4F4",
        "error": "FFD9D9D9",
        "warn": "FFEBEBEB",
        "total": "FFC8C8C8",
        "label": "FFE6E6E6",
    }[kind]


def data_style(styles, fill_name, align, wrap, numeric, bold=False):
    num = 0
    if numeric:
        num = 1 if align == "center" else 3
    return styles.style(
        bold=bold,
        fill=fill_color(fill_name),
        align=align,
        valign="top" if wrap else "center",
        wrap=wrap,
        num=num,
    )


def text_cell(styles, value, style, numeric=False):
    return {"value": value, "style": style, "numeric": numeric and value != "" and value is not None}


def title_row(sheet, styles, text, columns):
    style = styles.style(
        size=18, bold=True, color="FFFFFFFF", fill="FF2B2B2B", border="none",
        align="left", valign="center", wrap=False,
    )
    cells = [text_cell(styles, text if index == 0 else "", style) for index in range(columns)]
    row = add_row(sheet, cells, 32)
    merge(sheet, row, 1, columns)
    return style


def subtitle_row(sheet, styles, text, columns):
    style = styles.style(
        size=11, bold=False, color="FFF5F5F5", fill="FF4A4A4A", border="none",
        align="left", valign="center", wrap=True,
    )
    cells = [text_cell(styles, text if index == 0 else "", style) for index in range(columns)]
    row = add_row(sheet, cells, 22)
    merge(sheet, row, 1, columns)


def section_row(sheet, styles, text, columns):
    style = styles.style(
        size=12, bold=True, color="FFFFFFFF", fill="FF595959", border="none",
        align="left", valign="center", wrap=False,
    )
    cells = [text_cell(styles, text if index == 0 else "", style) for index in range(columns)]
    row = add_row(sheet, cells, 22)
    merge(sheet, row, 1, columns)


def header_cells(styles, names):
    style = styles.style(
        size=10, bold=True, color="FFFFFFFF", fill="FF333333", border="header",
        align="center", valign="center", wrap=True,
    )
    return [text_cell(styles, name, style) for name in names]


def blank_row(sheet, styles, columns, height=8):
    style = styles.style(border="none", fill="FFFFFFFF")
    add_row(sheet, [text_cell(styles, "", style) for _ in range(columns)], height)


def as_int(value):
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if isinstance(value, str) and re.fullmatch(r"\d+", value or ""):
        return int(value)
    return None


def build_table_row(styles, values, columns, fill_name, bold=False):
    cells = []
    for value, column in zip(values, columns):
        _name, align, wrap, numeric, _width = column
        number = as_int(value) if numeric else None
        use_numeric = number is not None
        shown = number if use_numeric else ("" if value is None else value)
        style = data_style(styles, fill_name, align, wrap, use_numeric, bold=bold)
        cells.append(text_cell(styles, shown, style, use_numeric))
    return cells


def reports_of(sources, kind):
    found = []
    for source in sources:
        for report in source["reports"]:
            if report["kind"] == kind:
                found.append(report)
    return found


def subtitle_for(reports, record_count):
    reflects = []
    ends = []
    labels = []
    for report in reports:
        if report["source"] not in labels:
            labels.append(report["source"])
        reflect = condition_value(report, "反映時刻 (JST)")
        end = condition_value(report, "終了時刻 (JST)")
        if reflect and reflect not in reflects:
            reflects.append(reflect)
        if end and end not in ends:
            ends.append(end)
    return "入力: %s    反映時刻: %s    終了時刻: %s    明細: %s 件" % (
        "、".join(labels) if labels else "なし",
        " / ".join(reflects) if reflects else "なし",
        " / ".join(ends) if ends else "なし",
        record_count,
    )


def build_detail_sheet(styles, kind, reports):
    extra = needs_extra(reports)
    columns = detail_columns(kind, extra)
    sheet = new_sheet("%s 明細" % KIND_NAME[kind], "FF4A4A4A", [column[4] for column in columns])
    title_row(sheet, styles, "%s 明細" % KIND_NAME[kind], len(columns))
    records = []
    for report in reports:
        records.extend(report["records"])
    subtitle_row(sheet, styles, subtitle_for(reports, len(records)), len(columns))
    header_index = add_row(sheet, header_cells(styles, [column[0] for column in columns]), 32)
    for index, record in enumerate(records):
        level = severity(kind, record)
        fill_name = level if level in ("error", "warn") else ("alt" if index % 2 else "normal")
        values = []
        for column in columns:
            name = column[0]
            if name == "実行":
                values.append(record.get("実行", ""))
            elif name == "入力ファイル":
                values.append(record.get("入力ファイル", ""))
            else:
                values.append(record.get(name, ""))
        add_row(sheet, build_table_row(styles, values, columns, fill_name), row_height(values, columns))
    last = max(header_index, len(sheet["rows"]))
    sheet["filter"] = "A%d:%s%d" % (header_index, col_letter(len(columns)), last)
    sheet["freeze"] = header_index
    sheet["repeat"] = header_index
    return sheet


def build_file_sheet(styles, kind, reports):
    columns = [
        ("実行", "center", False, True, 8),
        ("入力ファイル", "left", False, False, 32),
        ("No", "center", False, True, 8),
        ("コンテナ", "center", False, False, 14),
        ("ECSサービス", "center", False, False, 16),
        ("種別", "center", False, False, 12),
        ("タスク", "left", False, False, 36),
        ("ファイル", "left", False, False, 28),
        ("パス", "left", True, False, 72),
    ]
    sheet = new_sheet("%s 対象ファイル" % KIND_NAME[kind], "FF5C5C5C", [column[4] for column in columns])
    title_row(sheet, styles, "%s 対象ファイル" % KIND_NAME[kind], len(columns))
    total = sum(len(report["files"]) for report in reports)
    subtitle_row(sheet, styles, "一覧に出ているファイル: %s 件" % total, len(columns))
    header_index = add_row(sheet, header_cells(styles, [column[0] for column in columns]), 32)
    row_index = 0
    for report in reports:
        for item in report["files"]:
            values = [
                report["run"], report["source"], item["No"], item["コンテナ"], item["ECSサービス"],
                item["種別"], item["タスク"], item["ファイル"], item["パス"],
            ]
            fill_name = "alt" if row_index % 2 else "normal"
            add_row(sheet, build_table_row(styles, values, columns, fill_name), row_height(values, columns))
            row_index += 1
    last = max(header_index, len(sheet["rows"]))
    sheet["filter"] = "A%d:%s%d" % (header_index, col_letter(len(columns)), last)
    sheet["freeze"] = header_index
    sheet["repeat"] = header_index
    return sheet


def build_summary_sheet(styles, kind, reports):
    metrics = METRICS[kind]
    columns = [
        ("実行", "center", False, True, 8),
        ("入力ファイル", "left", False, False, 32),
        ("コンテナ", "left", False, False, 14),
        ("ECSサービス", "left", False, False, 16),
    ]
    for metric in metrics:
        columns.append((metric, "right", False, True, 12))
    columns.append(("合計", "right", False, True, 12))
    sheet = new_sheet("%s 集計" % KIND_NAME[kind], "FF6A6A6A", [column[4] for column in columns])
    title_row(sheet, styles, "%s 集計" % KIND_NAME[kind], len(columns))
    subtitle_row(sheet, styles, "件数は検索スクリプトが表示した集計です。空欄はその行に出ていない項目です。", len(columns))
    section_row(sheet, styles, "件数（コンテナ / ECSサービス）", len(columns))
    header_index = add_row(sheet, header_cells(styles, [column[0] for column in columns]), 32)
    body_rows = 0
    for report in reports:
        for item in report["summary_rows"]:
            values = [report["run"], report["source"], item.get("コンテナ", ""), item.get("ECSサービス", "")]
            for metric in metrics:
                values.append(item[metric] if metric in item else "")
            values.append(item.get("合計", ""))
            fill_name = "alt" if body_rows % 2 else "normal"
            add_row(sheet, build_table_row(styles, values, columns, fill_name))
            body_rows += 1
        if report["summary_total"]:
            item = report["summary_total"]
            values = [report["run"], report["source"], "合計", ""]
            for metric in metrics:
                values.append(item[metric] if metric in item else "")
            values.append(item.get("合計", ""))
            add_row(sheet, build_table_row(styles, values, columns, "total", bold=True), 20)
    last = max(header_index, len(sheet["rows"]))
    sheet["filter"] = "A%d:%s%d" % (header_index, col_letter(len(columns)), last)
    sheet["freeze"] = header_index
    sheet["repeat"] = header_index
    if any(report["statuses"] for report in reports):
        blank_row(sheet, styles, len(columns))
        section_row(sheet, styles, "ステータス内訳", len(columns))
        status_columns = [
            ("実行", "center", False, True, 8),
            ("入力ファイル", "left", False, False, 32),
            ("種別", "center", False, False, 14),
            ("値", "center", False, False, 16),
            ("件数", "right", False, True, 12),
        ]
        # The sheet width stays on the count table. Status rows use the same column count.
        status_header = ["実行", "入力ファイル", "種別", "値", "件数"] + [""] * (len(columns) - 5)
        add_row(sheet, header_cells(styles, status_header), 24)
        for report in reports:
            for kind_name, code, count in report["statuses"]:
                values = [report["run"], report["source"], kind_name, code, count]
                values.extend([""] * (len(columns) - 5))
                padded = columns[:]
                add_row(sheet, build_table_row(styles, values, padded, "normal"))
    if any(report["stats"] for report in reports):
        blank_row(sheet, styles, len(columns))
        section_row(sheet, styles, "読み込み状況", len(columns))
        stat_header = ["実行", "入力ファイル", "項目", "内容"] + [""] * (len(columns) - 4)
        add_row(sheet, header_cells(styles, stat_header), 24)
        stat_row = 0
        for report in reports:
            for label, value in report["stats"]:
                number = as_int(value)
                values = [report["run"], report["source"], label, number if number is not None else value]
                values.extend([""] * (len(columns) - 4))
                fill_name = "alt" if stat_row % 2 else "normal"
                stat_row += 1
                cells = build_table_row(styles, values, columns, fill_name)
                if number is None:
                    cells[3] = text_cell(
                        styles, value,
                        data_style(styles, fill_name, "left", True, False),
                        False,
                    )
                else:
                    cells[3] = text_cell(
                        styles, number,
                        data_style(styles, fill_name, "right", False, True),
                        True,
                    )
                add_row(sheet, cells, row_height(values, [
                    ("実行", "center", False, True, 8),
                    ("入力ファイル", "left", False, False, 32),
                    ("項目", "left", False, False, 28),
                    ("内容", "left", True, False, 72),
                ] + [("空き", "left", False, False, 12)] * (len(columns) - 4)))
    return sheet


def build_condition_sheet(styles, sources):
    columns = [
        ("ログ種別", "left", False, False, 16),
        ("実行", "center", False, True, 8),
        ("入力ファイル", "left", False, False, 32),
        ("項目", "left", False, False, 24),
        ("内容", "left", True, False, 78),
    ]
    sheet = new_sheet("検索条件", "FF3A3A3A", [column[4] for column in columns], paper="9")
    title_row(sheet, styles, "検索条件", len(columns))
    subtitle_row(sheet, styles, "検索スクリプトが先頭に出した条件です。", len(columns))
    header_index = add_row(sheet, header_cells(styles, [column[0] for column in columns]), 32)
    row_index = 0
    for kind in KIND_ORDER:
        for report in reports_of(sources, kind):
            for label, value in report["conditions"]:
                values = [KIND_NAME[kind], report["run"], report["source"], label, value]
                fill_name = "alt" if row_index % 2 else "normal"
                add_row(sheet, build_table_row(styles, values, columns, fill_name), row_height(values, columns))
                row_index += 1
    last = max(header_index, len(sheet["rows"]))
    sheet["filter"] = "A%d:%s%d" % (header_index, col_letter(len(columns)), last)
    sheet["freeze"] = header_index
    sheet["repeat"] = header_index
    return sheet


def build_note_sheet(styles, sources):
    columns = [
        ("ログ種別", "left", False, False, 16),
        ("実行", "center", False, True, 8),
        ("入力ファイル", "left", False, False, 32),
        ("区分", "left", False, False, 28),
        ("コンテナ", "center", False, False, 14),
        ("ECSサービス", "center", False, False, 16),
        ("内容", "left", True, False, 64),
        ("パス", "left", True, False, 64),
    ]
    sheet = new_sheet("確認事項", "FF7A7A7A", [column[4] for column in columns])
    title_row(sheet, styles, "確認事項", len(columns))
    subtitle_row(sheet, styles, "ディレクトリなし、読めないパス、省略、補足、読み取りの注意です。", len(columns))
    header_index = add_row(sheet, header_cells(styles, [column[0] for column in columns]), 32)
    row_index = 0

    def add_item(report, item, fill_force=None):
        nonlocal row_index
        values = [
            KIND_NAME[report["kind"]], report["run"], report["source"],
            item.get("区分", ""), item.get("コンテナ", ""), item.get("ECSサービス", ""),
            item.get("内容", ""), item.get("パス", ""),
        ]
        fill_name = fill_force or ("alt" if row_index % 2 else "normal")
        add_row(sheet, build_table_row(styles, values, columns, fill_name), row_height(values, columns))
        row_index += 1

    any_row = False
    for kind in KIND_ORDER:
        for report in reports_of(sources, kind):
            for item in report["issues"]:
                add_item(report, item)
                any_row = True
            for note in report["notes"]:
                add_item(report, {"区分": "補足", "内容": note})
                any_row = True
            for warning in report["warnings"]:
                add_item(report, {"区分": "読み取り", "内容": warning}, "warn")
                any_row = True
    if not any_row:
        return None
    last = max(header_index, len(sheet["rows"]))
    sheet["filter"] = "A%d:%s%d" % (header_index, col_letter(len(columns)), last)
    sheet["freeze"] = header_index
    sheet["repeat"] = header_index
    return sheet


def build_cover(styles, sources, made_at):
    columns = [
        ("ログ種別", "left", False, False, 16),
        ("実行", "center", False, True, 8),
        ("入力ファイル", "left", False, False, 34),
        ("反映時刻 (JST)", "left", False, False, 36),
        ("終了時刻 (JST)", "left", False, False, 28),
        ("明細", "right", False, True, 10),
        ("エラー", "right", False, True, 10),
        ("警告", "right", False, True, 10),
        ("対象ファイル", "right", False, True, 14),
    ]
    sheet = new_sheet("表紙", "FF2B2B2B", [column[4] for column in columns], paper="9")
    title_row(sheet, styles, "JBoss EAP ログ検索レポート", len(columns))
    subtitle_row(
        sheet, styles,
        "作成: %s    フォント: Meiryo UI    色: モノトーン" % made_at,
        len(columns),
    )
    blank_row(sheet, styles, len(columns), 10)
    section_row(sheet, styles, "概要", len(columns))
    header_index = add_row(sheet, header_cells(styles, [column[0] for column in columns]), 30)
    row_index = 0
    report_count = 0
    for kind in KIND_ORDER:
        for report in reports_of(sources, kind):
            report_count += 1
            declared = report["declared_files"]
            file_count = declared if declared is not None else len(report["files"])
            values = [
                KIND_NAME[kind],
                report["run"],
                report["source"],
                condition_value(report, "反映時刻 (JST)"),
                condition_value(report, "終了時刻 (JST)"),
                len(report["records"]),
                count_severity(kind, report["records"], "error"),
                count_severity(kind, report["records"], "warn"),
                file_count,
            ]
            fill_name = "alt" if row_index % 2 else "normal"
            add_row(sheet, build_table_row(styles, values, columns, fill_name), 20)
            row_index += 1
    if report_count == 0:
        note_style = styles.style(size=11, color="FF1F1F1F", fill="FFFFFFFF", border="none", wrap=True)
        cells = [text_cell(styles, "検索結果の見出しが見つかりませんでした。Tera Term のログに、スクリプトの実行結果が入っているか確認してください。" if i == 0 else "", note_style) for i in range(len(columns))]
        row = add_row(sheet, cells, 36)
        merge(sheet, row, 1, len(columns))
    sheet["filter"] = "A%d:%s%d" % (header_index, col_letter(len(columns)), max(header_index, len(sheet["rows"])))
    blank_row(sheet, styles, len(columns), 10)
    section_row(sheet, styles, "入力ファイル", len(columns))
    input_header = ["ファイル", "文字コード", "サイズ", "レポート", "", "", "", "", ""]
    add_row(sheet, header_cells(styles, input_header), 24)
    input_columns = [
        ("ファイル", "left", False, False, 36),
        ("文字コード", "center", False, False, 14),
        ("サイズ", "right", False, True, 14),
        ("レポート", "right", False, True, 12),
    ] + [("空き", "left", False, False, 12)] * 5
    for index, source in enumerate(sources):
        values = [source["label"], source["encoding"], source["size"], len(source["reports"]), "", "", "", "", ""]
        fill_name = "alt" if index % 2 else "normal"
        add_row(sheet, build_table_row(styles, values, input_columns, fill_name), 20)
    blank_row(sheet, styles, len(columns), 10)
    section_row(sheet, styles, "見方", len(columns))
    notes = [
        "明細シートは、検索結果の 1 件を 1 行にしています。見出しは画面に出た項目です。",
        "濃い灰色の行はエラー、やや薄い灰色の行は警告です。その他は白とごく薄い灰色です。",
        "見出し行で絞り込めます。長い文は折り返します。印刷は横向きで、幅を 1 ページに合わせます。",
    ]
    note_style = styles.style(size=10, color="FF1F1F1F", fill="FFFFFFFF", border="none", align="left", valign="center", wrap=True)
    for text in notes:
        cells = [text_cell(styles, text if i == 0 else "", note_style) for i in range(len(columns))]
        row = add_row(sheet, cells, 20)
        merge(sheet, row, 1, len(columns))
    return sheet


def build_sheets(styles, sources, made_at):
    sheets = [build_cover(styles, sources, made_at)]
    if any(source["reports"] for source in sources):
        sheets.append(build_condition_sheet(styles, sources))
    for kind in KIND_ORDER:
        reports = reports_of(sources, kind)
        if not reports:
            continue
        sheets.append(build_detail_sheet(styles, kind, reports))
        sheets.append(build_file_sheet(styles, kind, reports))
        if any(report["summary_rows"] or report["summary_total"] or report["stats"] or report["statuses"] for report in reports):
            sheets.append(build_summary_sheet(styles, kind, reports))
    note_sheet = build_note_sheet(styles, sources)
    if note_sheet is not None:
        sheets.append(note_sheet)
    return sheets


def defined_names_xml(sheets):
    names = []
    for sheet in sheets:
        if not sheet["repeat"]:
            continue
        safe = sheet["name"].replace("'", "''")
        names.append(
            "<definedName name=\"_xlnm.Print_Titles\" localSheetId=\"%d\">'%s'!$%d:$%d</definedName>"
            % (sheets.index(sheet), safe, sheet["repeat"], sheet["repeat"])
        )
    if not names:
        return ""
    return "<definedNames>%s</definedNames>" % "".join(names)


def workbook_xml(sheets):
    items = []
    for index, sheet in enumerate(sheets, 1):
        items.append(
            "<sheet name=\"%s\" sheetId=\"%d\" r:id=\"rId%d\"/>"
            % (xml_escape(sheet["name"]), index, index)
        )
    return (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        "<workbookPr defaultThemeVersion=\"164011\"/>"
        "<bookViews><workbookView activeTab=\"0\"/></bookViews>"
        "<sheets>%s</sheets>"
        "%s"
        "<calcPr calcMode=\"auto\"/>"
        "</workbook>"
        % ("".join(items), defined_names_xml(sheets))
    )


def workbook_rels(sheets):
    items = []
    for index, _sheet in enumerate(sheets, 1):
        items.append(
            "<Relationship Id=\"rId%d\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet%d.xml\"/>"
            % (index, index)
        )
    style_id = len(sheets) + 1
    items.append(
        "<Relationship Id=\"rId%d\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        % style_id
    )
    return (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">%s</Relationships>"
        % "".join(items)
    )


def content_types(sheets):
    overrides = [
        "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>",
        "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>",
        "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>",
        "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>",
    ]
    for index in range(1, len(sheets) + 1):
        overrides.append(
            "<Override PartName=\"/xl/worksheets/sheet%d.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            % index
        )
    return (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        "%s</Types>" % "".join(overrides)
    )


def core_xml(made_at_iso):
    return (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" "
        "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
        "xmlns:dcterms=\"http://purl.org/dc/terms/\" "
        "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        "<dc:title>JBoss EAP ログ検索レポート</dc:title>"
        "<dc:creator>jboss-eap-teraterm-log-report</dc:creator>"
        "<cp:lastModifiedBy>jboss-eap-teraterm-log-report</cp:lastModifiedBy>"
        "<dcterms:created xsi:type=\"dcterms:W3CDTF\">%s</dcterms:created>"
        "<dcterms:modified xsi:type=\"dcterms:W3CDTF\">%s</dcterms:modified>"
        "</cp:coreProperties>"
        % (made_at_iso, made_at_iso)
    )


def app_xml(sheets):
    titles = "".join("<vt:lpstr>%s</vt:lpstr>" % xml_escape(sheet["name"]) for sheet in sheets)
    return (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\" "
        "xmlns:vt=\"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes\">"
        "<Application>jboss-eap-teraterm-log-report</Application>"
        "<HeadingPairs><vt:vector size=\"2\" baseType=\"variant\">"
        "<vt:variant><vt:lpstr>ワークシート</vt:lpstr></vt:variant>"
        "<vt:variant><vt:i4>%d</vt:i4></vt:variant>"
        "</vt:vector></HeadingPairs>"
        "<TitlesOfParts><vt:vector size=\"%d\" baseType=\"lpstr\">%s</vt:vector></TitlesOfParts>"
        "</Properties>"
        % (len(sheets), len(sheets), titles)
    )


def root_rels():
    return (
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
        "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>"
        "</Relationships>"
    )


def write_xlsx(path, sheets, styles, made_at_iso):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    if temporary.exists():
        temporary.unlink()
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("[Content_Types].xml", content_types(sheets))
            archive.writestr("_rels/.rels", root_rels())
            archive.writestr("docProps/core.xml", core_xml(made_at_iso))
            archive.writestr("docProps/app.xml", app_xml(sheets))
            archive.writestr("xl/workbook.xml", workbook_xml(sheets))
            archive.writestr("xl/_rels/workbook.xml.rels", workbook_rels(sheets))
            archive.writestr("xl/styles.xml", styles.xml())
            for index, sheet in enumerate(sheets, 1):
                archive.writestr("xl/worksheets/sheet%d.xml" % index, sheet_xml(sheet, index == 1))
        os.replace(str(temporary), str(path))
    except Exception:
        if temporary.exists():
            temporary.unlink()
        raise
    try:
        os.chmod(str(path), 0o600)
    except OSError:
        pass


def default_output():
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    return Path.cwd() / ("jboss-eap-log-report-%s.xlsx" % stamp)


def print_summary(path, sources, code):
    print("レポートを書きました: %s" % path)
    if code == 2:
        print("検索結果の見出しは見つかりませんでした。表紙にその旨を書いてあります。", file=sys.stderr)
        return
    for kind in KIND_ORDER:
        reports = reports_of(sources, kind)
        if not reports:
            continue
        records = [record for report in reports for record in report["records"]]
        print(
            "  %-12s 明細 %d 件    エラー %d    警告 %d"
            % (
                KIND_NAME[kind],
                len(records),
                count_severity(kind, records, "error"),
                count_severity(kind, records, "warn"),
            )
        )


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="jboss-eap-teraterm-log-report.sh",
        description=(
            "JBoss EAP の server.log / access_log / gc.log 検索結果が入った "
            "Tera Term ログを読み、1 行 1 件の Excel レポートを作ります。"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "例:\n"
            "  bash jboss-eap-teraterm-log-report.sh -o report.xlsx teraterm.log\n"
            "  bash jboss-eap-teraterm-log-report.sh -o report.xlsx server.log access.log gc.log\n"
            "  bash jboss-eap-teraterm-log-report.sh -o report.xlsx ./teraterm-logs\n"
        ),
    )
    parser.add_argument("-o", "--output", help="出力する xlsx。省略時はカレントへ日時付きで作ります。")
    parser.add_argument("logs", nargs="+", help="Tera Term のログファイル、または .log / .txt があるディレクトリ")
    return parser.parse_args(argv)


def main(argv):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    args = parse_args(argv)
    paths = expand_inputs(args.logs)
    output = Path(args.output) if args.output else default_output()
    if output.suffix.lower() != ".xlsx":
        output = output.with_suffix(output.suffix + ".xlsx")
    if output.exists() and output.is_dir():
        die("出力先がディレクトリです: %s" % output)
    sources = load_sources(paths)
    made = datetime.now().astimezone()
    made_at = made.strftime("%Y-%m-%d %H:%M:%S")
    made_iso = made.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    styles = StyleBook()
    sheets = build_sheets(styles, sources, made_at)
    try:
        write_xlsx(output, sheets, styles, made_iso)
    except PermissionError:
        die("書き込めません。Excel で開いているときは閉じてから再実行してください: %s" % output)
    found = any(source["reports"] for source in sources)
    code = 0 if found else 2
    print_summary(output, sources, code)
    return code


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
PY
