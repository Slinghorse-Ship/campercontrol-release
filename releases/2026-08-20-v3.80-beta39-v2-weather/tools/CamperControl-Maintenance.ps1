[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$CerboHost = '172.24.24.1',
    [string]$SshUser = 'root',
    [ValidateSet('Key', 'Prompt')]
    [string]$Authentication = 'Key',
    [string]$IdentityFile,
    [switch]$AcceptNewHostKey,
    [switch]$Apply,
    [switch]$ForceFirmwareMismatch,
    [switch]$Build,
    [switch]$AllowNetwork,
    [string]$GuiRepository,
    [string]$PythonCommand = 'python',
    [string]$BuildOutputDirectory,
    [string]$ReportDirectory,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ReleaseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:ReleaseId = Split-Path $script:ReleaseRoot -Leaf
$script:ManifestPath = Join-Path $script:ReleaseRoot 'release.json'
$script:MatrixPath = Join-Path $PSScriptRoot 'compatibility-matrix.json'
$script:HealthScriptPath = Join-Path $PSScriptRoot 'campercontrol-health-readonly.sh'
$script:Checks = [System.Collections.Generic.List[object]]::new()
$script:RemoteFacts = [ordered]@{}

function Add-Check {
    param(
        [ValidateSet('GREEN', 'WARNING', 'ERROR')]
        [string]$Status,
        [string]$Name,
        [string]$Detail
    )
    $script:Checks.Add([pscustomobject]@{ status = $Status; name = $Name; detail = $Detail })
}

function Get-ObjectProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $Default
}

function Get-Manifest {
    if (-not (Test-Path -LiteralPath $script:ManifestPath -PathType Leaf)) {
        throw "Release manifest missing: $script:ManifestPath"
    }
    return Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-CompatibilityMatrix {
    if (-not (Test-Path -LiteralPath $script:MatrixPath -PathType Leaf)) {
        throw "Compatibility matrix missing: $script:MatrixPath"
    }
    $matrix = Get-Content -LiteralPath $script:MatrixPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($matrix.schema -ne 'campercontrol-compatibility-matrix-v1') {
        throw "Unsupported compatibility matrix schema: $($matrix.schema)"
    }
    return $matrix
}

function Assert-SshInputs {
    if ($CerboHost -notmatch '^[A-Za-z0-9_.:-]+$') {
        throw 'CerboHost contains unsupported characters.'
    }
    if ($SshUser -notmatch '^[A-Za-z0-9_.-]+$') {
        throw 'SshUser contains unsupported characters.'
    }
    if ($IdentityFile) {
        $resolved = Resolve-Path -LiteralPath $IdentityFile -ErrorAction Stop
        $script:ResolvedIdentityFile = $resolved.Path
    } else {
        $script:ResolvedIdentityFile = $null
    }
}

function Get-SshOptions {
    $options = [System.Collections.Generic.List[string]]::new()
    $options.Add('-o')
    $options.Add('ConnectTimeout=10')
    $options.Add('-o')
    $options.Add($(if ($AcceptNewHostKey) { 'StrictHostKeyChecking=accept-new' } else { 'StrictHostKeyChecking=yes' }))
    if ($Authentication -eq 'Key') {
        $options.Add('-o')
        $options.Add('BatchMode=yes')
    }
    if ($script:ResolvedIdentityFile) {
        $options.Add('-i')
        $options.Add($script:ResolvedIdentityFile)
    }
    return $options.ToArray()
}

function ConvertTo-RemoteCommand {
    param([string]$ScriptText)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($ScriptText)
    $base64 = [Convert]::ToBase64String($bytes)
    return "printf '%s' '$base64' | base64 -d | sh"
}

function Invoke-SshCommand {
    param(
        [string]$RemoteCommand,
        [switch]$AllowFailure
    )
    $ssh = Get-Command ssh -ErrorAction Stop
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($option in (Get-SshOptions)) { $arguments.Add($option) }
    $arguments.Add("$SshUser@$CerboHost")
    $arguments.Add($RemoteCommand)
    $output = & $ssh.Source @arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "SSH failed with exit code $exitCode. $($output -join ' ')"
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = @($output | ForEach-Object { [string]$_ }) }
}

function Invoke-RemoteScript {
    param([string]$Path, [switch]$AllowFailure)
    $source = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return Invoke-SshCommand -RemoteCommand (ConvertTo-RemoteCommand $source) -AllowFailure:$AllowFailure
}

function ConvertFrom-KeyValueLines {
    param([string[]]$Lines)
    $facts = [ordered]@{}
    foreach ($line in $Lines) {
        if ($line -match '^([A-Z0-9_]+)=(.*)$') {
            $facts[$Matches[1]] = $Matches[2]
        }
    }
    return $facts
}

function Get-Fact {
    param([string]$Name, [string]$Default = 'missing')
    if ($script:RemoteFacts.Contains($Name)) { return [string]$script:RemoteFacts[$Name] }
    return $Default
}

function Test-HexHash {
    param([string]$Value)
    return $Value -match '^[0-9a-fA-F]{64}$'
}

function Get-PendingReleasePlaceholders {
    $raw = Get-Content -LiteralPath $script:ManifestPath -Raw -Encoding UTF8
    return @([regex]::Matches($raw, '__PENDING_[A-Z0-9_]+__') | ForEach-Object Value | Sort-Object -Unique)
}

function Assert-ReleaseFinalized {
    $pending = @(Get-PendingReleasePlaceholders)
    if ($pending.Count -gt 0) {
        throw "Release is not final; unresolved values: $($pending -join ', ')"
    }
}

function Find-CompatibleFirmware {
    param($Matrix, [string]$Version, [string]$Build, [string]$Architecture)
    return @($Matrix.knownFirmware | Where-Object {
        $_.venusVersion -eq $Version -and $_.venusBuild -eq $Build -and $_.architecture -eq $Architecture
    }) | Select-Object -First 1
}

function Add-AuditChecks {
    param($Manifest, $Matrix, [switch]$AllowPending)

    $pending = @(Get-PendingReleasePlaceholders)
    if ($pending.Count -eq 0) {
        Add-Check GREEN 'Release finalization' 'No pending artifact metadata remains.'
    } elseif ($AllowPending) {
        Add-Check WARNING 'Release finalization' "Offline tooling self-test uses a draft manifest with $($pending.Count) explicit placeholder(s)."
    } else {
        Add-Check ERROR 'Release finalization' "Deployment is blocked by: $($pending -join ', ')."
    }

    $freezeStatus = [string]$Manifest.artifactFreeze.status
    $freezeCommit = [string]$Manifest.artifactFreeze.sourceCommit
    $sourceCommit = [string]$Manifest.sourceCommits.'camper-gui-v2'
    if ($freezeStatus -eq 'frozen' -and $freezeCommit -eq $sourceCommit) {
        Add-Check GREEN 'Artifact freeze' "GX and WASM artifacts are frozen from source commit $freezeCommit."
    } else {
        Add-Check ERROR 'Artifact freeze' "Status is $freezeStatus for $freezeCommit; direct apply is blocked until the official GX and WASM rebuild is frozen."
    }

    $version = Get-Fact 'VENUS_VERSION'
    $build = Get-Fact 'VENUS_BUILD'
    $architecture = Get-Fact 'ARCHITECTURE'
    $compatibility = Find-CompatibleFirmware $Matrix $version $build $architecture
    if ($compatibility) {
        Add-Check GREEN 'Firmware compatibility' "$version / $build / $architecture is pinned to gui-v2 $($compatibility.guiV2Version), commit $($compatibility.guiRepositoryCommit)."
    } else {
        Add-Check ERROR 'Firmware compatibility' "$version / $build / $architecture is not present in the compatibility matrix. No restore or build is allowed."
    }

    foreach ($disk in @(
        @{ Name = 'Root disk'; Key = 'ROOT_FREE_KB'; Warn = 32768; Error = 16384 },
        @{ Name = 'Data disk'; Key = 'DATA_FREE_KB'; Warn = 131072; Error = 65536 },
        @{ Name = 'Temporary disk'; Key = 'TMP_FREE_KB'; Warn = 65536; Error = 32768 }
    )) {
        $raw = Get-Fact $disk.Key '0'
        $free = 0L
        [void][long]::TryParse($raw, [ref]$free)
        if ($free -lt $disk.Error) {
            Add-Check ERROR $disk.Name "$free KiB free; below the safe audit floor of $($disk.Error) KiB."
        } elseif ($free -lt $disk.Warn) {
            Add-Check WARNING $disk.Name "$free KiB free; installation needs an explicit space review."
        } else {
            Add-Check GREEN $disk.Name "$free KiB free."
        }
    }

    $memory = 0L
    [void][long]::TryParse((Get-Fact 'MEM_AVAILABLE_KB' '0'), [ref]$memory)
    if ($memory -lt 32768) { Add-Check ERROR 'Available memory' "$memory KiB available; Node-RED/GUI stability is unsafe." }
    elseif ($memory -lt 65536) { Add-Check WARNING 'Available memory' "$memory KiB available; watch Node-RED RSS before deployment." }
    else { Add-Check GREEN 'Available memory' "$memory KiB available." }

    $nodeRss = 0L
    [void][long]::TryParse((Get-Fact 'NODE_RED_RSS_KB' '0'), [ref]$nodeRss)
    if ($nodeRss -gt 229376) { Add-Check ERROR 'Node-RED memory' "$nodeRss KiB RSS; near the historical heap-failure range." }
    elseif ($nodeRss -gt 153600) { Add-Check WARNING 'Node-RED memory' "$nodeRss KiB RSS; investigate growth." }
    else { Add-Check GREEN 'Node-RED memory' "$nodeRss KiB RSS." }

    $loadOne = 0.0
    [void][double]::TryParse((Get-Fact 'LOADAVG_1' '0'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$loadOne)
    if ($loadOne -gt 3.0) { Add-Check ERROR 'CPU load' "1-minute load average $loadOne is sustained too high for this Cerbo." }
    elseif ($loadOne -gt 1.5) { Add-Check WARNING 'CPU load' "1-minute load average $loadOne; recheck after idle." }
    else { Add-Check GREEN 'CPU load' "1-minute load average $loadOne." }

    $contextTmpCount = 0
    $contextTmpBytes = 0L
    [void][int]::TryParse((Get-Fact 'NODE_RED_CONTEXT_TMP_COUNT' '0'), [ref]$contextTmpCount)
    [void][long]::TryParse((Get-Fact 'NODE_RED_CONTEXT_TMP_BYTES' '0'), [ref]$contextTmpBytes)
    if ($contextTmpBytes -gt 16777216) { Add-Check ERROR 'Node-RED context temp growth' "$contextTmpCount orphan candidate(s), $contextTmpBytes bytes. Archive before exact cleanup." }
    elseif ($contextTmpCount -gt 0) { Add-Check WARNING 'Node-RED context temp growth' "$contextTmpCount orphan candidate(s), $contextTmpBytes bytes." }
    else { Add-Check GREEN 'Node-RED context temp growth' 'No persisted context *.tmp files found.' }

    $oldGuiCount = 0
    $oldGuiKb = 0L
    [void][int]::TryParse((Get-Fact 'OLD_GUI_TREE_COUNT' '0'), [ref]$oldGuiCount)
    [void][long]::TryParse((Get-Fact 'OLD_GUI_TREE_KB' '0'), [ref]$oldGuiKb)
    if ($oldGuiCount -gt 0) { Add-Check WARNING 'Old GUI trees on root' "$oldGuiCount exact tree(s), $oldGuiKb KiB: $(Get-Fact 'OLD_GUI_TREE_PATHS'). Archive each before targeted removal." }
    else { Add-Check GREEN 'Old GUI trees on root' 'No pre/rollback/failed/candidate GUI trees remain.' }

    foreach ($usage in @(
        @{ Name = 'Root logs'; Key = 'VAR_LOG_KB'; Warn = 16384 },
        @{ Name = 'Node-RED logs'; Key = 'NODE_RED_LOG_KB'; Warn = 8192 },
        @{ Name = 'Node-RED context'; Key = 'NODE_RED_CONTEXT_KB'; Warn = 32768 },
        @{ Name = 'CamperControl data'; Key = 'CAMPERCONTROL_DATA_KB'; Warn = 262144 },
        @{ Name = 'CamperControl release store'; Key = 'CAMPERCONTROL_RELEASES_KB'; Warn = 196608 },
        @{ Name = 'CamperControl staging'; Key = 'CAMPERCONTROL_STAGING_KB'; Warn = 65536 },
        @{ Name = 'CamperControl incoming'; Key = 'CAMPERCONTROL_INCOMING_KB'; Warn = 32768 }
    )) {
        $size = 0L
        [void][long]::TryParse((Get-Fact $usage.Key '0'), [ref]$size)
        if ($size -gt $usage.Warn) { Add-Check WARNING $usage.Name "$size KiB; review bounded directory growth." }
        else { Add-Check GREEN $usage.Name "$size KiB." }
    }

    $modifications = Get-Fact 'VENUS_MODIFICATIONS'
    switch ($modifications) {
        'enabled' { Add-Check GREEN 'Venus modifications' '/data/rc.local exists and is executable.' }
        'disabled' { Add-Check WARNING 'Venus modifications' '/data/rc.local.disabled exists. Firmware update restore is intentionally blocked until modifications are re-enabled.' }
        default { Add-Check ERROR 'Venus modifications' "State is $modifications; restore hooks cannot be trusted." }
    }

    $integrity = Get-Fact 'PERSISTENT_RELEASE_INTEGRITY'
    switch ($integrity) {
        'ok' { Add-Check GREEN 'Persistent release' "Checksums pass at /data/campercontrol/releases/$script:ReleaseId." }
        'missing' { Add-Check WARNING 'Persistent release' 'No persistent offline release is installed yet.' }
        default { Add-Check ERROR 'Persistent release' "Checksum state is $integrity. Do not restore from this copy." }
    }

    $expectedGx = [string]$Manifest.artifacts.gxArchive.binarySha256
    $actualGx = Get-Fact 'GX_SHA256'
    if ($actualGx -eq $expectedGx) { Add-Check GREEN 'GX install' "venus-gui-v2 matches $actualGx." }
    elseif ($actualGx -eq 'missing') { Add-Check ERROR 'GX install' 'Native gui-v2 binary is missing.' }
    else { Add-Check ERROR 'GX install' "Installed hash $actualGx differs from release hash $expectedGx." }

    $expectedWasm = [string]$Manifest.artifacts.wasmArchive.wasmGzipSha256
    $actualWasm = Get-Fact 'WASM_GZIP_SHA256'
    if ($actualWasm -eq $expectedWasm) { Add-Check GREEN 'WASM install' "venus-gui-v2.wasm.gz matches $actualWasm." }
    elseif ($actualWasm -eq 'missing') { Add-Check ERROR 'WASM install' 'Remote Console WASM gzip is missing.' }
    else { Add-Check ERROR 'WASM install' "Installed hash $actualWasm differs from release hash $expectedWasm." }

    $serviceStatus = Get-Fact 'CAMPER_SERVICE_STATUS'
    $serviceLink = Get-Fact 'CAMPER_SERVICE_LINK'
    if ($serviceLink -match '^/data/campercontrol/service/' -and $serviceStatus -match '^up:') {
        Add-Check GREEN 'Camper D-Bus service' "$serviceStatus; link $serviceLink."
    } else {
        Add-Check ERROR 'Camper D-Bus service' "Status $serviceStatus; link $serviceLink."
    }
    $apiConnected = Get-Fact 'CAMPER_DBUS_API_CONNECTED'
    if ($apiConnected -match '(^|\s)1($|\s)') {
        Add-Check GREEN 'Camper D-Bus data' "ApiConnected reports $apiConnected."
    } else {
        Add-Check WARNING 'Camper D-Bus data' "ApiConnected reports $apiConnected; the service may be waiting for Node-RED."
    }

    if ((Get-Fact 'MQTT_FLASHMQ') -eq 'running') { Add-Check GREEN 'MQTT broker' 'FlashMQ is running.' }
    else { Add-Check ERROR 'MQTT broker' 'FlashMQ was not observed.' }
    foreach ($transport in @(
        @{ Name = 'MQTT GXdbus bridge'; Key = 'MQTT_GXDBUS' },
        @{ Name = 'MQTT GXrpc bridge'; Key = 'MQTT_GXRPC' },
        @{ Name = 'VRM logger'; Key = 'VRM_LOGGER' }
    )) {
        if ((Get-Fact $transport.Key) -eq 'running') { Add-Check GREEN $transport.Name 'Process observed.' }
        else { Add-Check WARNING $transport.Name 'Process name was not observed; verify VRM connectivity and firmware naming on the Cerbo.' }
    }

    if ((Get-Fact 'NODE_RED_API') -eq 'reachable') { Add-Check GREEN 'Node-RED API' 'Local CamperControl state API responds.' }
    else { Add-Check ERROR 'Node-RED API' 'Local CamperControl state API is unreachable.' }
    $nodeCount = Get-Fact 'NODE_RED_FLOW_COUNT'
    $expectedNodeCount = [string]$Manifest.artifacts.nodeRedFlow.nodes
    if ($expectedNodeCount -match '^__PENDING_') { Add-Check WARNING 'Node-RED node count' "Observed $nodeCount; final expected count is intentionally pending." }
    elseif ($nodeCount -eq $expectedNodeCount) { Add-Check GREEN 'Node-RED node count' "Exactly $expectedNodeCount nodes are active." }
    elseif ($nodeCount -eq 'unavailable') { Add-Check WARNING 'Node-RED node count' 'The read-only /flows query could not be evaluated.' }
    else { Add-Check ERROR 'Node-RED node count' "Expected $expectedNodeCount, observed $nodeCount." }

    $expectedFlow = [string]$Manifest.artifacts.nodeRedFlow.sha256
    $actualFlow = Get-Fact 'NODE_RED_FLOW_SHA256'
    if ($expectedFlow -match '^__PENDING_') { Add-Check WARNING 'Node-RED flow hash' "Runtime is $actualFlow; the final distribution hash is intentionally pending." }
    elseif ($actualFlow -eq $expectedFlow) { Add-Check GREEN 'Node-RED flow hash' "Runtime file matches $expectedFlow." }
    elseif ($actualFlow -eq 'missing') { Add-Check WARNING 'Node-RED flow hash' 'No known runtime flow file was found; the API count remains authoritative.' }
    else { Add-Check WARNING 'Node-RED flow hash' "Runtime file hash $actualFlow differs from the distribution export $expectedFlow; deployed credentials or runtime formatting may explain this, so review before import." }

    $state = Get-Fact 'NODE_RED_STATE'
    if ($state -match 'orion_online=True') {
        Add-Check GREEN 'Orion XS' "$state."
    } elseif ($state -match 'orion_online=False') {
        Add-Check WARNING 'Orion XS' "Offline according to fresh telemetry ($state); no stale mode is treated as a valid state."
    } else {
        Add-Check WARNING 'Orion XS' "State unavailable ($state)."
    }
    if ($state -match 'shelly_available=True') {
        Add-Check GREEN 'Shelly / INDEVOLT grid' "$state."
    } elseif ($state -match 'shelly_available=False') {
        Add-Check GREEN 'Shelly / INDEVOLT grid' 'Expected-off semantics: the Shelly may be unpowered while 230 V is off; this is not a failure and no BLE fallback is activated.'
    } else {
        Add-Check WARNING 'Shelly / INDEVOLT grid' 'State unavailable; the optional BLE PoC remains disabled.'
    }

    $weatherStatus = Get-Fact 'WEATHER_DBUS_STATUS'
    $weatherBytes = 0L
    $weatherCacheBytes = 0L
    [void][long]::TryParse((Get-Fact 'WEATHER_DBUS_STATE_BYTES' '0'), [ref]$weatherBytes)
    [void][long]::TryParse((Get-Fact 'WEATHER_CACHE_BYTES' '0'), [ref]$weatherCacheBytes)
    if ($weatherStatus -eq 'ready' -and $weatherBytes -gt 0 -and $weatherBytes -le 16384) {
        Add-Check GREEN 'DWD weather state' "$weatherBytes bytes on /State/Weather; cache $weatherCacheBytes bytes."
    } elseif ($weatherStatus -eq 'ready') {
        Add-Check WARNING 'DWD weather state' "Payload is $weatherBytes bytes; cache is $weatherCacheBytes bytes. Review the 16-KiB service budget."
    } else {
        Add-Check WARNING 'DWD weather state' "Status $weatherStatus; error $(Get-Fact 'WEATHER_ERROR'). Cached data may still be used."
    }

    $backupCount = 0
    [void][int]::TryParse((Get-Fact 'BACKUP_COUNT' '0'), [ref]$backupCount)
    $backupIntegrity = Get-Fact 'LATEST_BACKUP_INTEGRITY'
    if ($backupCount -gt 0 -and $backupIntegrity -eq 'ok') {
        Add-Check GREEN 'Backups' "$backupCount compressed backup(s); newest checksum passes."
    } elseif ($backupIntegrity -eq 'failed') {
        Add-Check ERROR 'Backups' 'Newest compressed backup fails its SHA-256 sidecar.'
    } else {
        Add-Check WARNING 'Backups' "$backupCount compressed backup(s); no verified newest sidecar was found."
    }
}

function Write-MaintenanceReport {
    param([string]$Mode)
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    if (-not $ReportDirectory) {
        $base = Join-Path ([IO.Path]::GetTempPath()) 'CamperControl-Reports'
        $script:ResolvedReportDirectory = Join-Path $base $timestamp
    } else {
        $script:ResolvedReportDirectory = [IO.Path]::GetFullPath($ReportDirectory)
    }
    New-Item -ItemType Directory -Path $script:ResolvedReportDirectory -Force | Out-Null
    $summary = [ordered]@{
        green = @($script:Checks | Where-Object status -eq 'GREEN').Count
        warning = @($script:Checks | Where-Object status -eq 'WARNING').Count
        error = @($script:Checks | Where-Object status -eq 'ERROR').Count
    }
    $report = [ordered]@{
        schema = 'campercontrol-maintenance-report-v1'
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        release = $script:ReleaseId
        mode = $Mode
        target = "$SshUser@$CerboHost"
        summary = $summary
        checks = @($script:Checks)
        remoteFacts = $script:RemoteFacts
    }
    $jsonPath = Join-Path $script:ResolvedReportDirectory 'report.json'
    $textPath = Join-Path $script:ResolvedReportDirectory 'report.txt'
    $zipPath = "$($script:ResolvedReportDirectory).zip"
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("CamperControl maintenance report - $($report.generatedAtUtc)")
    $lines.Add("Release: $($report.release)")
    $lines.Add("Mode: $Mode")
    $lines.Add("Summary: GREEN=$($summary.green) WARNING=$($summary.warning) ERROR=$($summary.error)")
    $lines.Add('')
    foreach ($check in $script:Checks) { $lines.Add("[$($check.status)] $($check.name): $($check.detail)") }
    $lines | Set-Content -LiteralPath $textPath -Encoding UTF8
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path $jsonPath, $textPath -DestinationPath $zipPath -CompressionLevel Optimal
    foreach ($check in $script:Checks) {
        $color = switch ($check.status) { 'GREEN' { 'Green' } 'WARNING' { 'Yellow' } default { 'Red' } }
        Write-Host "[$($check.status)] $($check.name): $($check.detail)" -ForegroundColor $color
    }
    Write-Host "Report: $textPath"
    Write-Host "JSON:   $jsonPath"
    Write-Host "ZIP:    $zipPath"
    return [pscustomobject]@{ Report = $report; JsonPath = $jsonPath; TextPath = $textPath; ZipPath = $zipPath }
}

function Invoke-ReadOnlyAudit {
    $script:Checks.Clear()
    $manifest = Get-Manifest
    $matrix = Get-CompatibilityMatrix
    $remote = Invoke-RemoteScript -Path $script:HealthScriptPath
    $script:RemoteFacts = ConvertFrom-KeyValueLines $remote.Output
    if ((Get-Fact 'SCHEMA') -ne 'campercontrol-health-v2') {
        throw 'Remote health output did not contain the expected schema.'
    }
    Add-AuditChecks $manifest $matrix
    return [pscustomobject]@{ Manifest = $manifest; Matrix = $matrix }
}

function Invoke-ApplyRelease {
    param($Audit)
    Assert-ReleaseFinalized
    if ([string]$Audit.Manifest.artifactFreeze.status -ne 'frozen' -or
        [string]$Audit.Manifest.artifactFreeze.sourceCommit -ne [string]$Audit.Manifest.sourceCommits.'camper-gui-v2') {
        throw 'Apply blocked: release artifacts are not frozen from the declared gui-v2 source commit.'
    }
    $compatible = Find-CompatibleFirmware $Audit.Matrix (Get-Fact 'VENUS_VERSION') (Get-Fact 'VENUS_BUILD') (Get-Fact 'ARCHITECTURE')
    if (-not $compatible -and -not $ForceFirmwareMismatch) {
        throw 'Apply blocked: firmware/architecture mismatch. Use -ForceFirmwareMismatch only after a manual compatibility review.'
    }
    if ($ForceFirmwareMismatch) {
        Write-Warning 'DANGER: a restore is being forced onto firmware not pinned by this release.'
    }
    if (-not $PSCmdlet.ShouldProcess("$SshUser@$CerboHost", "Backup, persist and reinstall $script:ReleaseId")) { return }

    $persistentState = Get-Fact 'PERSISTENT_RELEASE_INTEGRITY'
    if ($persistentState -eq 'failed') {
        throw 'Apply blocked: the existing persistent release copy fails checksums and is never overwritten automatically.'
    }
    if ($persistentState -ne 'ok') {
        $incomingParent = '/data/campercontrol/incoming'
        $stage = "$incomingParent/$script:ReleaseId"
        $preflight = Invoke-SshCommand -RemoteCommand "test -d /data/campercontrol; test ! -L /data/campercontrol; mkdir -p '$incomingParent'; test -d '$incomingParent'; test ! -L '$incomingParent'; test ! -e '$stage'" -AllowFailure
        if ($preflight.ExitCode -ne 0) { throw "Remote stage already exists: $stage" }
        $scp = Get-Command scp -ErrorAction Stop
        $scpArguments = [System.Collections.Generic.List[string]]::new()
        foreach ($option in (Get-SshOptions)) { $scpArguments.Add($option) }
        $scpArguments.Add('-r')
        $scpArguments.Add($script:ReleaseRoot)
        $scpArguments.Add("$SshUser@${CerboHost}:$stage")
        & $scp.Source @scpArguments
        if ($LASTEXITCODE -ne 0) { throw "SCP failed with exit code $LASTEXITCODE." }
        $install = Invoke-SshCommand -RemoteCommand "'$stage/tools/install-persistent-release.sh'"
        $install.Output | ForEach-Object { Write-Host $_ }
        $cleanupIncoming = Invoke-SshCommand -RemoteCommand "case '$stage' in '$incomingParent/$script:ReleaseId') test -d '$stage' && test ! -L '$stage' && rm -rf '$stage' ;; *) exit 9 ;; esac"
        $cleanupIncoming.Output | ForEach-Object { Write-Host $_ }
    }

    $forceArgument = if ($ForceFirmwareMismatch) { ' --force-incompatible' } else { '' }
    $command = "'/data/campercontrol/releases/$script:ReleaseId/tools/reinstall-after-update.sh' --confirm-v3.80~39$forceArgument"
    $result = Invoke-SshCommand -RemoteCommand $command
    $result.Output | ForEach-Object { Write-Host $_ }
}

function Invoke-Git {
    param([string]$Repository, [string[]]$Arguments, [switch]$AllowFailure)
    $git = Get-Command git -ErrorAction Stop
    $output = & $git.Source -c 'safe.directory=*' -C $Repository @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw "git $($Arguments -join ' ') failed: $($output -join ' ')" }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = @($output | ForEach-Object { [string]$_ }) }
}

function ConvertTo-WslPath {
    param([string]$WindowsPath)
    $result = & wsl.exe wslpath -a $WindowsPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "WSL path conversion failed: $($result -join ' ')" }
    return ([string]($result | Select-Object -Last 1)).Trim()
}

function Quote-Bash {
    param([string]$Value)
    $singleQuote = [char]39
    $doubleQuote = [char]34
    $replacement = "$singleQuote$doubleQuote$singleQuote$doubleQuote$singleQuote"
    return "$singleQuote$($Value.Replace([string]$singleQuote, $replacement))$singleQuote"
}

function Invoke-WslBash {
    param([string]$Command)
    $output = & wsl.exe bash -lc $Command 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "WSL command failed with exit code $exitCode. $($output -join [Environment]::NewLine)" }
    return @($output | ForEach-Object { [string]$_ })
}

function Invoke-KnownCompatibleBuild {
    param($Audit)
    $compatible = Find-CompatibleFirmware $Audit.Matrix (Get-Fact 'VENUS_VERSION') (Get-Fact 'VENUS_BUILD') (Get-Fact 'ARCHITECTURE')
    if (-not $compatible) {
        throw 'Build blocked: detected firmware is unknown. Source is never auto-ported.'
    }
    if (-not $GuiRepository) { throw '-GuiRepository is required with -Build.' }
    $repository = (Resolve-Path -LiteralPath $GuiRepository).Path
    $status = Invoke-Git $repository @('status', '--porcelain=v1', '--untracked-files=normal')
    if ($status.Output.Count -gt 0) { throw "Build blocked: gui-v2 worktree is not clean. $($status.Output -join '; ')" }
    $head = (Invoke-Git $repository @('rev-parse', 'HEAD')).Output[-1].Trim()
    $expectedCommit = [string]$compatible.guiRepositoryCommit
    if ($head -ne $expectedCommit) {
        $known = Invoke-Git $repository @('cat-file', '-e', "$expectedCommit^{commit}") -AllowFailure
        if ($known.ExitCode -ne 0 -and $AllowNetwork) {
            [void](Invoke-Git $repository @('fetch', 'origin', $expectedCommit))
            Write-Warning 'The pinned commit was fetched, but no checkout or merge was performed.'
        }
        throw "Build blocked: HEAD is $head; expected $expectedCommit. Create or checkout a clean compatible worktree manually."
    }
    if ($AllowNetwork) {
        Write-Host 'Network permission is enabled, but no fetch is needed because the exact commit is already checked out.'
    }

    $python = Get-Command $PythonCommand -ErrorAction Stop
    Push-Location $repository
    try {
        & $python.Source -m unittest tests/camper_v2_panels_contract.py tests/camper_vrm_transport_contract.py
        if ($LASTEXITCODE -ne 0) { throw 'VRM transport contract failed.' }
        & $python.Source tools/camper-preview/smoke_test.py
        if ($LASTEXITCODE -ne 0) { throw '800x480 touch/viewport contract failed.' }
    } finally {
        Pop-Location
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'WSL is required for the official build scripts.' }
    $repositoryWsl = ConvertTo-WslPath $repository
    $quotedRepository = Quote-Bash $repositoryWsl
    [void](Invoke-WslBash "set -euo pipefail; cd $quotedRepository; test -x scripts/build-gx.sh; test -x scripts/build-wasm.sh; ./scripts/build-gx.sh")
    [void](Invoke-WslBash "set -euo pipefail; cd $quotedRepository; ./scripts/build-wasm.sh")

    $gxStage = Join-Path $repository 'build-gx_files_to_copy'
    $wasmStage = Join-Path $repository 'build-wasm_files_to_copy\wasm'
    $gxBinary = Join-Path $gxStage 'venus-gui-v2'
    $wasmGzip = Join-Path $wasmStage 'venus-gui-v2.wasm.gz'
    $wasmJs = Join-Path $wasmStage 'venus-gui-v2.js'
    foreach ($required in @($gxStage, $wasmStage, $gxBinary, $wasmGzip, $wasmJs)) {
        if (-not (Test-Path -LiteralPath $required)) { throw "Official build did not produce $required" }
    }

    if (-not $BuildOutputDirectory) {
        $BuildOutputDirectory = Join-Path (Get-Location) "campercontrol-build-$($compatible.venusVersion.Replace('~','-'))"
    }
    $outputDirectory = [IO.Path]::GetFullPath($BuildOutputDirectory)
    if (Test-Path -LiteralPath $outputDirectory) { throw "Build output already exists: $outputDirectory" }
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
    $gxArchive = Join-Path $outputDirectory 'camper-gui-v2-gx.tar.gz'
    $wasmArchive = Join-Path $outputDirectory 'camper-gui-v2-wasm.tar.gz'
    $gxWsl = ConvertTo-WslPath $gxStage
    $wasmWsl = ConvertTo-WslPath $wasmStage
    $gxArchiveWsl = ConvertTo-WslPath $gxArchive
    $wasmArchiveWsl = ConvertTo-WslPath $wasmArchive
    [void](Invoke-WslBash "set -euo pipefail; tar -czf $(Quote-Bash $gxArchiveWsl) -C $(Quote-Bash $gxWsl) .; tar -czf $(Quote-Bash $wasmArchiveWsl) -C $(Quote-Bash $wasmWsl) .")

    $gxFiles = @(Get-ChildItem -LiteralPath $gxStage -Recurse -File)
    $wasmFiles = @(Get-ChildItem -LiteralPath $wasmStage -Recurse -File)
    $buildManifest = [ordered]@{
        schema = 'campercontrol-known-compatible-build-v1'
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        sourceCommit = $head
        compatibility = $compatible
        contracts = [ordered]@{ v2Panels = 'passed'; vrm = 'passed'; touch800x480 = 'passed' }
        gx = [ordered]@{
            archive = (Split-Path $gxArchive -Leaf)
            archiveSha256 = (Get-FileHash -LiteralPath $gxArchive -Algorithm SHA256).Hash.ToLowerInvariant()
            fileCount = $gxFiles.Count
            bytes = ($gxFiles | Measure-Object Length -Sum).Sum
            binarySha256 = (Get-FileHash -LiteralPath $gxBinary -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        wasm = [ordered]@{
            archive = (Split-Path $wasmArchive -Leaf)
            archiveSha256 = (Get-FileHash -LiteralPath $wasmArchive -Algorithm SHA256).Hash.ToLowerInvariant()
            fileCount = $wasmFiles.Count
            bytes = ($wasmFiles | Measure-Object Length -Sum).Sum
            gzipSha256 = (Get-FileHash -LiteralPath $wasmGzip -Algorithm SHA256).Hash.ToLowerInvariant()
            javascriptSha256 = (Get-FileHash -LiteralPath $wasmJs -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $buildManifestPath = Join-Path $outputDirectory 'build-manifest.json'
    $buildManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $buildManifestPath -Encoding UTF8
    $checksumPath = Join-Path $outputDirectory 'checksums.sha256'
    @($gxArchive, $wasmArchive, $buildManifestPath) | ForEach-Object {
        $hash = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $(Split-Path $_ -Leaf)"
    } | Set-Content -LiteralPath $checksumPath -Encoding ascii
    Write-Host "Known-compatible build package: $outputDirectory"
}

function Invoke-OfflineSelfTest {
    $script:Checks.Clear()
    $manifest = Get-Manifest
    $matrix = Get-CompatibilityMatrix
    $known = @($matrix.knownFirmware)[0]
    $script:RemoteFacts = [ordered]@{
        SCHEMA = 'campercontrol-health-v2'
        VENUS_VERSION = [string]$known.venusVersion
        VENUS_BUILD = [string]$known.venusBuild
        ARCHITECTURE = [string]$known.architecture
        ROOT_FREE_KB = '65536'
        DATA_FREE_KB = '524288'
        TMP_FREE_KB = '262144'
        LOADAVG_1 = '0.25'
        LOADAVG_5 = '0.20'
        LOADAVG_15 = '0.15'
        MEM_AVAILABLE_KB = '131072'
        MEM_TOTAL_KB = '524288'
        NODE_RED_RSS_KB = '65536'
        NODE_RED_CONTEXT_TMP_COUNT = '0'
        NODE_RED_CONTEXT_TMP_BYTES = '0'
        OLD_GUI_TREE_COUNT = '0'
        OLD_GUI_TREE_KB = '0'
        OLD_GUI_TREE_PATHS = 'none'
        VAR_LOG_KB = '2048'
        NODE_RED_LOG_KB = '1024'
        NODE_RED_CONTEXT_KB = '4096'
        CAMPERCONTROL_DATA_KB = '32768'
        CAMPERCONTROL_RELEASES_KB = '24576'
        CAMPERCONTROL_STAGING_KB = '0'
        CAMPERCONTROL_INCOMING_KB = '0'
        VENUS_MODIFICATIONS = 'enabled'
        PERSISTENT_RELEASE_INTEGRITY = 'ok'
        GX_SHA256 = [string]$manifest.artifacts.gxArchive.binarySha256
        WASM_GZIP_SHA256 = [string]$manifest.artifacts.wasmArchive.wasmGzipSha256
        CAMPER_SERVICE_LINK = '/data/campercontrol/service/campercontrol-dbus-service'
        CAMPER_SERVICE_STATUS = 'up: campercontrol-dbus: 42 seconds'
        CAMPER_DBUS_API_CONNECTED = '1'
        MQTT_FLASHMQ = 'running'
        MQTT_GXDBUS = 'running'
        MQTT_GXRPC = 'running'
        VRM_LOGGER = 'running'
        NODE_RED_API = 'reachable'
        NODE_RED_FLOW_COUNT = '358'
        NODE_RED_FLOW_SHA256 = [string]$manifest.artifacts.nodeRedFlow.sha256
        NODE_RED_STATE = 'orion_online=True;orion_mode=1;orion_state=FLOAT;shelly_available=False;shelly_on=False'
        WEATHER_DBUS_STATUS = 'ready'
        WEATHER_DBUS_STATE_BYTES = '9003'
        WEATHER_CACHE_BYTES = '9003'
        WEATHER_ERROR = ''
        BACKUP_COUNT = '3'
        LATEST_BACKUP_INTEGRITY = 'ok'
    }
    Add-AuditChecks $manifest $matrix -AllowPending
    if (@($script:Checks | Where-Object status -eq 'ERROR').Count -ne 0) {
        throw 'Offline self-test expected zero ERROR checks.'
    }
    $report = Write-MaintenanceReport 'self-test'
    if (-not (Test-Path -LiteralPath $report.ZipPath)) { throw 'Offline self-test did not create a ZIP report.' }
    Write-Host 'MAINTENANCE_SELF_TEST_OK'
}

if ($Apply -and $Build) { throw '-Apply and -Build are intentionally separate operations.' }
if ($AllowNetwork -and -not $Build) { throw '-AllowNetwork is valid only with -Build.' }
if ($ForceFirmwareMismatch -and -not $Apply) { throw '-ForceFirmwareMismatch is valid only with -Apply.' }
Assert-SshInputs

if ($SelfTest) {
    Invoke-OfflineSelfTest
    exit 0
}

$audit = Invoke-ReadOnlyAudit
$mode = if ($Build) { 'build-preflight' } elseif ($Apply) { 'apply-preflight' } else { 'read-only' }
$writtenReport = Write-MaintenanceReport $mode

if ($Build) {
    if (@($script:Checks | Where-Object { $_.name -eq 'Firmware compatibility' -and $_.status -eq 'ERROR' }).Count -gt 0) {
        throw "Build blocked by compatibility report: $($writtenReport.TextPath)"
    }
    Invoke-KnownCompatibleBuild $audit
} elseif ($Apply) {
    Invoke-ApplyRelease $audit
} elseif ($script:Checks | Where-Object status -eq 'ERROR') {
    exit 2
}
