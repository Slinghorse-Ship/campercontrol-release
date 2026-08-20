[CmdletBinding()]
param([switch]$Replace)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$releaseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$manifestPath = Join-Path $releaseRoot 'release.json'
$checksumPath = Join-Path $releaseRoot 'checksums.sha256'
$temporaryPath = Join-Path $releaseRoot '.checksums.sha256.candidate'
$raw = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8
$pending = @([regex]::Matches($raw, '__PENDING_[A-Z0-9_]+__') | ForEach-Object Value | Sort-Object -Unique)
if ($pending.Count) { throw "Final checksums blocked by: $($pending -join ', ')" }
$manifest = $raw | ConvertFrom-Json
if ($manifest.release -ne (Split-Path $releaseRoot -Leaf) -or $manifest.status -ne 'ready') {
    throw 'Manifest release directory/status is not final.'
}
foreach ($required in @(
    $manifest.artifacts.gxArchive.path,
    $manifest.artifacts.wasmArchive.path,
    $manifest.artifacts.nodeRedFlow.path,
    $manifest.artifacts.syncArchive.path,
    'artifacts/cerbo-service/campercontrol_weather.py'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $releaseRoot $required) -PathType Leaf)) {
        throw "Required final artifact missing: $required"
    }
}
foreach ($scriptName in @('deploy-node-red.sh', 'archive-node-red-context-tmp.sh')) {
    $scriptText = Get-Content -LiteralPath (Join-Path $PSScriptRoot $scriptName) -Raw -Encoding UTF8
    if ($scriptText -match '__PENDING_[A-Z0-9_]+__') { throw "Pending value remains in $scriptName" }
}
if (Test-Path -LiteralPath $temporaryPath) { throw "Candidate already exists: $temporaryPath" }
if ((Test-Path -LiteralPath $checksumPath) -and -not $Replace) { throw 'checksums.sha256 exists; use -Replace explicitly.' }

$lines = Get-ChildItem -LiteralPath $releaseRoot -Recurse -File |
    Where-Object { $_.FullName -ne $checksumPath -and $_.FullName -ne $temporaryPath } |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring($releaseRoot.Length + 1).Replace('\', '/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $relative"
    }
$ascii = [Text.ASCIIEncoding]::new()
[IO.File]::WriteAllText($temporaryPath, (($lines -join "`n") + "`n"), $ascii)
if (Test-Path -LiteralPath $checksumPath) { Remove-Item -LiteralPath $checksumPath -Force }
Move-Item -LiteralPath $temporaryPath -Destination $checksumPath
Write-Host "Final checksums written: $checksumPath"
& (Join-Path $PSScriptRoot 'verify-release.ps1')
