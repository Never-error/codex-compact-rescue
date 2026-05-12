param(
    [Parameter(Mandatory = $true)][string]$CodexBin,
    [ValidateSet("present", "absent", "any")][string]$ExpectMarker = "present",
    [string]$LogsDb
)

$marker = "retrying remote compaction with fallback model"
$fallbackModel = "gpt-5.4-mini"
$sourceModel = "gpt-5.5"

if (-not (Test-Path -LiteralPath $CodexBin -PathType Leaf)) {
    Write-Error "Codex binary not found: $CodexBin"
    exit 1
}

$content = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($CodexBin))
$markerPresent = $content.Contains($marker) -and $content.Contains($fallbackModel) -and $content.Contains($sourceModel)

if ($ExpectMarker -eq "present" -and -not $markerPresent) {
    Write-Error "patch_marker=missing"
    exit 1
}

if ($ExpectMarker -eq "absent" -and $markerPresent) {
    Write-Error "patch_marker=present"
    exit 1
}

$hash = Get-FileHash -Algorithm SHA256 -LiteralPath $CodexBin
Write-Output "codex_bin=$CodexBin"
Write-Output "patch_marker=$markerPresent"
Write-Output "sha256=$($hash.Hash.ToLowerInvariant())"

if ($LogsDb -and (Get-Command sqlite3 -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $LogsDb)) {
    sqlite3 $LogsDb "select id, datetime(timestamp, 'unixepoch'), level, target, substr(feedback_log_body, 1, 240) from logs where target = 'codex_core::compact_remote' and feedback_log_body like '%fallback model%' order by id desc limit 20;"
}
