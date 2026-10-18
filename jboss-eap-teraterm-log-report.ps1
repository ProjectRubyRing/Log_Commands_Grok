# JBoss EAP の server.log / access_log / gc.log 検索結果が
# 入った Tera Term ログを読み、Excel レポート (.xlsx) を作る。
#
# 検索スクリプトの画面出力を、そのまま Tera Term のログに残してある
# 前提。ログをこのスクリプトへ渡すと、出力項目をヘッダにした
# 1 行 1 件の表にする。フォントは Meiryo UI、色は灰色だけ。
#
# Windows 11 の PowerShell 5.1 で実行する。追加モジュールは要らない。
# RHEL 9.8 では jboss-eap-teraterm-log-report.sh を使う。
#   powershell -File .\jboss-eap-teraterm-log-report.ps1 -Output report.xlsx .\teraterm.log
#   powershell -File .\jboss-eap-teraterm-log-report.ps1 -Output report.xlsx .\logs
#
# 検索結果の見出しが無いときは、表紙だけ書いた xlsx を残して終了コード 2。

[CmdletBinding()]
param(
    [Alias("o")]
    [string]$Output,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Path
)

$ErrorActionPreference = "Stop"

$Script:KindOrder = @("server", "access", "gc")
$Script:KindName = @{
    server = "server.log"
    access = "access_log"
    gc     = "gc.log"
}
$Script:ErrorWords = @{
    ERROR = $true; FATAL = $true; SEVERE = $true; EMERGENCY = $true; "サーバエラー" = $true
}
$Script:WarnWords = @{
    WARN = $true; WARNING = $true; "警告" = $true
}
$Script:Metrics = @{
    server = @("ERROR", "WARN", "FATAL", "SEVERE", "EMERGENCY", "INFO", "DEBUG", "TRACE")
    access = @("エラー", "警告", "正常", "転送", "情報", "不明")
    gc     = @("エラー", "警告", "情報", "DEBUG", "TRACE")
}
$Script:ClassByLabel = @{
    "サーバエラー" = "ERROR"
    "警告"       = "WARN"
    "正常"       = "OK"
    "転送"       = "REDIRECT"
    "情報"       = "INFO"
    "不明"       = "UNKNOWN"
}
$Script:IssueHeaders = @{
    "ディレクトリなし:" = "ディレクトリなし"
    "ログファイルなし:" = "ログファイルなし"
    "古いローテーションだけで、反映時刻の範囲には入らないサービス:" = "古いローテーションのみ"
    "読めないパス:" = "読めないパス"
    "切れたシンボリックリンク:" = "切れたシンボリックリンク"
    "基点の外を指していたため除外:" = "基点の外"
}
$Script:TitleRe = [regex]'^ JBoss EAP (server\.log|access_log|gc\.log) 検索$'
$Script:FieldRe = [regex]'^ {2}(.+?)\s+:\s(.*)$'
$Script:FileRe = [regex]'^ {2}(\d+)\. コンテナ: (\S+) {2}ECSサービス: (\S+) {2}種別: (\S+) {2}タスク: (.*)$'
$Script:NameRe = [regex]'^ {5}ファイル: (.*)$'
$Script:PathRe = [regex]'^ {5}パス: (.*)$'
$Script:MoreRe = [regex]'^ {2}\.\.\. 他 (\d+) 件$'
$Script:SkipRe = [regex]'^ {2}読み飛ばした古いローテーション: (\d+) 件（(.*)）$'
$Script:CountRe = [regex]'^ 対象ファイル (\d+) 件$'
$Script:PairRe = [regex]'^ {2}コンテナ: (\S+) {2}ECSサービス: (\S+)$'
$Script:OldRe = [regex]'^ {2}コンテナ: (\S+) {2}ECSサービス: (\S+) {2}読み飛ばし: (\d+) 件$'
$Script:RecRe = [regex]'^-------- #([0-9]+) --------$'
$Script:AccHeadRe = [regex]'^ アクセスログ (\d+) 件（JST の昇順）$'
$Script:NoiseRe = [regex]'^対象 \d+ ファイルを.*読み込んでいます\.\.\.$'
$Script:SumRe = [regex]'^ {2}コンテナ (\S+) / ECSサービス (\S+) {2}(.+) {2}合計 (\d+)$'
$Script:TotalRe = [regex]'^ {2}合計 {2}(.+) {2}表示 (\d+)$'
$Script:KvRe = [regex]'^ {2,}(.+?)\s*:\s(.*)$'
$Script:HttpRe = [regex]'^ {4}HTTP (\S+) × (\d+)$'
$Script:LevelRe = [regex]'^ {4}レベル (\S+) × (\d+)$'
$Script:MetricRe = [regex]'(EMERGENCY|SEVERE|ERROR|TRACE|DEBUG|FATAL|WARN|INFO|エラー|警告|正常|転送|情報|不明) (\d+)'
$Script:TsPrefixRe = [regex]'^(?:\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:[.,]\d{1,3})?|\[[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[.,]\d{1,3})?\])[ \t]'
$Script:AnsiRe = [regex]"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]|\x1b\([ -~]"
$Script:LongText = 32000

$Script:ServerCols = @(
    @("No", "center", $false, $true, 8),
    @("時刻 (JST)", "left", $false, $false, 23),
    @("レベル", "center", $false, $false, 14),
    @("コンテナ", "center", $false, $false, 14),
    @("ECSサービス", "center", $false, $false, 16),
    @("種別", "center", $false, $false, 12),
    @("タスク", "left", $false, $false, 36),
    @("ファイル", "left", $false, $false, 28),
    @("パス", "left", $true, $false, 64),
    @("メッセージ", "left", $true, $false, 78),
    @("スタックトレース", "left", $true, $false, 78)
)
$Script:AccessCols = @(
    @("No", "center", $false, $true, 8),
    @("時刻 (JST)", "left", $false, $false, 23),
    @("区分", "center", $false, $false, 14),
    @("HTTPステータス", "center", $false, $true, 16),
    @("レベル", "center", $false, $false, 12),
    @("コンテナ", "center", $false, $false, 14),
    @("ECSサービス", "center", $false, $false, 16),
    @("種別", "center", $false, $false, 12),
    @("タスク", "left", $false, $false, 36),
    @("メソッド", "center", $false, $false, 12),
    @("URI", "left", $true, $false, 64),
    @("プロトコル", "center", $false, $false, 14),
    @("メッセージ", "left", $true, $false, 56),
    @("クライアント", "left", $false, $false, 18),
    @("ユーザ", "left", $false, $false, 16),
    @("応答バイト", "right", $false, $true, 14),
    @("処理時間", "right", $false, $false, 14),
    @("Referer", "left", $true, $false, 42),
    @("UA", "left", $true, $false, 42),
    @("追加", "left", $true, $false, 36),
    @("元の時刻", "left", $false, $false, 28),
    @("ファイル", "left", $false, $false, 28),
    @("パス", "left", $true, $false, 64),
    @("生ログ", "left", $true, $false, 64)
)
$Script:GcCols = @(
    @("No", "center", $false, $true, 8),
    @("時刻 (JST)", "left", $false, $false, 23),
    @("レベル", "center", $false, $false, 12),
    @("イベント", "center", $false, $false, 16),
    @("停止", "right", $false, $false, 12),
    @("ヒープ", "left", $false, $false, 34),
    @("コンテナ", "center", $false, $false, 14),
    @("ECSサービス", "center", $false, $false, 16),
    @("種別", "center", $false, $false, 12),
    @("タスク", "left", $false, $false, 36),
    @("原因", "left", $true, $false, 28),
    @("GC番号", "center", $false, $true, 12),
    @("ファイル", "left", $false, $false, 22),
    @("元時刻", "left", $false, $false, 36),
    @("パス", "left", $true, $false, 64),
    @("ログ", "left", $true, $false, 72),
    @("継続行", "left", $true, $false, 72)
)
$Script:Cols = @{
    server = $Script:ServerCols
    access = $Script:AccessCols
    gc     = $Script:GcCols
}
$Script:ExtraCols = @(
    @("実行", "center", $false, $true, 8),
    @("入力ファイル", "left", $false, $false, 32)
)

function Get-Count {
    param($Value)
    if ($null -eq $Value) { return 0 }
    return [int]$Value.Count
}

function Fail {
    param([string]$Message, [int]$Code = 1)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Clean-Text {
    param($Value)
    if ($null -eq $Value) { return "" }
    $text = [string]$Value
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $text.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 9 -or $code -eq 10 -or $code -ge 32) {
            if ($code -ne 0xFFFE -and $code -ne 0xFFFF -and -not ($code -ge 0xD800 -and $code -le 0xDFFF)) {
                [void]$sb.Append($ch)
            }
        }
    }
    $out = $sb.ToString()
    if ($out.Length -gt $Script:LongText) {
        return $out.Substring(0, $Script:LongText) + "...（Excelのセル上限のため省略）"
    }
    return $out
}

function Get-DecodedText {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        $enc = New-Object System.Text.UTF8Encoding $false, $true
        return @{ Text = $enc.GetString($Bytes, 3, $Bytes.Length - 3); Encoding = "utf-8" }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $enc = [System.Text.Encoding]::Unicode
        return @{ Text = $enc.GetString($Bytes, 2, $Bytes.Length - 2); Encoding = "utf-16-le" }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        $enc = [System.Text.Encoding]::BigEndianUnicode
        return @{ Text = $enc.GetString($Bytes, 2, $Bytes.Length - 2); Encoding = "utf-16-be" }
    }
    $sample = [Math]::Min(200, $Bytes.Length)
    $nulls = 0
    for ($i = 0; $i -lt $sample; $i++) { if ($Bytes[$i] -eq 0) { $nulls++ } }
    if ($nulls -gt 8) {
        try {
            $enc = [System.Text.Encoding]::Unicode
            return @{ Text = $enc.GetString($Bytes); Encoding = "utf-16" }
        } catch {}
    }
    $strict = New-Object System.Text.UTF8Encoding $false, $true
    try {
        return @{ Text = $strict.GetString($Bytes); Encoding = "utf-8" }
    } catch {}
    $cp = [System.Text.Encoding]::GetEncoding(932)
    $cpText = $cp.GetString($Bytes)
    $loose = New-Object System.Text.UTF8Encoding $false, $false
    $replaced = $loose.GetString($Bytes)
    if ($cpText.Contains("JBoss EAP") -or $cpText.Contains("検索")) {
        if (-not $replaced.Contains("JBoss EAP") -and -not $replaced.Contains("検索")) {
            return @{ Text = $cpText; Encoding = "cp932" }
        }
    }
    $cpBad = ([regex]::Matches($cpText, [char]0xFFFD)).Count
    $utfBad = ([regex]::Matches($replaced, [char]0xFFFD)).Count
    if ($utfBad -gt $cpBad) {
        return @{ Text = $cpText; Encoding = "cp932" }
    }
    return @{ Text = $replaced; Encoding = "utf-8" }
}

function Remove-TimestampPrefix {
    param([string]$Line)
    $match = $Script:TsPrefixRe.Match($Line)
    if (-not $match.Success) { return $Line }
    return $Line.Substring($match.Length)
}

function ConvertTo-Lines {
    param([string]$Text)
    $text = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $text = $Script:AnsiRe.Replace($text, "")
    $text = [regex]::Replace($text, "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "")
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $text.Split("`n")) {
        $lines.Add((Remove-TimestampPrefix $line.TrimEnd()))
    }
    if ($lines.Count -gt 0 -and $lines[0].StartsWith([char]0xFEFF)) {
        $lines[0] = $lines[0].TrimStart([char]0xFEFF)
    }
    return ,$lines
}

function Test-Hr {
    param([string]$Line)
    return $Line.Length -ge 20 -and $Line -match '^=+$'
}

function Test-Thin {
    param([string]$Line)
    return $Line.Length -ge 20 -and $Line -match '^-+$'
}

function Get-Kind {
    param([string]$Title)
    $match = $Script:TitleRe.Match($Title)
    if (-not $match.Success) { return $null }
    $name = $match.Groups[1].Value
    if ($name -eq "server.log") { return "server" }
    if ($name -eq "access_log") { return "access" }
    return "gc"
}

function New-Issue {
    return @{
        "区分" = ""; "コンテナ" = ""; "ECSサービス" = ""; "内容" = ""; "パス" = ""
    }
}

function Get-Metrics {
    param([string]$Text)
    $found = @{}
    foreach ($match in $Script:MetricRe.Matches($Text)) {
        $found[$match.Groups[1].Value] = [int]$match.Groups[2].Value
    }
    return $found
}

function Get-Preface {
    param($Lines, [int]$Start, [int]$End)
    $files = New-Object System.Collections.Generic.List[object]
    $issues = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    $declared = $null
    $headerCount = $null
    $idx = $Start
    while ($idx -lt $End -and -not $Lines[$idx].StartsWith(" 対象ファイル ")) { $idx++ }
    if ($idx -ge $End) {
        for ($j = $Start; $j -lt $End; $j++) {
            $line = $Lines[$j]
            if ((Test-Hr $line) -or (Test-Thin $line) -or $line -eq "" -or $Script:NoiseRe.IsMatch($line)) { continue }
            $notes.Add($line.Trim())
        }
        return @{ Files = $files; Issues = $issues; Notes = $notes; Declared = $declared; HeaderCount = $headerCount }
    }
    $countMatch = $Script:CountRe.Match($Lines[$idx])
    if ($countMatch.Success) { $declared = [int]$countMatch.Groups[1].Value }
    $idx++
    $current = $null
    $section = $null
    $pending = $null
    while ($idx -lt $End -and -not (Test-Hr $Lines[$idx])) {
        $line = $Lines[$idx]
        $idx++
        if ($line -eq "" -or (Test-Thin $line)) { continue }
        $match = $Script:FileRe.Match($line)
        if ($match.Success) {
            $current = @{
                "No" = [int]$match.Groups[1].Value
                "コンテナ" = $match.Groups[2].Value
                "ECSサービス" = $match.Groups[3].Value
                "種別" = $match.Groups[4].Value
                "タスク" = $match.Groups[5].Value
                "ファイル" = ""
                "パス" = ""
            }
            $files.Add($current)
            $section = $null
            $pending = $null
            continue
        }
        $match = $Script:NameRe.Match($line)
        if ($match.Success -and $null -ne $current -and $null -eq $section) {
            $current["ファイル"] = $match.Groups[1].Value
            continue
        }
        $match = $Script:PathRe.Match($line)
        if ($match.Success -and $null -ne $current -and $null -eq $section) {
            $current["パス"] = $match.Groups[1].Value
            continue
        }
        $match = $Script:MoreRe.Match($line)
        if ($match.Success) {
            $item = New-Issue
            $item["区分"] = "対象ファイルの省略"
            $item["内容"] = "他 $($match.Groups[1].Value) 件は、このログには出ていません"
            $issues.Add($item)
            continue
        }
        $match = $Script:SkipRe.Match($line)
        if ($match.Success) {
            $item = New-Issue
            $item["区分"] = "読み飛ばした古いローテーション"
            $item["内容"] = "$($match.Groups[1].Value) 件（$($match.Groups[2].Value)）"
            $issues.Add($item)
            continue
        }
        $stripped = $line.Trim()
        if ($Script:IssueHeaders.ContainsKey($stripped)) {
            $section = $Script:IssueHeaders[$stripped]
            $current = $null
            $pending = $null
            continue
        }
        if ($section -eq "ログファイルなし") {
            $match = $Script:PairRe.Match($line)
            if ($match.Success) {
                $pending = New-Issue
                $pending["区分"] = $section
                $pending["コンテナ"] = $match.Groups[1].Value
                $pending["ECSサービス"] = $match.Groups[2].Value
                continue
            }
            if ($null -ne $pending -and $line.StartsWith("  ")) {
                $pending["パス"] = $line.Trim()
                $issues.Add($pending)
                $pending = $null
                continue
            }
        }
        if ($section -eq "古いローテーションのみ") {
            $match = $Script:OldRe.Match($line)
            if ($match.Success) {
                $pending = New-Issue
                $pending["区分"] = $section
                $pending["コンテナ"] = $match.Groups[1].Value
                $pending["ECSサービス"] = $match.Groups[2].Value
                $pending["内容"] = "読み飛ばし $($match.Groups[3].Value) 件"
                continue
            }
            if ($null -ne $pending -and $line.StartsWith("  ")) {
                $pending["パス"] = $line.Trim()
                $issues.Add($pending)
                $pending = $null
                continue
            }
        }
        if ($section -and $line.StartsWith("  ")) {
            $item = New-Issue
            $item["区分"] = $section
            $item["パス"] = $line.Trim()
            $issues.Add($item)
            continue
        }
        if ($stripped -and -not $Script:NoiseRe.IsMatch($stripped)) {
            $notes.Add($stripped)
        }
    }
    if ($idx -lt $End -and (Test-Hr $Lines[$idx])) { $idx++ }
    while ($idx -lt $End) {
        $line = $Lines[$idx]
        $idx++
        if ($line -eq "" -or (Test-Hr $line) -or (Test-Thin $line) -or $Script:NoiseRe.IsMatch($line)) { continue }
        $match = $Script:AccHeadRe.Match($line)
        if ($match.Success) {
            $headerCount = [int]$match.Groups[1].Value
            continue
        }
        $notes.Add($line.Trim())
    }
    if ($null -ne $declared) {
        $omitted = 0
        foreach ($item in $issues) {
            if ($item["区分"] -eq "対象ファイルの省略") {
                $number = [regex]::Match([string]$item["内容"], "(\d+)")
                if ($number.Success) { $omitted = [int]$number.Groups[1].Value }
            }
        }
        if (($files.Count + $omitted) -ne $declared) {
            $item = New-Issue
            $item["区分"] = "対象ファイル件数"
            $item["内容"] = "見出しは $declared 件、読み取れた一覧は $($files.Count) 件"
            $issues.Add($item)
        }
    }
    return @{ Files = $files; Issues = $issues; Notes = $notes; Declared = $declared; HeaderCount = $headerCount }
}

function Get-Summary {
    param($Lines, [int]$Start, [int]$End)
    $rows = New-Object System.Collections.Generic.List[object]
    $total = $null
    $stats = New-Object System.Collections.Generic.List[object]
    $statuses = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    $idx = $Start
    while ($idx -lt $End -and -not $Lines[$idx].StartsWith(" 件数（コンテナ")) { $idx++ }
    if ($idx -ge $End) {
        return @{ Rows = $rows; Total = $total; Stats = $stats; Statuses = $statuses; Notes = $notes }
    }
    $idx++
    while ($idx -lt $End -and -not (Test-Hr $Lines[$idx])) {
        $line = $Lines[$idx]
        $idx++
        if ($line -eq "" -or (Test-Thin $line)) { continue }
        $match = $Script:SumRe.Match($line)
        if ($match.Success) {
            $item = Get-Metrics $match.Groups[3].Value
            $item["コンテナ"] = $match.Groups[1].Value
            $item["ECSサービス"] = $match.Groups[2].Value
            $item["合計"] = [int]$match.Groups[4].Value
            $rows.Add($item)
            continue
        }
        $match = $Script:TotalRe.Match($line)
        if ($match.Success) {
            $total = Get-Metrics $match.Groups[1].Value
            $total["コンテナ"] = "合計"
            $total["ECSサービス"] = ""
            $total["表示"] = [int]$match.Groups[2].Value
            $sum = 0
            foreach ($key in @($total.Keys)) {
                if ($key -ne "表示" -and $total[$key] -is [int]) { $sum += $total[$key] }
            }
            $total["合計"] = $sum
            continue
        }
        $match = $Script:HttpRe.Match($line)
        if ($match.Success) {
            $statuses.Add(@("HTTP", $match.Groups[1].Value, [int]$match.Groups[2].Value))
            continue
        }
        $match = $Script:LevelRe.Match($line)
        if ($match.Success) {
            $statuses.Add(@("レベル", $match.Groups[1].Value, [int]$match.Groups[2].Value))
            continue
        }
        $stripped = $line.Trim()
        if ($stripped -eq "ステータス内訳") { continue }
        if ($stripped -eq "集計するファイルがありません。") {
            $notes.Add($stripped)
            continue
        }
        $match = $Script:KvRe.Match($line)
        if ($match.Success) {
            $stats.Add(@($match.Groups[1].Value.Trim(), $match.Groups[2].Value.Trim()))
            continue
        }
        if ($stripped) { $notes.Add($stripped) }
    }
    return @{ Rows = $rows; Total = $total; Stats = $stats; Statuses = $statuses; Notes = $notes }
}

function New-Record {
    param($Columns)
    $record = @{}
    foreach ($column in $Columns) { $record[$column[0]] = "" }
    return $record
}

function ConvertFrom-ServerBody {
    param($Body)
    $record = New-Record $Script:ServerCols
    if ($Body.Count -lt 4) {
        $record["メッセージ"] = ($Body -join "`n")
        return @{ Record = $record; Warning = "server.log の明細が4行未満です" }
    }
    $head = $Body[0]; $meta = $Body[1]; $task = $Body[2]; $path = $Body[3]
    $headM = [regex]::Match($head, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) {2}\[([A-Za-z]+)\] {2}(.*)$')
    $metaM = [regex]::Match($meta, '^コンテナ: (\S+)\s{2,}ECSサービス: (\S+)\s{2,}種別: (\S+)$')
    $taskM = [regex]::Match($task, '^タスク: (.*)$')
    $pathM = [regex]::Match($path, '^パス: (.*)$')
    if (-not ($headM.Success -and $metaM.Success -and $taskM.Success -and $pathM.Success)) {
        $record["メッセージ"] = ($Body -join "`n")
        return @{ Record = $record; Warning = "server.log の明細の並びを読めませんでした" }
    }
    $record["時刻 (JST)"] = $headM.Groups[1].Value
    $record["レベル"] = $headM.Groups[2].Value
    $record["ファイル"] = $headM.Groups[3].Value.Trim()
    $record["コンテナ"] = $metaM.Groups[1].Value
    $record["ECSサービス"] = $metaM.Groups[2].Value
    $record["種別"] = $metaM.Groups[3].Value
    $record["タスク"] = $taskM.Groups[1].Value
    $record["パス"] = $pathM.Groups[1].Value
    $messages = New-Object System.Collections.Generic.List[string]
    $stacks = New-Object System.Collections.Generic.List[string]
    for ($i = 4; $i -lt $Body.Count; $i++) {
        if ($Body[$i].StartsWith("  ")) { $stacks.Add($Body[$i].Substring(2)) }
        else { $messages.Add($Body[$i]) }
    }
    $record["メッセージ"] = ($messages -join "`n")
    $record["スタックトレース"] = ($stacks -join "`n")
    return @{ Record = $record; Warning = $null }
}

function Set-RequestLine {
    param($Record, [string]$Line)
    $proto = ""
    $match = [regex]::Match($Line, '^(.*) {2}(HTTP/[0-9.]+)$')
    if ($match.Success) {
        $Line = $match.Groups[1].Value
        $proto = $match.Groups[2].Value
    }
    $methodM = [regex]::Match($Line, '^(GET|HEAD|POST|PUT|DELETE|CONNECT|OPTIONS|TRACE|PATCH)(?: {2}(.*))?$')
    if ($methodM.Success) {
        $Record["メソッド"] = $methodM.Groups[1].Value
        $uri = $methodM.Groups[2].Value
        if ($null -eq $uri) { $uri = "" }
        $Record["URI"] = $uri
    } else {
        $Record["URI"] = $Line
    }
    $Record["プロトコル"] = $proto
}

function Test-RequestLine {
    param([string]$Line)
    if ($Line -match '^(GET|HEAD|POST|PUT|DELETE|CONNECT|OPTIONS|TRACE|PATCH)( {2}|$)') { return $true }
    if ($Line -match ' {2}HTTP/[0-9.]+$') { return $true }
    if ($Line.StartsWith("/") -or $Line.StartsWith("http://") -or $Line.StartsWith("https://")) { return $true }
    return $false
}

function Test-BitsLine {
    param([string]$Line)
    $parts = [regex]::Split($Line, ' {4}')
    $keys = @("クライアント: ", "ユーザ: ", "応答バイト: ", "処理時間: ")
    if ($parts.Count -eq 0) { return $false }
    foreach ($part in $parts) {
        $ok = $false
        foreach ($key in $keys) { if ($part.StartsWith($key)) { $ok = $true } }
        if (-not $ok) { return $false }
    }
    return $true
}

function Set-Bits {
    param($Record, [string]$Line)
    foreach ($part in [regex]::Split($Line, ' {4}')) {
        if ($part.StartsWith("クライアント: ")) { $Record["クライアント"] = $part.Substring("クライアント: ".Length) }
        elseif ($part.StartsWith("ユーザ: ")) { $Record["ユーザ"] = $part.Substring("ユーザ: ".Length) }
        elseif ($part.StartsWith("応答バイト: ")) { $Record["応答バイト"] = $part.Substring("応答バイト: ".Length) }
        elseif ($part.StartsWith("処理時間: ")) { $Record["処理時間"] = $part.Substring("処理時間: ".Length) }
    }
}

function ConvertFrom-AccessBody {
    param($Body)
    $record = New-Record $Script:AccessCols
    if ($Body.Count -lt 2) {
        $record["メッセージ"] = ($Body -join "`n")
        return @{ Record = $record; Warning = "access_log の明細が2行未満です" }
    }
    $parts = @([regex]::Split($Body[0], ' {2,}'))
    $metaM = [regex]::Match($Body[1], '^種別: (\S+)\s{2,}タスク: (.*)$')
    if ($parts.Count -lt 4 -or -not $metaM.Success) {
        $record["メッセージ"] = ($Body -join "`n")
        return @{ Record = $record; Warning = "access_log の明細の並びを読めませんでした" }
    }
    $ts = $parts[0]; $badge = $parts[1]; $pair = $parts[2]; $label = $parts[3]
    $pairM = [regex]::Match($pair, '^(\S+) / (\S+)$')
    $tsM = [regex]::Match($ts, '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$')
    if (-not ($pairM.Success -and $tsM.Success -and $Script:ClassByLabel.ContainsKey($label))) {
        $record["メッセージ"] = ($Body -join "`n")
        return @{ Record = $record; Warning = "access_log の見出し行を読めませんでした" }
    }
    $record["時刻 (JST)"] = $ts
    $record["区分"] = $label
    $record["コンテナ"] = $pairM.Groups[1].Value
    $record["ECSサービス"] = $pairM.Groups[2].Value
    $httpM = [regex]::Match($badge, '^\[HTTP ([1-5][0-9]{2})\]$')
    $levelM = [regex]::Match($badge, '^\[([A-Za-z]+)\]$')
    if ($httpM.Success) { $record["HTTPステータス"] = $httpM.Groups[1].Value }
    elseif ($levelM.Success -and $levelM.Groups[1].Value -ne "不明") { $record["レベル"] = $levelM.Groups[1].Value }
    $record["種別"] = $metaM.Groups[1].Value
    $record["タスク"] = $metaM.Groups[2].Value
    $unlabeled = New-Object System.Collections.Generic.List[string]
    for ($i = 2; $i -lt $Body.Count; $i++) {
        $line = $Body[$i]
        if ($line.StartsWith("Referer: ")) { $record["Referer"] = $line.Substring("Referer: ".Length) }
        elseif ($line.StartsWith("UA: ")) { $record["UA"] = $line.Substring("UA: ".Length) }
        elseif ($line.StartsWith("追加: ")) { $record["追加"] = $line.Substring("追加: ".Length) }
        elseif ($line.StartsWith("元の時刻: ")) { $record["元の時刻"] = $line.Substring("元の時刻: ".Length) }
        elseif ($line.StartsWith("ファイル: ")) { $record["ファイル"] = $line.Substring("ファイル: ".Length) }
        elseif ($line.StartsWith("パス: ")) { $record["パス"] = $line.Substring("パス: ".Length) }
        elseif ($line.StartsWith("生ログ: ")) { $record["生ログ"] = $line.Substring("生ログ: ".Length) }
        elseif (Test-BitsLine $line) { Set-Bits $record $line }
        else { $unlabeled.Add($line) }
    }
    foreach ($line in $unlabeled) {
        if ($record["メソッド"] -eq "" -and $record["URI"] -eq "" -and (Test-RequestLine $line)) {
            Set-RequestLine $record $line
        } elseif ($record["メッセージ"] -eq "") {
            $record["メッセージ"] = $line
        } else {
            $record["メッセージ"] = $record["メッセージ"] + "`n" + $line
        }
    }
    return @{ Record = $record; Warning = $null }
}

function Set-GcMeta {
    param($Record, [string]$Line)
    foreach ($part in [regex]::Split($Line, ' {4}')) {
        if ($part.StartsWith("原因: ")) { $Record["原因"] = $part.Substring("原因: ".Length) }
        elseif ($part.StartsWith("GC番号: ")) { $Record["GC番号"] = $part.Substring("GC番号: ".Length) }
        elseif ($part.StartsWith("ファイル: ")) { $Record["ファイル"] = $part.Substring("ファイル: ".Length) }
    }
}

function ConvertFrom-GcBody {
    param($Body)
    $record = New-Record $Script:GcCols
    if ($Body.Count -eq 0) {
        return @{ Record = $record; Warning = "gc.log の明細が空です" }
    }
    $parts = @([regex]::Split($Body[0], ' {2,}'))
    if ($parts.Count -lt 3) {
        $record["ログ"] = ($Body -join "`n")
        return @{ Record = $record; Warning = "gc.log の見出し行を読めませんでした" }
    }
    $ts = $parts[0]
    $badge = $parts[1]
    $pair = $parts[$parts.Count - 1]
    $tsM = [regex]::Match($ts, '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$')
    $badgeM = [regex]::Match($badge, '^\[([A-Za-z]+)\]$')
    $pairM = [regex]::Match($pair, '^(\S+) / (\S+)$')
    if (-not ($tsM.Success -and $badgeM.Success -and $pairM.Success)) {
        $record["ログ"] = ($Body -join "`n")
        return @{ Record = $record; Warning = "gc.log の見出し行を読めませんでした" }
    }
    $record["時刻 (JST)"] = $ts
    $record["レベル"] = $badgeM.Groups[1].Value
    $record["コンテナ"] = $pairM.Groups[1].Value
    $record["ECSサービス"] = $pairM.Groups[2].Value
    for ($i = 2; $i -lt ($parts.Count - 1); $i++) {
        $token = $parts[$i]
        if ($token.StartsWith("停止 ")) { $record["停止"] = $token.Substring("停止 ".Length) }
        elseif ($token.StartsWith("ヒープ ")) { $record["ヒープ"] = $token.Substring("ヒープ ".Length) }
        elseif ($record["イベント"] -eq "") { $record["イベント"] = $token }
        else { $record["イベント"] = $record["イベント"] + " " + $token }
    }
    $cont = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -lt $Body.Count; $i++) {
        $line = $Body[$i]
        if ($line -match '^コンテナ: \S+\s{2,}ECSサービス: ') {
            $metaM = [regex]::Match($line, '^コンテナ: (\S+)\s{2,}ECSサービス: (\S+)\s{2,}種別: (\S+)\s{2,}タスク: (.*)$')
            if ($metaM.Success) {
                $record["コンテナ"] = $metaM.Groups[1].Value
                $record["ECSサービス"] = $metaM.Groups[2].Value
                $record["種別"] = $metaM.Groups[3].Value
                $record["タスク"] = $metaM.Groups[4].Value
            }
            continue
        }
        if ($line.StartsWith("原因: ") -or $line.StartsWith("GC番号: ") -or $line.StartsWith("ファイル: ") -or $line.Contains("    ファイル: ") -or $line.Contains("    原因: ") -or $line.Contains("    GC番号: ")) {
            Set-GcMeta $record $line
            continue
        }
        if ($line.StartsWith("元時刻: ")) { $record["元時刻"] = $line.Substring("元時刻: ".Length); continue }
        if ($line.StartsWith("パス: ")) { $record["パス"] = $line.Substring("パス: ".Length); continue }
        if ($line.StartsWith("ログ: ")) { $record["ログ"] = $line.Substring("ログ: ".Length); continue }
        if ($line.StartsWith("  ")) { $cont.Add($line.Substring(2)); continue }
        if ($record["ログ"] -eq "") { $record["ログ"] = $line }
        else { $cont.Add($line) }
    }
    $record["継続行"] = ($cont -join "`n")
    return @{ Record = $record; Warning = $null }
}

function Get-Body {
    param($Lines, [int]$Index, [int]$End)
    $body = New-Object System.Collections.Generic.List[string]
    while ($Index -lt $End) {
        $line = $Lines[$Index]
        if ($Script:RecRe.IsMatch($line) -or $line.StartsWith(" 件数（コンテナ")) { break }
        if (Test-Hr $line) {
            $nxt = $Index + 1
            while ($nxt -lt $End -and $Lines[$nxt] -eq "") { $nxt++ }
            if ($nxt -lt $End -and $Lines[$nxt].StartsWith(" 件数（コンテナ")) { break }
            $Index++
            continue
        }
        if ($line -eq "" -or $Script:NoiseRe.IsMatch($line)) {
            $Index++
            continue
        }
        if ($line.StartsWith("| ")) { $body.Add($line.Substring(2)) }
        elseif ($line -eq "|") { $body.Add("") }
        elseif ($body.Count -gt 0) { $body[$body.Count - 1] = $body[$body.Count - 1] + $line.Trim() }
        $Index++
    }
    return @{ Body = $body; Index = $Index }
}

function ConvertFrom-Report {
    param($Lines, [int]$Start, [int]$End, [string]$SourceName, [int]$Run)
    $kind = Get-Kind $Lines[$Start + 1]
    $report = @{
        Kind = $kind
        Source = $SourceName
        Run = $Run
        Conditions = New-Object System.Collections.Generic.List[object]
        DeclaredFiles = $null
        Files = @()
        Issues = @()
        Notes = New-Object System.Collections.Generic.List[string]
        Warnings = New-Object System.Collections.Generic.List[string]
        Records = New-Object System.Collections.Generic.List[object]
        SummaryRows = @()
        SummaryTotal = $null
        Stats = @()
        Statuses = @()
        HeaderCount = $null
    }
    $idx = $Start + 3
    while ($idx -lt $End -and -not (Test-Hr $Lines[$idx])) {
        $match = $Script:FieldRe.Match($Lines[$idx])
        if ($match.Success) {
            $report.Conditions.Add(@($match.Groups[1].Value.Trim(), $match.Groups[2].Value.Trim()))
        }
        $idx++
    }
    if ($idx -lt $End -and (Test-Hr $Lines[$idx])) { $idx++ }
    $prefaceEnd = $idx
    while ($prefaceEnd -lt $End) {
        if ($Script:RecRe.IsMatch($Lines[$prefaceEnd]) -or $Lines[$prefaceEnd].StartsWith(" 件数（コンテナ")) { break }
        $prefaceEnd++
    }
    $preface = Get-Preface $Lines $idx $prefaceEnd
    $report.Files = $preface.Files
    $report.Issues = $preface.Issues
    foreach ($note in $preface.Notes) { $report.Notes.Add($note) }
    $report.DeclaredFiles = $preface.Declared
    $report.HeaderCount = $preface.HeaderCount
    $idx = $prefaceEnd
    while ($idx -lt $End -and -not $Lines[$idx].StartsWith(" 件数（コンテナ")) {
        $match = $Script:RecRe.Match($Lines[$idx])
        if ($match.Success) {
            $number = [int]$match.Groups[1].Value
            $got = Get-Body $Lines ($idx + 1) $End
            $idx = $got.Index
            if ($kind -eq "server") { $parsed = ConvertFrom-ServerBody $got.Body }
            elseif ($kind -eq "access") { $parsed = ConvertFrom-AccessBody $got.Body }
            else { $parsed = ConvertFrom-GcBody $got.Body }
            $parsed.Record["No"] = $number
            $parsed.Record["実行"] = $Run
            $parsed.Record["入力ファイル"] = $SourceName
            $report.Records.Add($parsed.Record)
            if ($parsed.Warning) { $report.Warnings.Add("#$number $($parsed.Warning)") }
            continue
        }
        $idx++
    }
    $summary = Get-Summary $Lines $idx $End
    $report.SummaryRows = $summary.Rows
    $report.SummaryTotal = $summary.Total
    $report.Stats = $summary.Stats
    $report.Statuses = $summary.Statuses
    foreach ($note in $summary.Notes) { $report.Notes.Add($note) }
    if ($null -ne $report.HeaderCount -and $report.HeaderCount -ne $report.Records.Count) {
        $report.Warnings.Add("アクセスログ見出しは $($report.HeaderCount) 件、読み取った明細は $($report.Records.Count) 件です")
    }
    return $report
}

function Find-Reports {
    param($Lines, [string]$SourceName, $Counters)
    $starts = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt ($Lines.Count - 2); $i++) {
        if ((Test-Hr $Lines[$i]) -and $Script:TitleRe.IsMatch($Lines[$i + 1]) -and (Test-Hr $Lines[$i + 2])) {
            $starts.Add($i)
        }
    }
    $reports = New-Object System.Collections.Generic.List[object]
    for ($pos = 0; $pos -lt $starts.Count; $pos++) {
        $start = $starts[$pos]
        $end = $Lines.Count
        if ($pos + 1 -lt $starts.Count) { $end = $starts[$pos + 1] }
        $kind = Get-Kind $Lines[$start + 1]
        $Counters[$kind] = [int]$Counters[$kind] + 1
        $reports.Add((ConvertFrom-Report $Lines $start $end $SourceName ([int]$Counters[$kind])))
    }
    return ,$reports
}

function Get-SourceLabel {
    param([string]$FullName, $All)
    $name = [IO.Path]::GetFileName($FullName)
    $same = @($All | Where-Object { [IO.Path]::GetFileName($_) -eq $name })
    if ($same.Count -gt 1) {
        return ([IO.Path]::GetFileName([IO.Path]::GetDirectoryName($FullName)) + "/" + $name)
    }
    return $name
}

function Expand-Inputs {
    param([string[]]$RawPaths)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $RawPaths) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        if (Test-Path -LiteralPath $raw -PathType Container) {
            $children = @(Get-ChildItem -LiteralPath $raw -File | Where-Object { $_.Extension -match '^\.(log|txt)$' } | Sort-Object -Property Name)
            if ($children.Count -eq 0) { Fail "ログファイルがありません: $raw" }
            foreach ($child in $children) { $found.Add($child.FullName) }
        } elseif (Test-Path -LiteralPath $raw -PathType Leaf) {
            if ([IO.Path]::GetExtension($raw).ToLowerInvariant() -eq ".xlsx") { Fail "xlsx は入力にできません: $raw" }
            $found.Add((Resolve-Path -LiteralPath $raw).Path)
        } else {
            Fail "見つかりません: $raw"
        }
    }
    if ($found.Count -eq 0) { Fail "ログファイルを指定してください。" }
    return ,$found
}

function Read-Sources {
    param($Paths)
    $sources = New-Object System.Collections.Generic.List[object]
    $counters = @{ server = 0; access = 0; gc = 0 }
    foreach ($path in $Paths) {
        $bytes = [IO.File]::ReadAllBytes($path)
        $decoded = Get-DecodedText $bytes
        $label = Get-SourceLabel $path $Paths
        $lines = ConvertTo-Lines $decoded.Text
        $reports = Find-Reports $lines $label $counters
        $sources.Add(@{
            Path = $path
            Label = $label
            Encoding = $decoded.Encoding
            Size = $bytes.Length
            Reports = $reports
        })
    }
    return ,$sources
}

function Get-Condition {
    param($Report, [string]$Label)
    foreach ($pair in $Report.Conditions) {
        if ($pair[0] -eq $Label) { return $pair[1] }
    }
    return ""
}

function Get-Severity {
    param($Kind, $Record)
    $word = ""
    if ($Kind -eq "access") { $word = [string]$Record["区分"] }
    else { $word = [string]$Record["レベル"] }
    if ($Script:ErrorWords.ContainsKey($word)) { return "error" }
    if ($Script:WarnWords.ContainsKey($word)) { return "warn" }
    return "normal"
}

function Get-SeverityCount {
    param($Kind, $Records, [string]$Level)
    $count = 0
    foreach ($record in $Records) {
        if ((Get-Severity $Kind $record) -eq $Level) { $count++ }
    }
    return $count
}

function Test-NeedsExtra {
    param($Reports)
    if ((Get-Count $Reports) -gt 1) { return $true }
    $names = @{}
    foreach ($report in $Reports) { $names[$report.Source] = $true }
    return $names.Count -gt 1
}

function Get-DetailColumns {
    param($Kind, [bool]$WithRun)
    $cols = New-Object System.Collections.Generic.List[object]
    $base = $Script:Cols[$Kind]
    if ($WithRun) {
        $cols.Add($base[0])
        foreach ($spec in $Script:ExtraCols) { $cols.Add($spec) }
        for ($i = 1; $i -lt $base.Count; $i++) { $cols.Add($base[$i]) }
    } else {
        foreach ($column in $base) { $cols.Add($column) }
    }
    return ,$cols
}

function Get-ReportsOf {
    param($Sources, [string]$Kind)
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($source in $Sources) {
        foreach ($report in $source.Reports) {
            if ($report.Kind -eq $Kind) { $found.Add($report) }
        }
    }
    return ,$found
}

function Get-ColumnLetter {
    param([int]$Number)
    $letters = ""
    while ($Number -gt 0) {
        $Number--
        $rem = $Number % 26
        $Number = [int][Math]::Floor($Number / 26)
        $letters = ([char](65 + $rem)) + $letters
    }
    return $letters
}

function Get-RowHeight {
    param($Values, $Columns)
    $lines = 1
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $column = $Columns[$i]
        $wrap = [bool]$column[2]
        $width = [int]$column[4]
        if (-not $wrap) { continue }
        $value = $Values[$i]
        if ($null -eq $value -or [string]$value -eq "") { continue }
        $needed = 0
        foreach ($part in ([string]$value).Split("`n")) {
            $weight = 0
            foreach ($ch in $part.ToCharArray()) {
                if ([int]$ch -gt 127) { $weight += 2 } else { $weight += 1 }
            }
            $cap = [Math]::Max($width - 1, 4)
            $needed += [Math]::Max(1, [int][Math]::Ceiling($weight / [double]$cap))
        }
        if ($needed -gt $lines) { $lines = $needed }
    }
    return [Math]::Min(120, [Math]::Max(18, $lines * 15))
}

function New-StyleBook {
    $book = @{
        Fonts = New-Object System.Collections.Generic.List[object]
        Fills = New-Object System.Collections.Generic.List[object]
        Borders = New-Object System.Collections.Generic.List[string]
        Xfs = New-Object System.Collections.Generic.List[object]
        FontCache = @{}
        FillCache = @{}
        BorderCache = @{ none = 0 }
        XfCache = @{}
    }
    $book.Fills.Add(@{ Pattern = "none"; Rgb = $null })
    $book.Fills.Add(@{ Pattern = "gray125"; Rgb = $null })
    $book.Borders.Add("none")
    Add-BookFont $book 10 $false "FF1F1F1F" $false | Out-Null
    $book.Xfs.Add(@{ Font = 0; Fill = 0; Border = 0; Align = "left"; Valign = "center"; Wrap = $false; Num = 0; ApplyNum = $false })
    return $book
}

function Add-BookFont {
    param($Book, [int]$Size, [bool]$Bold, [string]$Color, [bool]$Italic)
    $key = "$Size|$Bold|$Color|$Italic"
    if ($Book.FontCache.ContainsKey($key)) { return [int]$Book.FontCache[$key] }
    $index = $Book.Fonts.Count
    $Book.Fonts.Add(@{ Size = $Size; Bold = $Bold; Color = $Color; Italic = $Italic })
    $Book.FontCache[$key] = $index
    return $index
}

function Add-BookFill {
    param($Book, [string]$Rgb)
    if ([string]::IsNullOrEmpty($Rgb)) { return 0 }
    if ($Book.FillCache.ContainsKey($Rgb)) { return [int]$Book.FillCache[$Rgb] }
    $index = $Book.Fills.Count
    $Book.Fills.Add(@{ Pattern = "solid"; Rgb = $Rgb })
    $Book.FillCache[$Rgb] = $index
    return $index
}

function Add-BookBorder {
    param($Book, [string]$Kind)
    if ($Book.BorderCache.ContainsKey($Kind)) { return [int]$Book.BorderCache[$Kind] }
    $index = $Book.Borders.Count
    $Book.Borders.Add($Kind)
    $Book.BorderCache[$Kind] = $index
    return $index
}

function Get-StyleId {
    param(
        $Book, [int]$Size = 10, [bool]$Bold = $false, [string]$Color = "FF1F1F1F",
        [string]$Fill = "", [string]$Border = "thin", [string]$Align = "left",
        [string]$Valign = "center", [bool]$Wrap = $false, [int]$Num = 0, [bool]$Italic = $false
    )
    $key = "$Size|$Bold|$Color|$Fill|$Border|$Align|$Valign|$Wrap|$Num|$Italic"
    if ($Book.XfCache.ContainsKey($key)) { return [int]$Book.XfCache[$key] }
    $fontId = Add-BookFont $Book $Size $Bold $Color $Italic
    $fillId = Add-BookFill $Book $Fill
    $borderId = Add-BookBorder $Book $Border
    $index = $Book.Xfs.Count
    $Book.Xfs.Add(@{
        Font = $fontId; Fill = $fillId; Border = $borderId; Align = $Align; Valign = $Valign
        Wrap = $Wrap; Num = $Num; ApplyNum = ($Num -ne 0)
    })
    $Book.XfCache[$key] = $index
    return $index
}

function Get-StylesXml {
    param($Book)
    $fonts = New-Object System.Text.StringBuilder
    foreach ($font in $Book.Fonts) {
        $parts = New-Object System.Text.StringBuilder
        if ($font.Bold) { [void]$parts.Append("<b/>") }
        [void]$parts.Append("<sz val=`"$($font.Size)`"/>")
        [void]$parts.Append("<color rgb=`"$($font.Color)`"/>")
        if ($font.Italic) { [void]$parts.Append("<i/>") }
        [void]$parts.Append("<name val=`"Meiryo UI`"/>")
        [void]$parts.Append("<family val=`"2`"/>")
        [void]$parts.Append("<charset val=`"128`"/>")
        [void]$fonts.Append("<font>$($parts.ToString())</font>")
    }
    $fills = New-Object System.Text.StringBuilder
    foreach ($fill in $Book.Fills) {
        if ($fill.Pattern -eq "gray125") {
            [void]$fills.Append("<fill><patternFill patternType=`"gray125`"/></fill>")
        } elseif ($fill.Pattern -eq "solid" -and $fill.Rgb) {
            [void]$fills.Append("<fill><patternFill patternType=`"solid`"><fgColor rgb=`"$($fill.Rgb)`"/><bgColor indexed=`"64`"/></patternFill></fill>")
        } else {
            [void]$fills.Append("<fill><patternFill patternType=`"none`"/></fill>")
        }
    }
    $borders = New-Object System.Text.StringBuilder
    foreach ($kind in $Book.Borders) {
        if ($kind -eq "none") {
            [void]$borders.Append("<border><left/><right/><top/><bottom/><diagonal/></border>")
        } elseif ($kind -eq "header") {
            $color = "<color rgb=`"FFB5B5B5`"/>"
            $bottom = "<color rgb=`"FF4A4A4A`"/>"
            [void]$borders.Append("<border><left style=`"thin`">$color</left><right style=`"thin`">$color</right><top style=`"thin`">$color</top><bottom style=`"medium`">$bottom</bottom><diagonal/></border>")
        } else {
            $color = "<color rgb=`"FFB5B5B5`"/>"
            [void]$borders.Append("<border><left style=`"thin`">$color</left><right style=`"thin`">$color</right><top style=`"thin`">$color</top><bottom style=`"thin`">$color</bottom><diagonal/></border>")
        }
    }
    $xfs = New-Object System.Text.StringBuilder
    foreach ($xf in $Book.Xfs) {
        $applyFill = 0
        if ([int]$xf.Fill -ne 0) { $applyFill = 1 }
        $applyBorder = 0
        if ([int]$xf.Border -ne 0) { $applyBorder = 1 }
        $applyNum = 0
        if ($xf.ApplyNum) { $applyNum = 1 }
        $wrap = 0
        if ($xf.Wrap) { $wrap = 1 }
        [void]$xfs.Append("<xf numFmtId=`"$($xf.Num)`" fontId=`"$($xf.Font)`" fillId=`"$($xf.Fill)`" borderId=`"$($xf.Border)`" xfId=`"0`" applyFont=`"1`" applyFill=`"$applyFill`" applyBorder=`"$applyBorder`" applyAlignment=`"1`" applyNumberFormat=`"$applyNum`"><alignment horizontal=`"$($xf.Align)`" vertical=`"$($xf.Valign)`" wrapText=`"$wrap`"/></xf>")
    }
    return "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>" +
        "<styleSheet xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`">" +
        "<fonts count=`"$($Book.Fonts.Count)`">$($fonts.ToString())</fonts>" +
        "<fills count=`"$($Book.Fills.Count)`">$($fills.ToString())</fills>" +
        "<borders count=`"$($Book.Borders.Count)`">$($borders.ToString())</borders>" +
        "<cellStyleXfs count=`"1`"><xf numFmtId=`"0`" fontId=`"0`" fillId=`"0`" borderId=`"0`"/></cellStyleXfs>" +
        "<cellXfs count=`"$($Book.Xfs.Count)`">$($xfs.ToString())</cellXfs>" +
        "<cellStyles count=`"1`"><cellStyle name=`"Normal`" xfId=`"0`" builtinId=`"0`"/></cellStyles>" +
        "</styleSheet>"
}

function Test-Preserve {
    param($Value)
    if ($null -eq $Value) { return $false }
    $text = [string]$Value
    return $text.StartsWith(" ") -or $text.EndsWith(" ") -or $text.Contains("`n") -or $text.Contains("  ")
}

function ConvertTo-XmlText {
    param([string]$Text)
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("`n", "&#10;")
}

function ConvertTo-CellXml {
    param([string]$Ref, $Value, [int]$Style, [bool]$Numeric)
    if ($Numeric -and $null -ne $Value -and [string]$Value -ne "") {
        return "<c r=`"$Ref`" s=`"$Style`"><v>$([int]$Value)</v></c>"
    }
    if ($null -eq $Value -or [string]$Value -eq "") {
        return "<c r=`"$Ref`" s=`"$Style`"/>"
    }
    $text = Clean-Text $Value
    $space = ""
    if (Test-Preserve $text) { $space = " xml:space=`"preserve`"" }
    $escaped = ConvertTo-XmlText $text
    return "<c r=`"$Ref`" t=`"inlineStr`" s=`"$Style`"><is><t$space>$escaped</t></is></c>"
}

function ConvertTo-SheetXml {
    param($Sheet, [bool]$Selected)
    $cols = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Sheet.Widths.Count; $i++) {
        $n = $i + 1
        [void]$cols.Append("<col min=`"$n`" max=`"$n`" width=`"$($Sheet.Widths[$i])`" customWidth=`"1`"/>")
    }
    $rows = New-Object System.Text.StringBuilder
    for ($r = 0; $r -lt $Sheet.Rows.Count; $r++) {
        $cells = New-Object System.Text.StringBuilder
        $row = $Sheet.Rows[$r]
        for ($c = 0; $c -lt $row.Count; $c++) {
            $ref = "$(Get-ColumnLetter ($c + 1))$($r + 1)"
            $cell = $row[$c]
            [void]$cells.Append((ConvertTo-CellXml $ref $cell.Value ([int]$cell.Style) ([bool]$cell.Numeric)))
        }
        $heightXml = ""
        $key = [string]($r + 1)
        if ($Sheet.Heights.ContainsKey($key)) { $heightXml = " ht=`"$($Sheet.Heights[$key])`" customHeight=`"1`"" }
        [void]$rows.Append("<row r=`"$($r + 1)`"$heightXml>$($cells.ToString())</row>")
    }
    $merges = ""
    if ($Sheet.Merges.Count -gt 0) {
        $items = New-Object System.Text.StringBuilder
        foreach ($ref in $Sheet.Merges) { [void]$items.Append("<mergeCell ref=`"$ref`"/>") }
        $merges = "<mergeCells count=`"$($Sheet.Merges.Count)`">$($items.ToString())</mergeCells>"
    }
    $auto = ""
    if ($Sheet.Filter) { $auto = "<autoFilter ref=`"$($Sheet.Filter)`"/>" }
    $freeze = ""
    if ($Sheet.Freeze) {
        $next = [int]$Sheet.Freeze + 1
        $freeze = "<pane ySplit=`"$($Sheet.Freeze)`" topLeftCell=`"A$next`" activePane=`"bottomLeft`" state=`"frozen`"/><selection pane=`"bottomLeft`" activeCell=`"A$next`" sqref=`"A$next`"/>"
    }
    $selectedXml = ""
    if ($Selected) { $selectedXml = " tabSelected=`"1`"" }
    $lastCol = Get-ColumnLetter ([Math]::Max(1, $Sheet.Widths.Count))
    $lastRow = [Math]::Max(1, $Sheet.Rows.Count)
    $header = "&amp;L&amp;&quot;Meiryo UI,Standard&quot;&amp;9JBoss EAP ログ検索レポート&amp;C&amp;A&amp;R&amp;D &amp;T"
    $footer = "&amp;L&amp;F&amp;C&amp;P / &amp;N&amp;R&amp;&quot;Meiryo UI,Standard&quot;&amp;9モノトーン"
    return "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>" +
        "<worksheet xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`" xmlns:r=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships`">" +
        "<sheetPr><tabColor rgb=`"$($Sheet.Tab)`"/><pageSetUpPr fitToPage=`"1`"/></sheetPr>" +
        "<dimension ref=`"A1:$lastCol$lastRow`"/>" +
        "<sheetViews><sheetView workbookViewId=`"0`" showGridLines=`"0`" zoomScale=`"100`"$selectedXml>$freeze</sheetView></sheetViews>" +
        "<sheetFormatPr defaultRowHeight=`"18`" customHeight=`"1`"/>" +
        "<cols>$($cols.ToString())</cols><sheetData>$($rows.ToString())</sheetData>" +
        "$auto$merges" +
        "<printOptions horizontalCentered=`"0`"/>" +
        "<pageMargins left=`"0.4`" right=`"0.4`" top=`"0.65`" bottom=`"0.5`" header=`"0.28`" footer=`"0.28`"/>" +
        "<pageSetup orientation=`"landscape`" paperSize=`"$($Sheet.Paper)`" fitToWidth=`"1`" fitToHeight=`"0`" pageOrder=`"down`"/>" +
        "<headerFooter><oddHeader>$header</oddHeader><oddFooter>$footer</oddFooter></headerFooter>" +
        "</worksheet>"
}

function New-Sheet {
    param([string]$Name, [string]$Tab, $Widths, [string]$Paper = "8")
    return @{
        Name = $Name
        Tab = $Tab
        Widths = @($Widths)
        Rows = New-Object System.Collections.Generic.List[object]
        Heights = @{}
        Merges = New-Object System.Collections.Generic.List[string]
        Filter = $null
        Freeze = 0
        Repeat = $null
        Paper = $Paper
    }
}

function Add-SheetRow {
    param($Sheet, $Cells, $Height = $null)
    $Sheet.Rows.Add(@($Cells))
    if ($null -ne $Height) { $Sheet.Heights[[string]$Sheet.Rows.Count] = $Height }
    return $Sheet.Rows.Count
}

function Add-Merge {
    param($Sheet, [int]$Row, [int]$StartCol, [int]$EndCol)
    if ($EndCol -gt $StartCol) {
        $Sheet.Merges.Add("$(Get-ColumnLetter $StartCol)${Row}:$(Get-ColumnLetter $EndCol)${Row}")
    }
}

function Get-FillColor {
    param([string]$Name)
    switch ($Name) {
        "normal" { return "FFFFFFFF" }
        "alt" { return "FFF4F4F4" }
        "error" { return "FFD9D9D9" }
        "warn" { return "FFEBEBEB" }
        "total" { return "FFC8C8C8" }
        "label" { return "FFE6E6E6" }
        default { return "FFFFFFFF" }
    }
}

function Get-DataStyle {
    param($Styles, [string]$FillName, [string]$Align, [bool]$Wrap, [bool]$Numeric, [bool]$Bold = $false)
    $num = 0
    if ($Numeric) {
        if ($Align -eq "center") { $num = 1 } else { $num = 3 }
    }
    $valign = "center"
    if ($Wrap) { $valign = "top" }
    return Get-StyleId $Styles -Bold $Bold -Fill (Get-FillColor $FillName) -Align $Align -Valign $valign -Wrap $Wrap -Num $num
}

function New-TextCell {
    param($Value, [int]$Style, [bool]$Numeric = $false)
    $use = $false
    if ($Numeric -and $null -ne $Value -and [string]$Value -ne "") { $use = $true }
    return @{ Value = $Value; Style = $Style; Numeric = $use }
}

function Add-TitleRow {
    param($Sheet, $Styles, [string]$Text, [int]$Columns)
    $style = Get-StyleId $Styles -Size 18 -Bold $true -Color "FFFFFFFF" -Fill "FF2B2B2B" -Border "none" -Align "left" -Valign "center"
    $cells = @()
    for ($i = 0; $i -lt $Columns; $i++) {
        $value = ""
        if ($i -eq 0) { $value = $Text }
        $cells += (New-TextCell $value $style)
    }
    $row = Add-SheetRow $Sheet $cells 32
    Add-Merge $Sheet $row 1 $Columns
}

function Add-SubtitleRow {
    param($Sheet, $Styles, [string]$Text, [int]$Columns)
    $style = Get-StyleId $Styles -Size 11 -Color "FFF5F5F5" -Fill "FF4A4A4A" -Border "none" -Align "left" -Valign "center" -Wrap $true
    $cells = @()
    for ($i = 0; $i -lt $Columns; $i++) {
        $value = ""
        if ($i -eq 0) { $value = $Text }
        $cells += (New-TextCell $value $style)
    }
    $row = Add-SheetRow $Sheet $cells 22
    Add-Merge $Sheet $row 1 $Columns
}

function Add-SectionRow {
    param($Sheet, $Styles, [string]$Text, [int]$Columns)
    $style = Get-StyleId $Styles -Size 12 -Bold $true -Color "FFFFFFFF" -Fill "FF595959" -Border "none" -Align "left" -Valign "center"
    $cells = @()
    for ($i = 0; $i -lt $Columns; $i++) {
        $value = ""
        if ($i -eq 0) { $value = $Text }
        $cells += (New-TextCell $value $style)
    }
    $row = Add-SheetRow $Sheet $cells 22
    Add-Merge $Sheet $row 1 $Columns
}

function New-HeaderCells {
    param($Styles, $Names)
    $style = Get-StyleId $Styles -Size 10 -Bold $true -Color "FFFFFFFF" -Fill "FF333333" -Border "header" -Align "center" -Valign "center" -Wrap $true
    $cells = @()
    foreach ($name in $Names) { $cells += (New-TextCell $name $style) }
    return ,$cells
}

function Add-BlankRow {
    param($Sheet, $Styles, [int]$Columns, [int]$Height = 8)
    $style = Get-StyleId $Styles -Border "none" -Fill "FFFFFFFF"
    $cells = @()
    for ($i = 0; $i -lt $Columns; $i++) { $cells += (New-TextCell "" $style) }
    Add-SheetRow $Sheet $cells $Height | Out-Null
}

function ConvertTo-IntOrNull {
    param($Value)
    if ($Value -is [int] -and -not ($Value -is [bool])) { return $Value }
    $text = [string]$Value
    if ($text -match '^\d+$') { return [int]$text }
    return $null
}

function New-TableRow {
    param($Styles, $Values, $Columns, [string]$FillName, [bool]$Bold = $false)
    $cells = @()
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $column = $Columns[$i]
        $align = [string]$column[1]
        $wrap = [bool]$column[2]
        $numeric = [bool]$column[3]
        $value = $Values[$i]
        $number = $null
        if ($numeric) { $number = ConvertTo-IntOrNull $value }
        $use = $null -ne $number
        $shown = $value
        if ($use) { $shown = $number }
        elseif ($null -eq $value) { $shown = "" }
        $style = Get-DataStyle $Styles $FillName $align $wrap $use $Bold
        $cells += (New-TextCell $shown $style $use)
    }
    return ,$cells
}

function Get-Subtitle {
    param($Reports, [int]$RecordCount)
    $reflects = New-Object System.Collections.Generic.List[string]
    $ends = New-Object System.Collections.Generic.List[string]
    $labels = New-Object System.Collections.Generic.List[string]
    foreach ($report in $Reports) {
        if (-not $labels.Contains($report.Source)) { $labels.Add($report.Source) }
        $reflect = Get-Condition $report "反映時刻 (JST)"
        $end = Get-Condition $report "終了時刻 (JST)"
        if ($reflect -and -not $reflects.Contains($reflect)) { $reflects.Add($reflect) }
        if ($end -and -not $ends.Contains($end)) { $ends.Add($end) }
    }
    $inputText = "なし"
    if ($labels.Count -gt 0) { $inputText = ($labels -join "、") }
    $reflectText = "なし"
    if ($reflects.Count -gt 0) { $reflectText = ($reflects -join " / ") }
    $endText = "なし"
    if ($ends.Count -gt 0) { $endText = ($ends -join " / ") }
    return "入力: $inputText    反映時刻: $reflectText    終了時刻: $endText    明細: $RecordCount 件"
}

function New-DetailSheet {
    param($Styles, [string]$Kind, $Reports)
    $extra = Test-NeedsExtra $Reports
    $columns = Get-DetailColumns $Kind $extra
    $widths = @()
    foreach ($column in $columns) { $widths += $column[4] }
    $sheet = New-Sheet "$($Script:KindName[$Kind]) 明細" "FF4A4A4A" $widths
    Add-TitleRow $sheet $Styles "$($Script:KindName[$Kind]) 明細" $columns.Count
    $records = New-Object System.Collections.Generic.List[object]
    foreach ($report in $Reports) { foreach ($record in $report.Records) { $records.Add($record) } }
    Add-SubtitleRow $sheet $Styles (Get-Subtitle $Reports $records.Count) $columns.Count
    $names = @()
    foreach ($column in $columns) { $names += $column[0] }
    $headerIndex = Add-SheetRow $sheet (New-HeaderCells $Styles $names) 32
    for ($index = 0; $index -lt $records.Count; $index++) {
        $record = $records[$index]
        $level = Get-Severity $Kind $record
        $fillName = "normal"
        if ($level -eq "error" -or $level -eq "warn") { $fillName = $level }
        elseif ($index % 2) { $fillName = "alt" }
        $values = @()
        foreach ($column in $columns) {
            $name = [string]$column[0]
            if ($record.ContainsKey($name)) { $values += $record[$name] } else { $values += "" }
        }
        Add-SheetRow $sheet (New-TableRow $Styles $values $columns $fillName) (Get-RowHeight $values $columns) | Out-Null
    }
    $last = [Math]::Max($headerIndex, $sheet.Rows.Count)
    $sheet.Filter = "A${headerIndex}:$(Get-ColumnLetter $columns.Count)$last"
    $sheet.Freeze = $headerIndex
    $sheet.Repeat = $headerIndex
    return $sheet
}

function New-FileSheet {
    param($Styles, [string]$Kind, $Reports)
    $columns = @(
        @("実行", "center", $false, $true, 8),
        @("入力ファイル", "left", $false, $false, 32),
        @("No", "center", $false, $true, 8),
        @("コンテナ", "center", $false, $false, 14),
        @("ECSサービス", "center", $false, $false, 16),
        @("種別", "center", $false, $false, 12),
        @("タスク", "left", $false, $false, 36),
        @("ファイル", "left", $false, $false, 28),
        @("パス", "left", $true, $false, 72)
    )
    $widths = @(); foreach ($column in $columns) { $widths += $column[4] }
    $sheet = New-Sheet "$($Script:KindName[$Kind]) 対象ファイル" "FF5C5C5C" $widths
    Add-TitleRow $sheet $Styles "$($Script:KindName[$Kind]) 対象ファイル" $columns.Count
    $total = 0
    foreach ($report in $Reports) { $total += (Get-Count $report.Files) }
    Add-SubtitleRow $sheet $Styles "一覧に出ているファイル: $total 件" $columns.Count
    $headerIndex = Add-SheetRow $sheet (New-HeaderCells $Styles @("実行", "入力ファイル", "No", "コンテナ", "ECSサービス", "種別", "タスク", "ファイル", "パス")) 32
    $rowIndex = 0
    foreach ($report in $Reports) {
        foreach ($item in $report.Files) {
            $values = @($report.Run, $report.Source, $item["No"], $item["コンテナ"], $item["ECSサービス"], $item["種別"], $item["タスク"], $item["ファイル"], $item["パス"])
            $fillName = "normal"
            if ($rowIndex % 2) { $fillName = "alt" }
            Add-SheetRow $sheet (New-TableRow $Styles $values $columns $fillName) (Get-RowHeight $values $columns) | Out-Null
            $rowIndex++
        }
    }
    $last = [Math]::Max($headerIndex, $sheet.Rows.Count)
    $sheet.Filter = "A${headerIndex}:$(Get-ColumnLetter $columns.Count)$last"
    $sheet.Freeze = $headerIndex
    $sheet.Repeat = $headerIndex
    return $sheet
}

function New-SummarySheet {
    param($Styles, [string]$Kind, $Reports)
    $metrics = $Script:Metrics[$Kind]
    $columns = New-Object System.Collections.Generic.List[object]
    $columns.Add(@("実行", "center", $false, $true, 8))
    $columns.Add(@("入力ファイル", "left", $false, $false, 32))
    $columns.Add(@("コンテナ", "left", $false, $false, 14))
    $columns.Add(@("ECSサービス", "left", $false, $false, 16))
    foreach ($metric in $metrics) { $columns.Add(@($metric, "right", $false, $true, 12)) }
    $columns.Add(@("合計", "right", $false, $true, 12))
    $widths = @(); foreach ($column in $columns) { $widths += $column[4] }
    $sheet = New-Sheet "$($Script:KindName[$Kind]) 集計" "FF6A6A6A" $widths
    Add-TitleRow $sheet $Styles "$($Script:KindName[$Kind]) 集計" $columns.Count
    Add-SubtitleRow $sheet $Styles "件数は検索スクリプトが表示した集計です。空欄はその行に出ていない項目です。" $columns.Count
    Add-SectionRow $sheet $Styles "件数（コンテナ / ECSサービス）" $columns.Count
    $names = @(); foreach ($column in $columns) { $names += $column[0] }
    $headerIndex = Add-SheetRow $sheet (New-HeaderCells $Styles $names) 32
    $bodyRows = 0
    foreach ($report in $Reports) {
        foreach ($item in $report.SummaryRows) {
            $values = @($report.Run, $report.Source, $item["コンテナ"], $item["ECSサービス"])
            foreach ($metric in $metrics) {
                if ($item.ContainsKey($metric)) { $values += $item[$metric] } else { $values += "" }
            }
            $values += $item["合計"]
            $fillName = "normal"
            if ($bodyRows % 2) { $fillName = "alt" }
            Add-SheetRow $sheet (New-TableRow $Styles $values $columns $fillName) | Out-Null
            $bodyRows++
        }
        if ($null -ne $report.SummaryTotal) {
            $item = $report.SummaryTotal
            $values = @($report.Run, $report.Source, "合計", "")
            foreach ($metric in $metrics) {
                if ($item.ContainsKey($metric)) { $values += $item[$metric] } else { $values += "" }
            }
            $values += $item["合計"]
            Add-SheetRow $sheet (New-TableRow $Styles $values $columns "total" $true) 20 | Out-Null
        }
    }
    $last = [Math]::Max($headerIndex, $sheet.Rows.Count)
    $sheet.Filter = "A${headerIndex}:$(Get-ColumnLetter $columns.Count)$last"
    $sheet.Freeze = $headerIndex
    $sheet.Repeat = $headerIndex
    $hasStatus = $false
    foreach ($report in $Reports) { if ((Get-Count $report.Statuses) -gt 0) { $hasStatus = $true } }
    if ($hasStatus) {
        Add-BlankRow $sheet $Styles $columns.Count
        Add-SectionRow $sheet $Styles "ステータス内訳" $columns.Count
        $statusHeader = @("実行", "入力ファイル", "種別", "値", "件数")
        while ($statusHeader.Count -lt $columns.Count) { $statusHeader += "" }
        Add-SheetRow $sheet (New-HeaderCells $Styles $statusHeader) 24 | Out-Null
        foreach ($report in $Reports) {
            foreach ($status in $report.Statuses) {
                $values = @($report.Run, $report.Source, $status[0], $status[1], $status[2])
                while ($values.Count -lt $columns.Count) { $values += "" }
                Add-SheetRow $sheet (New-TableRow $Styles $values $columns "normal") | Out-Null
            }
        }
    }
    $hasStats = $false
    foreach ($report in $Reports) { if ((Get-Count $report.Stats) -gt 0) { $hasStats = $true } }
    if ($hasStats) {
        Add-BlankRow $sheet $Styles $columns.Count
        Add-SectionRow $sheet $Styles "読み込み状況" $columns.Count
        $statHeader = @("実行", "入力ファイル", "項目", "内容")
        while ($statHeader.Count -lt $columns.Count) { $statHeader += "" }
        Add-SheetRow $sheet (New-HeaderCells $Styles $statHeader) 24 | Out-Null
        $statRow = 0
        foreach ($report in $Reports) {
            foreach ($pair in $report.Stats) {
                $number = ConvertTo-IntOrNull $pair[1]
                $shown = $pair[1]
                if ($null -ne $number) { $shown = $number }
                $values = @($report.Run, $report.Source, $pair[0], $shown)
                while ($values.Count -lt $columns.Count) { $values += "" }
                $fillName = "normal"
                if ($statRow % 2) { $fillName = "alt" }
                $statRow++
                $cells = New-TableRow $Styles $values $columns $fillName
                if ($null -eq $number) {
                    $cells[3] = New-TextCell $pair[1] (Get-DataStyle $Styles $fillName "left" $true $false) $false
                } else {
                    $cells[3] = New-TextCell $number (Get-DataStyle $Styles $fillName "right" $false $true) $true
                }
                $heightCols = @(
                    @("実行", "center", $false, $true, 8),
                    @("入力ファイル", "left", $false, $false, 32),
                    @("項目", "left", $false, $false, 28),
                    @("内容", "left", $true, $false, 72)
                )
                while ($heightCols.Count -lt $columns.Count) { $heightCols += @("空き", "left", $false, $false, 12) }
                Add-SheetRow $sheet $cells (Get-RowHeight $values $heightCols) | Out-Null
            }
        }
    }
    return $sheet
}

function New-ConditionSheet {
    param($Styles, $Sources)
    $columns = @(
        @("ログ種別", "left", $false, $false, 16),
        @("実行", "center", $false, $true, 8),
        @("入力ファイル", "left", $false, $false, 32),
        @("項目", "left", $false, $false, 24),
        @("内容", "left", $true, $false, 78)
    )
    $widths = @(); foreach ($column in $columns) { $widths += $column[4] }
    $sheet = New-Sheet "検索条件" "FF3A3A3A" $widths "9"
    Add-TitleRow $sheet $Styles "検索条件" $columns.Count
    Add-SubtitleRow $sheet $Styles "検索スクリプトが先頭に出した条件です。" $columns.Count
    $headerIndex = Add-SheetRow $sheet (New-HeaderCells $Styles @("ログ種別", "実行", "入力ファイル", "項目", "内容")) 32
    $rowIndex = 0
    foreach ($kind in $Script:KindOrder) {
        foreach ($report in (Get-ReportsOf $Sources $kind)) {
            foreach ($pair in $report.Conditions) {
                $values = @($Script:KindName[$kind], $report.Run, $report.Source, $pair[0], $pair[1])
                $fillName = "normal"
                if ($rowIndex % 2) { $fillName = "alt" }
                Add-SheetRow $sheet (New-TableRow $Styles $values $columns $fillName) (Get-RowHeight $values $columns) | Out-Null
                $rowIndex++
            }
        }
    }
    $last = [Math]::Max($headerIndex, $sheet.Rows.Count)
    $sheet.Filter = "A${headerIndex}:$(Get-ColumnLetter $columns.Count)$last"
    $sheet.Freeze = $headerIndex
    $sheet.Repeat = $headerIndex
    return $sheet
}

function New-NoteSheet {
    param($Styles, $Sources)
    $columns = @(
        @("ログ種別", "left", $false, $false, 16),
        @("実行", "center", $false, $true, 8),
        @("入力ファイル", "left", $false, $false, 32),
        @("区分", "left", $false, $false, 28),
        @("コンテナ", "center", $false, $false, 14),
        @("ECSサービス", "center", $false, $false, 16),
        @("内容", "left", $true, $false, 64),
        @("パス", "left", $true, $false, 64)
    )
    $widths = @(); foreach ($column in $columns) { $widths += $column[4] }
    $sheet = New-Sheet "確認事項" "FF7A7A7A" $widths
    Add-TitleRow $sheet $Styles "確認事項" $columns.Count
    Add-SubtitleRow $sheet $Styles "ディレクトリなし、読めないパス、省略、補足、読み取りの注意です。" $columns.Count
    $headerIndex = Add-SheetRow $sheet (New-HeaderCells $Styles @("ログ種別", "実行", "入力ファイル", "区分", "コンテナ", "ECSサービス", "内容", "パス")) 32
    $rowIndex = 0
    $any = $false
    foreach ($kind in $Script:KindOrder) {
        foreach ($report in (Get-ReportsOf $Sources $kind)) {
            foreach ($item in $report.Issues) {
                $values = @($Script:KindName[$kind], $report.Run, $report.Source, $item["区分"], $item["コンテナ"], $item["ECSサービス"], $item["内容"], $item["パス"])
                $fillName = "normal"
                if ($rowIndex % 2) { $fillName = "alt" }
                Add-SheetRow $sheet (New-TableRow $Styles $values $columns $fillName) (Get-RowHeight $values $columns) | Out-Null
                $rowIndex++; $any = $true
            }
            foreach ($note in $report.Notes) {
                $values = @($Script:KindName[$kind], $report.Run, $report.Source, "補足", "", "", $note, "")
                $fillName = "normal"
                if ($rowIndex % 2) { $fillName = "alt" }
                Add-SheetRow $sheet (New-TableRow $Styles $values $columns $fillName) (Get-RowHeight $values $columns) | Out-Null
                $rowIndex++; $any = $true
            }
            foreach ($warning in $report.Warnings) {
                $values = @($Script:KindName[$kind], $report.Run, $report.Source, "読み取り", "", "", $warning, "")
                Add-SheetRow $sheet (New-TableRow $Styles $values $columns "warn") (Get-RowHeight $values $columns) | Out-Null
                $rowIndex++; $any = $true
            }
        }
    }
    if (-not $any) { return $null }
    $last = [Math]::Max($headerIndex, $sheet.Rows.Count)
    $sheet.Filter = "A${headerIndex}:$(Get-ColumnLetter $columns.Count)$last"
    $sheet.Freeze = $headerIndex
    $sheet.Repeat = $headerIndex
    return $sheet
}

function New-CoverSheet {
    param($Styles, $Sources, [string]$MadeAt)
    $columns = @(
        @("ログ種別", "left", $false, $false, 16),
        @("実行", "center", $false, $true, 8),
        @("入力ファイル", "left", $false, $false, 34),
        @("反映時刻 (JST)", "left", $false, $false, 36),
        @("終了時刻 (JST)", "left", $false, $false, 28),
        @("明細", "right", $false, $true, 10),
        @("エラー", "right", $false, $true, 10),
        @("警告", "right", $false, $true, 10),
        @("対象ファイル", "right", $false, $true, 14)
    )
    $widths = @(); foreach ($column in $columns) { $widths += $column[4] }
    $sheet = New-Sheet "表紙" "FF2B2B2B" $widths "9"
    Add-TitleRow $sheet $Styles "JBoss EAP ログ検索レポート" $columns.Count
    Add-SubtitleRow $sheet $Styles "作成: $MadeAt    フォント: Meiryo UI    色: モノトーン" $columns.Count
    Add-BlankRow $sheet $Styles $columns.Count 10
    Add-SectionRow $sheet $Styles "概要" $columns.Count
    $headerIndex = Add-SheetRow $sheet (New-HeaderCells $Styles @("ログ種別", "実行", "入力ファイル", "反映時刻 (JST)", "終了時刻 (JST)", "明細", "エラー", "警告", "対象ファイル")) 30
    $rowIndex = 0
    $reportCount = 0
    foreach ($kind in $Script:KindOrder) {
        foreach ($report in (Get-ReportsOf $Sources $kind)) {
            $reportCount++
            $fileCount = Get-Count $report.Files
            if ($null -ne $report.DeclaredFiles) { $fileCount = [int]$report.DeclaredFiles }
            $values = @(
                $Script:KindName[$kind], $report.Run, $report.Source,
                (Get-Condition $report "反映時刻 (JST)"),
                (Get-Condition $report "終了時刻 (JST)"),
                (Get-Count $report.Records),
                (Get-SeverityCount $kind $report.Records "error"),
                (Get-SeverityCount $kind $report.Records "warn"),
                $fileCount
            )
            $fillName = "normal"
            if ($rowIndex % 2) { $fillName = "alt" }
            Add-SheetRow $sheet (New-TableRow $Styles $values $columns $fillName) 20 | Out-Null
            $rowIndex++
        }
    }
    if ($reportCount -eq 0) {
        $noteStyle = Get-StyleId $Styles -Size 11 -Color "FF1F1F1F" -Fill "FFFFFFFF" -Border "none" -Wrap $true
        $cells = @()
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $value = ""
            if ($i -eq 0) { $value = "検索結果の見出しが見つかりませんでした。Tera Term のログに、スクリプトの実行結果が入っているか確認してください。" }
            $cells += (New-TextCell $value $noteStyle)
        }
        $row = Add-SheetRow $sheet $cells 36
        Add-Merge $sheet $row 1 $columns.Count
    }
    $sheet.Filter = "A${headerIndex}:$(Get-ColumnLetter $columns.Count)$([Math]::Max($headerIndex, $sheet.Rows.Count))"
    Add-BlankRow $sheet $Styles $columns.Count 10
    Add-SectionRow $sheet $Styles "入力ファイル" $columns.Count
    Add-SheetRow $sheet (New-HeaderCells $Styles @("ファイル", "文字コード", "サイズ", "レポート", "", "", "", "", "")) 24 | Out-Null
    $inputColumns = @(
        @("ファイル", "left", $false, $false, 36),
        @("文字コード", "center", $false, $false, 14),
        @("サイズ", "right", $false, $true, 14),
        @("レポート", "right", $false, $true, 12),
        @("空き", "left", $false, $false, 12),
        @("空き", "left", $false, $false, 12),
        @("空き", "left", $false, $false, 12),
        @("空き", "left", $false, $false, 12),
        @("空き", "left", $false, $false, 12)
    )
    for ($index = 0; $index -lt (Get-Count $Sources); $index++) {
        $source = $Sources[$index]
        $values = @($source.Label, $source.Encoding, $source.Size, (Get-Count $source.Reports), "", "", "", "", "")
        $fillName = "normal"
        if ($index % 2) { $fillName = "alt" }
        Add-SheetRow $sheet (New-TableRow $Styles $values $inputColumns $fillName) 20 | Out-Null
    }
    Add-BlankRow $sheet $Styles $columns.Count 10
    Add-SectionRow $sheet $Styles "見方" $columns.Count
    $notes = @(
        "明細シートは、検索結果の 1 件を 1 行にしています。見出しは画面に出た項目です。",
        "濃い灰色の行はエラー、やや薄い灰色の行は警告です。その他は白とごく薄い灰色です。",
        "見出し行で絞り込めます。長い文は折り返します。印刷は横向きで、幅を 1 ページに合わせます。"
    )
    $noteStyle = Get-StyleId $Styles -Size 10 -Color "FF1F1F1F" -Fill "FFFFFFFF" -Border "none" -Align "left" -Valign "center" -Wrap $true
    foreach ($text in $notes) {
        $cells = @()
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $value = ""
            if ($i -eq 0) { $value = $text }
            $cells += (New-TextCell $value $noteStyle)
        }
        $row = Add-SheetRow $sheet $cells 20
        Add-Merge $sheet $row 1 $columns.Count
    }
    return $sheet
}

function New-Sheets {
    param($Styles, $Sources, [string]$MadeAt)
    $sheets = New-Object System.Collections.Generic.List[object]
    $sheets.Add((New-CoverSheet $Styles $Sources $MadeAt))
    $any = $false
    foreach ($source in $Sources) { if ((Get-Count $source.Reports) -gt 0) { $any = $true } }
    if ($any) { $sheets.Add((New-ConditionSheet $Styles $Sources)) }
    foreach ($kind in $Script:KindOrder) {
        $reports = Get-ReportsOf $Sources $kind
        if ((Get-Count $reports) -eq 0) { continue }
        $sheets.Add((New-DetailSheet $Styles $kind $reports))
        $sheets.Add((New-FileSheet $Styles $kind $reports))
        $hasSummary = $false
        foreach ($report in $reports) {
            if ((Get-Count $report.SummaryRows) -gt 0 -or $null -ne $report.SummaryTotal -or (Get-Count $report.Stats) -gt 0 -or (Get-Count $report.Statuses) -gt 0) {
                $hasSummary = $true
            }
        }
        if ($hasSummary) { $sheets.Add((New-SummarySheet $Styles $kind $reports)) }
    }
    $note = New-NoteSheet $Styles $Sources
    if ($null -ne $note) { $sheets.Add($note) }
    return ,$sheets
}

function ConvertTo-XmlAttr {
    param([string]$Text)
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function Get-DefinedNamesXml {
    param($Sheets)
    $names = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Sheets.Count; $i++) {
        $sheet = $Sheets[$i]
        if (-not $sheet.Repeat) { continue }
        $safe = ([string]$sheet.Name).Replace("'", "''")
        [void]$names.Append("<definedName name=`"_xlnm.Print_Titles`" localSheetId=`"$i`">'$safe'!`$$($sheet.Repeat):`$$($sheet.Repeat)</definedName>")
    }
    if ($names.Length -eq 0) { return "" }
    return "<definedNames>$($names.ToString())</definedNames>"
}

function Get-WorkbookXml {
    param($Sheets)
    $items = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Sheets.Count; $i++) {
        $n = $i + 1
        [void]$items.Append("<sheet name=`"$(ConvertTo-XmlAttr $Sheets[$i].Name)`" sheetId=`"$n`" r:id=`"rId$n`"/>")
    }
    return "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>" +
        "<workbook xmlns=`"http://schemas.openxmlformats.org/spreadsheetml/2006/main`" xmlns:r=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships`">" +
        "<workbookPr defaultThemeVersion=`"164011`"/>" +
        "<bookViews><workbookView activeTab=`"0`"/></bookViews>" +
        "<sheets>$($items.ToString())</sheets>" +
        "$(Get-DefinedNamesXml $Sheets)" +
        "<calcPr calcMode=`"auto`"/>" +
        "</workbook>"
}

function Get-WorkbookRels {
    param($Sheets)
    $items = New-Object System.Text.StringBuilder
    for ($i = 1; $i -le $Sheets.Count; $i++) {
        [void]$items.Append("<Relationship Id=`"rId$i`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet`" Target=`"worksheets/sheet$i.xml`"/>")
    }
    $styleId = $Sheets.Count + 1
    [void]$items.Append("<Relationship Id=`"rId$styleId`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles`" Target=`"styles.xml`"/>")
    return "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>" +
        "<Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`">$($items.ToString())</Relationships>"
}

function Get-ContentTypes {
    param($Sheets)
    $overrides = New-Object System.Text.StringBuilder
    [void]$overrides.Append("<Override PartName=`"/xl/workbook.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml`"/>")
    [void]$overrides.Append("<Override PartName=`"/xl/styles.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml`"/>")
    [void]$overrides.Append("<Override PartName=`"/docProps/core.xml`" ContentType=`"application/vnd.openxmlformats-package.core-properties+xml`"/>")
    [void]$overrides.Append("<Override PartName=`"/docProps/app.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.extended-properties+xml`"/>")
    for ($i = 1; $i -le $Sheets.Count; $i++) {
        [void]$overrides.Append("<Override PartName=`"/xl/worksheets/sheet$i.xml`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/>")
    }
    return "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>" +
        "<Types xmlns=`"http://schemas.openxmlformats.org/package/2006/content-types`">" +
        "<Default Extension=`"rels`" ContentType=`"application/vnd.openxmlformats-package.relationships+xml`"/>" +
        "<Default Extension=`"xml`" ContentType=`"application/xml`"/>" +
        "$($overrides.ToString())</Types>"
}

function Get-CoreXml {
    param([string]$MadeIso)
    return "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>" +
        "<cp:coreProperties xmlns:cp=`"http://schemas.openxmlformats.org/package/2006/metadata/core-properties`" xmlns:dc=`"http://purl.org/dc/elements/1.1/`" xmlns:dcterms=`"http://purl.org/dc/terms/`" xmlns:xsi=`"http://www.w3.org/2001/XMLSchema-instance`">" +
        "<dc:title>JBoss EAP ログ検索レポート</dc:title>" +
        "<dc:creator>jboss-eap-teraterm-log-report</dc:creator>" +
        "<cp:lastModifiedBy>jboss-eap-teraterm-log-report</cp:lastModifiedBy>" +
        "<dcterms:created xsi:type=`"dcterms:W3CDTF`">$MadeIso</dcterms:created>" +
        "<dcterms:modified xsi:type=`"dcterms:W3CDTF`">$MadeIso</dcterms:modified>" +
        "</cp:coreProperties>"
}

function Get-AppXml {
    param($Sheets)
    $titles = New-Object System.Text.StringBuilder
    foreach ($sheet in $Sheets) { [void]$titles.Append("<vt:lpstr>$(ConvertTo-XmlAttr $sheet.Name)</vt:lpstr>") }
    return "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>" +
        "<Properties xmlns=`"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties`" xmlns:vt=`"http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes`">" +
        "<Application>jboss-eap-teraterm-log-report</Application>" +
        "<HeadingPairs><vt:vector size=`"2`" baseType=`"variant`">" +
        "<vt:variant><vt:lpstr>ワークシート</vt:lpstr></vt:variant>" +
        "<vt:variant><vt:i4>$($Sheets.Count)</vt:i4></vt:variant>" +
        "</vt:vector></HeadingPairs>" +
        "<TitlesOfParts><vt:vector size=`"$($Sheets.Count)`" baseType=`"lpstr`">$($titles.ToString())</vt:vector></TitlesOfParts>" +
        "</Properties>"
}

function Get-RootRels {
    return "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>" +
        "<Relationships xmlns=`"http://schemas.openxmlformats.org/package/2006/relationships`">" +
        "<Relationship Id=`"rId1`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument`" Target=`"xl/workbook.xml`"/>" +
        "<Relationship Id=`"rId2`" Type=`"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties`" Target=`"docProps/core.xml`"/>" +
        "<Relationship Id=`"rId3`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties`" Target=`"docProps/app.xml`"/>" +
        "</Relationships>"
}

function Write-ZipText {
    param($Zip, [string]$Name, [string]$Text)
    $entry = $Zip.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding $false))
    $writer.Write($Text)
    $writer.Dispose()
}

function Write-Workbook {
    param([string]$Path, $Sheets, $Styles, [string]$MadeIso)
    $parent = [IO.Path]::GetDirectoryName($Path)
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    $temporary = "$Path.partial"
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($temporary, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        Write-ZipText $zip "[Content_Types].xml" (Get-ContentTypes $Sheets)
        Write-ZipText $zip "_rels/.rels" (Get-RootRels)
        Write-ZipText $zip "docProps/core.xml" (Get-CoreXml $MadeIso)
        Write-ZipText $zip "docProps/app.xml" (Get-AppXml $Sheets)
        Write-ZipText $zip "xl/workbook.xml" (Get-WorkbookXml $Sheets)
        Write-ZipText $zip "xl/_rels/workbook.xml.rels" (Get-WorkbookRels $Sheets)
        Write-ZipText $zip "xl/styles.xml" (Get-StylesXml $Styles)
        for ($i = 0; $i -lt $Sheets.Count; $i++) {
            Write-ZipText $zip "xl/worksheets/sheet$($i + 1).xml" (ConvertTo-SheetXml $Sheets[$i] ($i -eq 0))
        }
    } finally {
        $zip.Dispose()
    }
    try {
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        Move-Item -LiteralPath $temporary -Destination $Path
    } catch {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        Fail "書き込めません。Excel で開いているときは閉じてから再実行してください: $Path"
    }
}

function Write-Summary {
    param([string]$Path, $Sources, [int]$Code)
    [Console]::Out.WriteLine("レポートを書きました: $Path")
    if ($Code -eq 2) {
        [Console]::Error.WriteLine("検索結果の見出しは見つかりませんでした。表紙にその旨を書いてあります。")
        return
    }
    foreach ($kind in $Script:KindOrder) {
        $reports = Get-ReportsOf $Sources $kind
        if ((Get-Count $reports) -eq 0) { continue }
        $records = New-Object System.Collections.Generic.List[object]
        foreach ($report in $reports) { foreach ($record in $report.Records) { $records.Add($record) } }
        $name = $Script:KindName[$kind]
        $line = "  {0,-12} 明細 {1} 件    エラー {2}    警告 {3}" -f $name, $records.Count, (Get-SeverityCount $kind $records "error"), (Get-SeverityCount $kind $records "warn")
        [Console]::Out.WriteLine($line)
    }
}

if (-not $Path -or $Path.Count -eq 0) {
    Fail "ログファイルを指定してください。`n例: powershell -File .\jboss-eap-teraterm-log-report.ps1 -Output report.xlsx .\teraterm.log"
}
if (-not $Output) {
    $Output = Join-Path (Get-Location) ("jboss-eap-log-report-{0:yyyyMMdd-HHmmss}.xlsx" -f (Get-Date))
}
$ext = [IO.Path]::GetExtension($Output)
if ($ext.ToLowerInvariant() -ne ".xlsx") {
    if ([string]::IsNullOrEmpty($ext)) { $Output = "$Output.xlsx" }
    else { $Output = $Output.Substring(0, $Output.Length - $ext.Length) + $ext + ".xlsx" }
}
if (Test-Path -LiteralPath $Output -PathType Container) { Fail "出力先がディレクトリです: $Output" }

$inputs = Expand-Inputs $Path
$sources = Read-Sources $inputs
$made = Get-Date
$madeAt = $made.ToString("yyyy-MM-dd HH:mm:ss")
$madeIso = $made.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$styles = New-StyleBook
$sheets = New-Sheets $styles $sources $madeAt
Write-Workbook $Output $sheets $styles $madeIso
$found = $false
foreach ($source in $sources) { if ((Get-Count $source.Reports) -gt 0) { $found = $true } }
$code = 0
if (-not $found) { $code = 2 }
Write-Summary $Output $sources $code
exit $code
