param(
    [Parameter(Mandatory = $true)][string]$CodexBin,
    [Parameter(Mandatory = $true)][string]$Backup,
    [switch]$Yes
)

if (-not $Yes) {
    Write-Error "Refusing to restore $CodexBin without -Yes"
    exit 2
}

if (-not (Test-Path -LiteralPath $Backup -PathType Leaf)) {
    Write-Error "Backup not found: $Backup"
    exit 1
}

Copy-Item -LiteralPath $Backup -Destination $CodexBin -Force

Write-Output "restored=$CodexBin"
Write-Output "backup=$Backup"
