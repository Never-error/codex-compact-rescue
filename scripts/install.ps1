param(
    [Parameter(Mandatory = $true)][string]$CodexBin,
    [Parameter(Mandatory = $true)][string]$PatchedBin,
    [string]$BackupDir,
    [switch]$Yes
)

if (-not $Yes) {
    Write-Error "Refusing to replace $CodexBin without -Yes"
    exit 2
}

if (-not (Test-Path -LiteralPath $CodexBin -PathType Leaf)) {
    Write-Error "Codex binary not found: $CodexBin"
    exit 1
}

if (-not (Test-Path -LiteralPath $PatchedBin -PathType Leaf)) {
    Write-Error "Patched binary not found: $PatchedBin"
    exit 1
}

if (-not $BackupDir) {
    $BackupDir = Split-Path -Parent $CodexBin
}

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = Join-Path $BackupDir ("$(Split-Path -Leaf $CodexBin).backup-$timestamp")

Copy-Item -LiteralPath $CodexBin -Destination $backupPath -Force
Copy-Item -LiteralPath $PatchedBin -Destination $CodexBin -Force

Write-Output "backup=$backupPath"
Write-Output "installed=$CodexBin"
