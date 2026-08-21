[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$release = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$tools = Join-Path $release 'tools'
$manifest = Get-Content -LiteralPath (Join-Path $release 'release.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ([string]$Actual -ne [string]$Expected) { throw "$Label mismatch: $Actual != $Expected" }
}

Assert-Equal $manifest.release '2026-08-20-v3.80-beta39-v2-weather' 'Release id'
Assert-Equal $manifest.sourceCommits.'camper-gui-v2' '9e5a5282162b590b1e446958d97bf268915b3c23' 'GUI commit'
Assert-Equal $manifest.sourceCommits.'campercontrol-node-red' '8805a01e5068bea46e3b4138039c9e260b6b1051' 'Node/Cerbo commit'
Assert-Equal $manifest.sourceCommits.'sync3-camper' '8819d7378ed219836116574bbec3b5cfe31df01a' 'SYNC commit'
Assert-Equal $manifest.designs.default 'v2' 'Default design'
Assert-Equal @($manifest.designs.available).Count 1 'Design count'
Assert-Equal $manifest.designs.legacyV1Included $false 'V1 exclusion'

$gx = Join-Path $release $manifest.artifacts.gxArchive.path
$wasm = Join-Path $release $manifest.artifacts.wasmArchive.path
Assert-Equal (Get-FileHash -LiteralPath $gx -Algorithm SHA256).Hash.ToLowerInvariant() $manifest.artifacts.gxArchive.archiveSha256 'GX archive'
Assert-Equal (Get-FileHash -LiteralPath $wasm -Algorithm SHA256).Hash.ToLowerInvariant() $manifest.artifacts.wasmArchive.archiveSha256 'WASM archive'
$gxEntries = @(& tar -tzf $gx)
if ($LASTEXITCODE -ne 0) { throw 'Cannot list GX archive.' }
$wasmEntries = @(& tar -tzf $wasm)
if ($LASTEXITCODE -ne 0) { throw 'Cannot list WASM archive.' }
Assert-Equal @($gxEntries | Where-Object { -not $_.EndsWith('/') }).Count 924 'GX file count'
Assert-Equal @($wasmEntries | Where-Object { -not $_.EndsWith('/') }).Count 21 'WASM file count'
Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $release $manifest.artifacts.cerboService.path) -Recurse -File).Count 19 'Cerbo file count'

$normalizedGx = @($gxEntries | ForEach-Object { $_ -replace '^\./', '' })
foreach ($required in $manifest.artifacts.gxArchive.requiredFiles) {
    if ($normalizedGx -notcontains $required) { throw "GX V2 file missing: $required" }
}
foreach ($forbidden in @(
    'Victron/VenusOS/pages/camper/CamperHome.qml',
    'Victron/VenusOS/pages/camper/CamperLights.qml',
    'Victron/VenusOS/pages/camper/CamperPower.qml',
    'Victron/VenusOS/components/camper/CamperDesignSettings.qml'
)) {
    if ($normalizedGx -contains $forbidden) { throw "Legacy V1 payload present: $forbidden" }
}
$shellSource = (& tar -xOzf $gx './Victron/VenusOS/pages/camper/CamperShell.qml') -join "`n"
$panelSource = (& tar -xOzf $gx './Victron/VenusOS/pages/camper/v2/CamperV2PanelHost.qml') -join "`n"
$weatherSource = (& tar -xOzf $gx './Victron/VenusOS/data/camper/CamperWeatherAdapter.qml') -join "`n"
if (-not $shellSource.Contains('CamperV2Shell') -or $shellSource -match 'designVersion|CamperDesignSettings|CamperHome') { throw 'GX entry point is not V2-only.' }
foreach ($required in @('camperV2LeftEdgeSwipe', 'camperV2RightEdgeSwipe', 'width: root.edgeWidth')) {
    if (-not $panelSource.Contains($required)) { throw "Invisible edge contract missing: $required" }
}
if (-not $weatherSource.Contains('/State/Weather') -or $weatherSource.Contains('XMLHttpRequest')) { throw 'Central read-only weather adapter contract failed.' }

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('cc-release-tooling-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $temporary | Out-Null
    & tar -xzf $gx -C $temporary venus-gui-v2 2>$null
    if ($LASTEXITCODE -ne 0) { & tar -xzf $gx -C $temporary ./venus-gui-v2 }
    Assert-Equal (Get-FileHash -LiteralPath (Join-Path $temporary 'venus-gui-v2') -Algorithm SHA256).Hash.ToLowerInvariant() $manifest.artifacts.gxArchive.binarySha256 'GX binary'
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}

$shellScripts = @(Get-ChildItem -LiteralPath $tools -Filter '*.sh' -File)
$sh = Get-Command sh -ErrorAction SilentlyContinue
if ($sh) {
    foreach ($script in $shellScripts) {
        & $sh.Source -n $script.FullName
        if ($LASTEXITCODE -ne 0) { throw "sh -n failed: $($script.Name)" }
    }
}

$allToolText = ($shellScripts | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 }) -join "`n"
foreach ($stale in @('2026-08-19-v3.80-beta39-display-fit', '9b7df5a9e2fdf8a7cb2fb13f0635cbf8957194fa', 'camper-gui-v2-display-fit-20260819')) {
    if ($allToolText.Contains($stale)) { throw "Stale release token remains: $stale" }
}
foreach ($required in @(
    '/data/campercontrol/cache/weather-v1.json',
    '/data/campercontrol/cache/mosmix-stations-v1.cfg',
    '/data/campercontrol/weather-location.json',
    '/State/Weather',
    'NODE_RED_CONTEXT_TMP_BYTES',
    'OLD_GUI_TREE_KB'
)) {
    if (-not $allToolText.Contains($required)) { throw "Tooling contract missing: $required" }
}

foreach ($deployName in @('deploy-gx.sh', 'deploy-wasm.sh')) {
    $source = Get-Content -LiteralPath (Join-Path $tools $deployName) -Raw -Encoding UTF8
    foreach ($required in @('gui-v2.pre-v2-weather-20260820', 'archive_and_remove_exact_pre_tree', 'tar -czf', 'sha256sum -c')) {
        if (-not $source.Contains($required)) { throw "$deployName pre-tree archive contract missing: $required" }
    }
}

$pending = @([regex]::Matches((Get-Content -LiteralPath (Join-Path $release 'release.json') -Raw), '__PENDING_[A-Z0-9_]+__') | ForEach-Object Value | Sort-Object -Unique)
$expectedPending = @()
Assert-Equal ($pending -join ',') (($expectedPending | Sort-Object) -join ',') 'Explicit pending set'

'RELEASE_TOOLING_OFFLINE_TESTS_OK'
