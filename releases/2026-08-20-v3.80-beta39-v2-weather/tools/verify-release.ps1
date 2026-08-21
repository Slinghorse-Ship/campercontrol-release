[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$releaseRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$checksumFile = Join-Path $releaseRoot "checksums.sha256"
$manifestFile = Join-Path $releaseRoot "release.json"
$temporaryRoot = $null
$checksummedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Resolve-ReleaseFile {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $candidate = [IO.Path]::GetFullPath((Join-Path $releaseRoot $RelativePath.Replace("/", [IO.Path]::DirectorySeparatorChar)))
    $rootPrefix = $releaseRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes release root: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Release file missing: $RelativePath"
    }
    return $candidate
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StreamSha256 {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($Stream) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $algorithm.Dispose()
    }
}

function Assert-PngHasAlpha {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $header = [IO.File]::ReadAllBytes($Path)
    if ($header.Length -lt 26 -or $header[25] -notin @(4, 6)) {
        throw "$Label is not a PNG with an alpha channel"
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([string]$Actual -ne [string]$Expected) {
        throw "$Label mismatch: expected '$Expected', got '$Actual'"
    }
}

function Get-SafeTarEntries {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    $entries = @(& tar -tzf $ArchivePath)
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot list tar archive: $ArchivePath"
    }
    foreach ($entry in $entries) {
        $normalized = $entry -replace '^\./', ''
        if ($normalized.StartsWith("/") -or $normalized -match '^[A-Za-z]:' -or $normalized -match '(^|/)\.\.(/|$)') {
            throw "Unsafe archive entry '$entry' in $ArchivePath"
        }
    }
    return $entries
}

if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
    throw "release.json does not exist"
}
$manifestRaw = Get-Content -LiteralPath $manifestFile -Raw
$pending = @([regex]::Matches($manifestRaw, '__PENDING_[A-Z0-9_]+__') | ForEach-Object Value | Sort-Object -Unique)
if ($pending.Count -gt 0) {
    throw "FINALIZATION_REQUIRED: unresolved release values: $($pending -join ', ')"
}
$manifest = $manifestRaw | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) {
    throw "checksums.sha256 does not exist"
}

$failures = 0
foreach ($line in Get-Content -LiteralPath $checksumFile) {
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    $parts = $line -split "\s{2,}", 2
    if ($parts.Count -ne 2) {
        throw "Invalid checksum line: $line"
    }

    $expected = $parts[0].ToLowerInvariant()
    $relativePath = $parts[1]
    $normalizedRelativePath = $relativePath.Replace("\", "/")
    if (-not $checksummedPaths.Add($normalizedRelativePath)) {
        throw "Duplicate checksum path: $relativePath"
    }
    $filePath = Resolve-ReleaseFile $relativePath
    $actual = Get-Sha256 $filePath

    if ($actual -ne $expected) {
        Write-Error "Checksum mismatch: $relativePath" -ErrorAction Continue
        $failures++
    } else {
        Write-Host "OK  $relativePath"
    }
}

if ($failures -gt 0) {
    throw "$failures release file(s) failed checksum verification."
}

$releaseFiles = @(Get-ChildItem -LiteralPath $releaseRoot -Recurse -File | Where-Object { $_.FullName -ne $checksumFile })
foreach ($releaseFile in $releaseFiles) {
    $relativeReleaseFile = $releaseFile.FullName.Substring($releaseRoot.Length + 1).Replace("\", "/")
    if (-not $checksummedPaths.Contains($relativeReleaseFile)) {
        throw "Release file is not covered by checksums.sha256: $relativeReleaseFile"
    }
}
Assert-Equal $checksummedPaths.Count $releaseFiles.Count "Checksummed release file count"

Assert-Equal $manifest.release (Split-Path $releaseRoot -Leaf) "Release directory"
Assert-Equal $manifest.schema "campercontrol-release-v2" "Release schema"
Assert-Equal $manifest.status "ready" "Release state"
Assert-Equal $manifest.deployed $false "Deployment state"
Assert-Equal $manifest.designs.default "v2" "Default design"
Assert-Equal @($manifest.designs.available).Count 1 "Available design count"
Assert-Equal $manifest.designs.available[0] "v2" "Only available design"
Assert-Equal $manifest.designs.legacyV1Included $false "Legacy V1 payload state"
Assert-Equal $manifest.designs.selectorIncluded $false "Design selector state"
Assert-Equal $manifest.artifactFreeze.status "frozen" "Artifact freeze state"
Assert-Equal $manifest.artifactFreeze.sourceCommit $manifest.sourceCommits.'camper-gui-v2' "Artifact freeze source commit"
Assert-Equal $manifest.builds.gx.sourceCommit $manifest.sourceCommits.'camper-gui-v2' "GX build source commit"
Assert-Equal $manifest.builds.wasm.sourceCommit $manifest.sourceCommits.'camper-gui-v2' "WASM build source commit"
Assert-Equal $manifest.builds.gx.result "pass" "GX build result"
Assert-Equal $manifest.builds.wasm.result "pass" "WASM build result"
Assert-Equal $manifest.optionalComponents.shellyBleProbe.enabled $false "Shelly BLE probe enabled state"
Assert-Equal $manifest.optionalComponents.shellyBleProbe.deployed $false "Shelly BLE probe deployment state"
Assert-Equal $manifest.sourceCommits.'camper-gui-v2' '251b7b47124bb474f61a8cdd5217bf0634a87d47' 'Frozen GUI source commit'
Assert-Equal $manifest.sourceCommits.'campercontrol-node-red' 'fbf29b334c5c1fc5b05ebeb6f2ce76bc28e036b7' 'Frozen Node/Cerbo source commit'
Assert-Equal $manifest.sourceCommits.'sync3-camper' '325d91084fe32e95b60672bff3e3b0f252e91a4f' 'Frozen SYNC source commit'
Assert-Equal $manifest.artifacts.nodeRedFlow.sourceCommit $manifest.sourceCommits.'campercontrol-node-red' 'Node-RED artifact source commit'
Assert-Equal $manifest.artifacts.cerboService.sourceCommit $manifest.sourceCommits.'campercontrol-node-red' 'Cerbo artifact source commit'
Assert-Equal $manifest.artifacts.syncArchive.sourceCommit $manifest.sourceCommits.'sync3-camper' 'SYNC artifact source commit'

$shellyProbe = Get-Content -LiteralPath (Resolve-ReleaseFile $manifest.optionalComponents.shellyBleProbe.toolPath) -Raw
foreach ($requiredProbeContract in @(
    'default=0.0',
    '"--experimental-enable"',
    '"--scan-seconds"',
    '"pairingImplemented": False',
    '"rpcImplemented": False',
    '"relayWriteImplemented": False'
)) {
    if (-not $shellyProbe.Contains($requiredProbeContract)) {
        throw "Shelly BLE probe safety contract missing: $requiredProbeContract"
    }
}
$productionTextFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $releaseRoot "artifacts"), (Join-Path $releaseRoot "tools") -Recurse -File |
        Where-Object {
            $_.Extension -in @(".sh", ".py", ".qml", ".json", ".md", ".ps1", ".mjs") -and
            $_.FullName -ne (Join-Path $releaseRoot "tools/verify-release.ps1")
        }
)
foreach ($productionFile in $productionTextFiles) {
    if ((Get-Content -LiteralPath $productionFile.FullName -Raw).Contains("shelly_ble_probe")) {
        throw "Optional Shelly BLE probe is referenced by production file: $($productionFile.FullName)"
    }
}

$artifactChecks = @(
    @($manifest.artifacts.gxArchive.path, $manifest.artifacts.gxArchive.archiveSha256, "GX archive"),
    @($manifest.artifacts.wasmArchive.path, $manifest.artifacts.wasmArchive.archiveSha256, "WASM archive"),
    @($manifest.artifacts.syncArchive.path, $manifest.artifacts.syncArchive.archiveSha256, "SYNC archive"),
    @($manifest.artifacts.nodeRedFlow.path, $manifest.artifacts.nodeRedFlow.sha256, "Node-RED flow")
)
foreach ($check in $artifactChecks) {
    $artifactPath = Resolve-ReleaseFile $check[0]
    Assert-Equal (Get-Sha256 $artifactPath) ([string]$check[1]).ToLowerInvariant() $check[2]
}

$cerboArtifactRoot = [IO.Path]::GetFullPath((Join-Path $releaseRoot $manifest.artifacts.cerboService.path))
$cerboRootPrefix = $cerboArtifactRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not (Test-Path -LiteralPath $cerboArtifactRoot -PathType Container)) {
    throw 'Cerbo artifact directory is missing.'
}
$cerboDiskFiles = @(Get-ChildItem -LiteralPath $cerboArtifactRoot -Recurse -File)
$cerboManifestFiles = @($manifest.artifacts.cerboService.files)
Assert-Equal $cerboDiskFiles.Count $manifest.artifacts.cerboService.fileCount 'Cerbo artifact file count'
Assert-Equal $cerboManifestFiles.Count $manifest.artifacts.cerboService.fileCount 'Cerbo manifest inventory count'
$cerboSources = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$cerboTargets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($record in $cerboManifestFiles) {
    $source = ([string]$record.source).Replace('\', '/')
    if (-not $cerboSources.Add($source)) { throw "Duplicate Cerbo source: $source" }
    if (-not $cerboTargets.Add([string]$record.target)) { throw "Duplicate Cerbo target: $($record.target)" }
    if ($source.StartsWith('/') -or $source -match '^[A-Za-z]:' -or $source -match '(^|/)\.\.(/|$)') {
        throw "Unsafe Cerbo source path: $source"
    }
    $artifactPath = [IO.Path]::GetFullPath((Join-Path $cerboArtifactRoot $source.Replace('/', [IO.Path]::DirectorySeparatorChar)))
    if (-not $artifactPath.StartsWith($cerboRootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Cerbo inventory file is missing or escapes its root: $source"
    }
    if ((Get-Item -LiteralPath $artifactPath).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Cerbo payload may not contain links: $source"
    }
    Assert-Equal (Get-Item -LiteralPath $artifactPath).Length $record.bytes "Cerbo bytes $source"
    Assert-Equal (Get-Sha256 $artifactPath) $record.sha256 "Cerbo hash $source"
    if ([string]$record.mode -notin @('0644', '0755')) { throw "Invalid Cerbo mode for $source" }

    $expectedTarget = if ($source -eq 'starlink-read-status.sh') {
        '/data/campercontrol/starlink/read-status.sh'
    } else {
        "/data/campercontrol/service/$source"
    }
    Assert-Equal $record.target $expectedTarget "Cerbo target $source"
}
foreach ($diskFile in $cerboDiskFiles) {
    $relative = $diskFile.FullName.Substring($cerboArtifactRoot.Length + 1).Replace('\', '/')
    if (-not $cerboSources.Contains($relative)) { throw "Unmanifested Cerbo artifact: $relative" }
    if ($relative -match '(^|/)(__pycache__|.*\.py[co]$)') { throw "Generated Python cache in Cerbo artifact: $relative" }
}
Assert-Equal $manifest.artifacts.cerboService.weatherModuleSha256 (($cerboManifestFiles | Where-Object source -eq 'campercontrol_weather.py').sha256) 'Weather module manifest hash'
$starlinkRecords = @($cerboManifestFiles | Where-Object source -eq 'starlink-read-status.sh')
Assert-Equal $starlinkRecords.Count 1 'Starlink target mapping count'
$sudoersRecords = @($cerboManifestFiles | Where-Object source -eq 'sudoers-campercontrol')
Assert-Equal $sudoersRecords.Count 1 'Sudoers mapping count'
Assert-Equal $sudoersRecords[0].installedTarget '/etc/sudoers.d/campercontrol' 'Sudoers installed target'
Assert-Equal $sudoersRecords[0].installedMode '0440' 'Sudoers installed mode'

$flowPath = Resolve-ReleaseFile $manifest.artifacts.nodeRedFlow.path
$flowNodes = @(Get-Content -LiteralPath $flowPath -Raw | ConvertFrom-Json)
Assert-Equal $flowNodes.Count $manifest.artifacts.nodeRedFlow.nodes "Node-RED node count"
Assert-Equal (Get-Item -LiteralPath $flowPath).Length $manifest.artifacts.nodeRedFlow.bytes "Node-RED flow bytes"
$flowText = Get-Content -LiteralPath $flowPath -Raw
foreach ($forbiddenFlowContract in @("camper-dashboard-v1", "designVersion === 'v1'", 'designVersion === "v1"')) {
    if ($flowText.Contains($forbiddenFlowContract)) {
        throw "Node-RED contains a legacy V1 runtime contract: $forbiddenFlowContract"
    }
}
foreach ($requiredRemoteSafetyContract in @(
    'remote_link_protection',
    "if (isRemoteLinkProtected(item)) return 'remote_link_protection';",
    'const invalid = expanded.map(item => validateItem(item)).find(value => value);',
    'commands.length = commandCountBeforeScene',
    'output[index].length = length',
    "origin === 'vrm'"
)) {
    if (-not $flowText.Contains($requiredRemoteSafetyContract)) {
        throw "Node-RED remote Starlink safety contract missing: $requiredRemoteSafetyContract"
    }
}
foreach ($node in $flowNodes | Where-Object type -eq 'function') {
    $source = [string]$node.func
    if (($source.Contains('setTimeout') -or $source.Contains('setInterval')) -and
        $source -match '(?i)(?:context|flow|global)\.set\([^;\r\n]*(?:timer|interval)') {
        throw "Node-RED function persists a timer handle: $($node.id) / $($node.name)"
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$syncPath = Resolve-ReleaseFile $manifest.artifacts.syncArchive.path
Assert-Equal (Get-Item -LiteralPath $syncPath).Length $manifest.artifacts.syncArchive.bytes "SYNC ZIP bytes"
$syncZip = [IO.Compression.ZipFile]::OpenRead($syncPath)
try {
    Assert-Equal $syncZip.Entries.Count $manifest.artifacts.syncArchive.entries "SYNC ZIP entry count"
    foreach ($entry in $syncZip.Entries) {
        $normalizedEntry = $entry.FullName.Replace("\", "/")
        if ($normalizedEntry.StartsWith("/") -or $normalizedEntry -match '^[A-Za-z]:' -or
            $normalizedEntry -match '(^|/)\.\.(/|$)') {
            throw "Unsafe SYNC ZIP entry: $($entry.FullName)"
        }
        if ($normalizedEntry -match '(?i)(CamperHome|CamperLights|CamperPower|CamperDesignSettings|camper-dashboard-v1)') {
            throw "Legacy V1 file/reference found in SYNC ZIP: $normalizedEntry"
        }
    }

    foreach ($requiredSyncPath in @(
        'SyncMyMod/files/app/Jan/Camper/ModernShell.qml',
        'SyncMyMod/files/app/Jan/Camper/V2EdgePanels.qml'
    )) {
        if (-not ($syncZip.Entries | Where-Object FullName -eq $requiredSyncPath)) {
            throw "SYNC V2-only ZIP does not contain $requiredSyncPath"
        }
    }

    $appEntry = $syncZip.Entries | Where-Object { $_.FullName -eq "SyncMyMod/files/other/app-entry.json" }
    if (-not $appEntry) {
        throw "SYNC ZIP does not contain app-entry.json"
    }
    $reader = [IO.StreamReader]::new($appEntry.Open())
    try {
        $appManifest = $reader.ReadToEnd() | ConvertFrom-Json
    } finally {
        $reader.Dispose()
    }
    Assert-Equal $appManifest.appVersion $manifest.artifacts.syncArchive.version "SYNC app version"

    foreach ($theme in @("dark", "light")) {
        $logoEntryPath = "SyncMyMod/files/app/Jan/Camper/transit-line-symbol-$theme.png"
        $logoEntry = $syncZip.Entries | Where-Object { $_.FullName -eq $logoEntryPath }
        if (-not $logoEntry) {
            throw "SYNC ZIP does not contain $logoEntryPath"
        }
        $logoStream = $logoEntry.Open()
        try {
            Assert-Equal (Get-StreamSha256 $logoStream) $manifest.validation.commonTransitLogoSha256.$theme "SYNC $theme Transit logo"
        } finally {
            $logoStream.Dispose()
        }
    }
} finally {
    $syncZip.Dispose()
}

foreach ($theme in @("dark", "light")) {
    $nodeLogo = Resolve-ReleaseFile "artifacts/node-red/camper-assets/transit-line-symbol-$theme.png"
    Assert-Equal (Get-Sha256 $nodeLogo) $manifest.validation.commonTransitLogoSha256.$theme "Node-RED $theme Transit logo"
    Assert-PngHasAlpha $nodeLogo "Node-RED $theme Transit logo"
}

foreach ($deployScript in @("tools/deploy-gx.sh", "tools/deploy-wasm.sh", "tools/deploy-node-red.sh", "tools/archive-node-red-context-tmp.sh")) {
    $deployContent = Get-Content -LiteralPath (Resolve-ReleaseFile $deployScript) -Raw
    if ($deployContent -match '__[A-Z0-9_]+__') {
        throw "Unresolved placeholder in $deployScript"
    }
}
$reinstallContent = Get-Content -LiteralPath (Resolve-ReleaseFile "tools/reinstall-after-update.sh") -Raw
$maintenanceContent = Get-Content -LiteralPath (Resolve-ReleaseFile "tools/CamperControl-Maintenance.ps1") -Raw
$nodeDeployContent = Get-Content -LiteralPath (Resolve-ReleaseFile "tools/deploy-node-red.sh") -Raw
$serviceInstallContent = Get-Content -LiteralPath (Resolve-ReleaseFile "tools/install-campercontrol-service.sh") -Raw
$backupInvocations = @(
    ([regex]::Matches($reinstallContent, '(?m)^"\$release_root/tools/create-preapply-backup\.sh"$')).Count,
    ([regex]::Matches($maintenanceContent, 'Invoke-RemoteScript[^\r\n]+create-preapply-backup\.sh')).Count,
    ([regex]::Matches($nodeDeployContent, '(?m)^"\$release_root/tools/create-preapply-backup\.sh"$')).Count,
    ([regex]::Matches($serviceInstallContent, '(?m)^"\$release_root/tools/create-preapply-backup\.sh"$')).Count
)
Assert-Equal (($backupInvocations | Measure-Object -Sum).Sum) 1 "one full pre-apply backup per reinstall"
$backupContent = Get-Content -LiteralPath (Resolve-ReleaseFile 'tools/create-preapply-backup.sh') -Raw
foreach ($backupPathContract in @(
    'data/rc.local.before-camper-wifi-connect',
    'data/campercontrol/starlink',
    'etc/sudoers.d/campercontrol'
)) {
    if (-not $backupContent.Contains($backupPathContract)) {
        throw "Full pre-apply backup path missing: $backupPathContract"
    }
}
foreach ($stageContract in @(
    'REINSTALL_BLOCKED_STALE_STAGE',
    'NOT_ENOUGH_DATA_SPACE_FOR_STAGES',
    'mkdir "$gx_candidate"',
    'mkdir "$wasm_candidate"'
)) {
    if (-not $reinstallContent.Contains($stageContract)) {
        throw "Fresh stage/resource contract missing: $stageContract"
    }
}
$servicePosition = $reinstallContent.IndexOf('"$release_root/tools/install-campercontrol-service.sh"')
$nodePosition = $reinstallContent.IndexOf('"$release_root/tools/deploy-node-red.sh"', $servicePosition)
$gxPosition = $reinstallContent.IndexOf('"$release_root/tools/deploy-gx.sh"', $nodePosition)
$wasmPosition = $reinstallContent.IndexOf('"$release_root/tools/deploy-wasm.sh"', $gxPosition)
if ($servicePosition -lt 0 -or $nodePosition -le $servicePosition -or $gxPosition -le $nodePosition -or $wasmPosition -le $gxPosition) {
    throw 'Reinstall order must be central service, Node-RED, GX, WASM'
}
foreach ($rollbackContract in @(
    'stop_linked_service',
    'old_dbus_was_up',
    'old_dbus_had_dir',
    'old_wifi_was_up',
    'old_wifi_had_dir',
    'wait_service_up "$dbus_service_link"',
    'wait_service_up "$wifi_service_link"',
    'wait_bridge_identity',
    'validate_bridge_identity',
    'weather snapshot exceeds 16 KiB',
    'test ! -L "$service_root"',
    'NOT_ENOUGH_DATA_SPACE_FOR_SERVICES',
    'expected_file_count=19',
    'device-http-bounded.py',
    'starlink_root/read-status.sh',
    'mv "$candidate/service/campercontrol-dbus-service/run" "$dbus_service_dir/run"',
    'mv "$dbus_service_dir/run" "$rollback/service/campercontrol-dbus-service/run"',
    'mv "$candidate/service/wifi-connect-http-service/run" "$wifi_service_dir/run"',
    'mv "$wifi_service_dir/run" "$rollback/service/wifi-connect-http-service/run"',
    '"$service_root/install-privileges.sh"'
)) {
    if (-not $serviceInstallContent.Contains($rollbackContract)) {
        throw "Service process rollback/weather contract missing: $rollbackContract"
    }
}
foreach ($cerboSource in $cerboSources) {
    if (-not $serviceInstallContent.Contains($cerboSource)) {
        throw "Cerbo installer does not cover manifest source: $cerboSource"
    }
}
if ($serviceInstallContent -match 'for relative in[^\r\n]*(?:campercontrol-dbus-service|wifi-connect-http-service);' -or
    $serviceInstallContent.Contains('rm -rf "$service_root/$relative"')) {
    throw 'Service installer must preserve the runit service-directory/supervise inode during updates'
}
$contextCleanupContent = Get-Content -LiteralPath (Resolve-ReleaseFile "tools/archive-node-red-context-tmp.sh") -Raw
if (-not $contextCleanupContent.Contains('http://127.0.0.1:1880/camper/api/v2/state')) {
    throw 'Node-RED context cleanup does not wait for the Camper state endpoint'
}
foreach ($boundedHttpScript in @(
    @{ Name = 'health'; Content = (Get-Content -LiteralPath (Resolve-ReleaseFile "tools/campercontrol-health-readonly.sh") -Raw) },
    @{ Name = 'Node-RED deploy'; Content = $nodeDeployContent },
    @{ Name = 'context cleanup'; Content = $contextCleanupContent }
)) {
    if ($boundedHttpScript.Content.Contains('wget ') -or
        -not $boundedHttpScript.Content.Contains('signal.alarm(5)')) {
        throw "$($boundedHttpScript.Name) local HTTP probe is not hard-time-bounded"
    }
}
foreach ($runitScript in @(
    @{ Name = 'service installer'; Content = $serviceInstallContent },
    @{ Name = 'Node-RED deploy'; Content = $nodeDeployContent },
    @{ Name = 'context cleanup'; Content = $contextCleanupContent }
)) {
    if ($runitScript.Content.Contains("grep -q '^up:'") -or -not $runitScript.Content.Contains("grep -q ': up '")) {
        throw "$($runitScript.Name) does not parse Venus svstat output safely"
    }
}
$gxDeploy = Get-Content -LiteralPath (Resolve-ReleaseFile "tools/deploy-gx.sh") -Raw
$wasmDeploy = Get-Content -LiteralPath (Resolve-ReleaseFile "tools/deploy-wasm.sh") -Raw
if ($gxDeploy -notmatch "(?m)^expected_hash=$([regex]::Escape($manifest.artifacts.gxArchive.binarySha256))$" -or
    $gxDeploy -notmatch "(?m)^expected_files=$($manifest.artifacts.gxArchive.files)$") {
    throw "GX deploy script is not pinned to the manifest build"
}
if ($wasmDeploy -notmatch "(?m)^expected_hash=$([regex]::Escape($manifest.artifacts.wasmArchive.wasmGzipSha256))$" -or
    $wasmDeploy -notmatch "(?m)^expected_files=$($manifest.artifacts.wasmArchive.files)$") {
    throw "WASM deploy script is not pinned to the manifest build"
}
if ($wasmDeploy -match '(?m)^grep[^\r\n]+nodeRedUrl') {
    throw 'WASM deploy must not treat a browser-to-Node-RED URL as its transport contract'
}

$gxPath = Resolve-ReleaseFile $manifest.artifacts.gxArchive.path
$wasmPath = Resolve-ReleaseFile $manifest.artifacts.wasmArchive.path
$gxEntries = @(Get-SafeTarEntries $gxPath)
$wasmEntries = @(Get-SafeTarEntries $wasmPath)
$gxFileEntries = @($gxEntries | Where-Object { -not $_.EndsWith("/") })
$wasmFileEntries = @($wasmEntries | Where-Object { -not $_.EndsWith("/") })
Assert-Equal $gxFileEntries.Count $manifest.artifacts.gxArchive.files "GX archive file count"
Assert-Equal $wasmFileEntries.Count $manifest.artifacts.wasmArchive.files "WASM archive file count"
Assert-Equal (Get-Item -LiteralPath $gxPath).Length $manifest.artifacts.gxArchive.bytes "GX archive bytes"
Assert-Equal (Get-Item -LiteralPath $wasmPath).Length $manifest.artifacts.wasmArchive.bytes "WASM archive bytes"

$temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporaryRoot = Join-Path $temporaryBase ("campercontrol-release-" + [Guid]::NewGuid().ToString("N"))
$gxExtract = Join-Path $temporaryRoot "gx"
$wasmExtract = Join-Path $temporaryRoot "wasm"
New-Item -ItemType Directory -Path $gxExtract, $wasmExtract | Out-Null

try {
    & tar -xzf $gxPath -C $gxExtract
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot extract GX archive"
    }
    & tar -xzf $wasmPath -C $wasmExtract
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot extract WASM archive"
    }

    Assert-Equal @(Get-ChildItem -LiteralPath $gxExtract -Recurse -File).Count $manifest.artifacts.gxArchive.files "Extracted GX file count"
    Assert-Equal @(Get-ChildItem -LiteralPath $wasmExtract -Recurse -File).Count $manifest.artifacts.wasmArchive.files "Extracted WASM file count"

    $gxBinary = Join-Path $gxExtract $manifest.artifacts.gxArchive.binaryPath
    Assert-Equal (Get-Sha256 $gxBinary) $manifest.artifacts.gxArchive.binarySha256 "GX binary"
    foreach ($requiredFile in $manifest.artifacts.gxArchive.requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $gxExtract $requiredFile) -PathType Leaf)) {
            throw "Required GX file missing from archive: $requiredFile"
        }
    }
    foreach ($forbiddenFile in @(
        'Victron/VenusOS/pages/camper/CamperHome.qml',
        'Victron/VenusOS/pages/camper/CamperLights.qml',
        'Victron/VenusOS/pages/camper/CamperPower.qml',
        'Victron/VenusOS/components/camper/CamperDesignSettings.qml'
    )) {
        if (Test-Path -LiteralPath (Join-Path $gxExtract $forbiddenFile)) {
            throw "Legacy V1 file is present in GX archive: $forbiddenFile"
        }
    }
    $camperShell = Get-Content -LiteralPath (Join-Path $gxExtract 'Victron/VenusOS/pages/camper/CamperShell.qml') -Raw
    if (-not $camperShell.Contains('CamperV2Shell') -or $camperShell -match 'designVersion|CamperDesignSettings|CamperHome') {
        throw 'CamperShell is not a direct V2-only entry point'
    }
    $panelHost = Get-Content -LiteralPath (Join-Path $gxExtract 'Victron/VenusOS/pages/camper/v2/CamperV2PanelHost.qml') -Raw
    foreach ($edgeContract in @('camperV2LeftEdgeSwipe', 'camperV2RightEdgeSwipe', 'width: root.edgeWidth')) {
        if (-not $panelHost.Contains($edgeContract)) { throw "Invisible edge-panel contract missing: $edgeContract" }
    }
    $weatherAdapter = Get-Content -LiteralPath (Join-Path $gxExtract 'Victron/VenusOS/data/camper/CamperWeatherAdapter.qml') -Raw
    if (-not $weatherAdapter.Contains('/State/Weather') -or $weatherAdapter.Contains('XMLHttpRequest')) {
        throw 'Weather adapter must read central /State/Weather without browser HTTP'
    }
    $gxHeader = Get-Content -LiteralPath (Join-Path $gxExtract "Victron/VenusOS/components/camper/v2/CamperV2Header.qml") -Raw
    foreach ($theme in @("dark", "light")) {
        if ($gxHeader -notmatch [regex]::Escape("qrc:/images/camper_transit_line_$theme.png")) {
            throw "GX header does not reference the compiled $theme Transit logo"
        }
    }

    $mqttAdapter = Get-Content -LiteralPath (Join-Path $gxExtract "Victron/VenusOS/data/camper/CamperNodeRedMqttAdapter.qml") -Raw
    $transportFacade = Get-Content -LiteralPath (Join-Path $gxExtract "Victron/VenusOS/data/camper/CamperNodeRedAdapter.qml") -Raw
    foreach ($requiredMqttContract in @(
        'serviceUidFromName("com.victronenergy.campercontrol", 0)',
        'BackendConnection.vrmPortalMode === BackendConnection.Full',
        '"/State/Ui"',
        '"/State/Energy"',
        '"/State/Water"',
        '"/State/Climate"',
        '"/State/Lights"',
        '"/State/Vehicle"',
        '"/State/Power"'
    )) {
        if (-not $mqttAdapter.Contains($requiredMqttContract)) {
            throw "GX/WASM MQTT transport contract missing: $requiredMqttContract"
        }
    }
    if ($mqttAdapter.Contains("XMLHttpRequest")) {
        throw "WASM MQTT adapter must not use local browser HTTP"
    }
    if (-not $mqttAdapter.Contains('body.origin = remoteSession ? "vrm" : "gx"') -or
        -not $mqttAdapter.Contains('function isRemoteStarlinkOff') -or
        -not $mqttAdapter.Contains('remoteSession && target === "starpower"') -or
        -not $mqttAdapter.Contains('Number(fields.channel) === 5')) {
        throw 'GX/WASM adapter does not label VRM commands or block remote Starlink OFF locally'
    }
    if (-not $transportFacade.Contains('sourceComponent: bridgeTransport') -or
        -not $transportFacade.Contains('CamperNodeRedMqttAdapter') -or
        $transportFacade.Contains('CamperNodeRedHttpAdapter')) {
        throw "Transport facade does not use the single D-Bus/MQTT bridge on GX and WASM"
    }

    $wasmGzip = Join-Path $wasmExtract $manifest.artifacts.wasmArchive.wasmGzipPath
    Assert-Equal (Get-Sha256 $wasmGzip) $manifest.artifacts.wasmArchive.wasmGzipSha256 "WASM gzip"
    Assert-Equal (Get-Item -LiteralPath $wasmGzip).Length $manifest.artifacts.wasmArchive.wasmGzipBytes "WASM gzip bytes"
    $wasmJavascript = Join-Path $wasmExtract $manifest.artifacts.wasmArchive.javascriptPath
    Assert-Equal (Get-Sha256 $wasmJavascript) $manifest.artifacts.wasmArchive.javascriptSha256 "WASM JavaScript"

    $decompressedWasm = Join-Path $temporaryRoot "venus-gui-v2.wasm"
    $sourceStream = [IO.File]::OpenRead($wasmGzip)
    $gzipStream = [IO.Compression.GZipStream]::new($sourceStream, [IO.Compression.CompressionMode]::Decompress)
    $targetStream = [IO.File]::Create($decompressedWasm)
    try {
        $gzipStream.CopyTo($targetStream)
    } finally {
        $targetStream.Dispose()
        $gzipStream.Dispose()
        $sourceStream.Dispose()
    }
    Assert-Equal (Get-Sha256 $decompressedWasm) $manifest.artifacts.wasmArchive.wasmSha256 "Decompressed WASM"
    Assert-Equal (Get-Item -LiteralPath $decompressedWasm).Length $manifest.artifacts.wasmArchive.wasmBytes "Decompressed WASM bytes"

    $sidecar = Get-Content -LiteralPath (Join-Path $wasmExtract "venus-gui-v2.wasm.sha256") -Raw
    $sidecarHash = ($sidecar -split '\s+')[0].ToLowerInvariant()
    Assert-Equal $sidecarHash $manifest.artifacts.wasmArchive.wasmSha256 "WASM sidecar"

    # VRM does not load our local index.html.  Remote and local clients both
    # use the already verified com.victronenergy.campercontrol MQTT/D-Bus
    # transport, so no browser-to-Node-RED URL is part of the release contract.
} finally {
    if ($temporaryRoot) {
        $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
        if (-not $resolvedTemporaryRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean unexpected temporary path: $resolvedTemporaryRoot"
        }
        if (Test-Path -LiteralPath $resolvedTemporaryRoot) {
            Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
        }
    }
}

Write-Host "Release verification passed."
