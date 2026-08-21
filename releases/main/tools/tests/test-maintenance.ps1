[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tools = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$maintenance = Join-Path $tools 'CamperControl-Maintenance.ps1'
$health = Join-Path $tools 'campercontrol-health-readonly.sh'
$matrix = Join-Path $tools 'compatibility-matrix.json'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('campercontrol-maintenance-test-' + [guid]::NewGuid().ToString('N'))

try {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($maintenance, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | ForEach-Object Message | Out-String) }
    $source = Get-Content -LiteralPath $maintenance -Raw -Encoding UTF8
    foreach ($required in @('-Apply', '-Build', 'ForceFirmwareMismatch', 'Assert-ReleaseFinalized', 'reinstall-after-update.sh', 'build-gx.sh', 'build-wasm.sh', 'camper_v2_panels_contract.py', 'camper_vrm_transport_contract.py', 'smoke_test.py')) {
        if (-not $source.Contains($required)) { throw "Maintenance contract missing: $required" }
    }
    if ($source -match '(?i)password\s*=|ConvertFrom-SecureString|Set-Content[^\r\n]*password') {
        throw 'Maintenance script must not accept, persist or log a password.'
    }
    $healthSource = Get-Content -LiteralPath $health -Raw -Encoding UTF8
    foreach ($required in @('campercontrol-health-v2', 'LOADAVG_1', 'MEM_AVAILABLE_KB', 'NODE_RED_RSS_KB', 'NODE_RED_CONTEXT_TMP_COUNT', 'OLD_GUI_TREE_COUNT', 'WEATHER_CACHE_BYTES', 'WEATHER_LOCATION_CONFIG_BYTES')) {
        if (-not $healthSource.Contains($required)) { throw "Health resource contract missing: $required" }
    }
    foreach ($forbidden in @('dbus-send', 'SetValue', 'mkdir /', 'rm -rf', 'systemctl restart', 'svc -')) {
        if ($healthSource.Contains($forbidden)) { throw "Read-only health script contains forbidden mutation token: $forbidden" }
    }
    $parsedMatrix = Get-Content -LiteralPath $matrix -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($parsedMatrix.knownFirmware).Count -ne 1) { throw 'Expected one explicitly supported firmware entry.' }
    if ($parsedMatrix.knownFirmware[0].guiRepositoryCommit -ne '9e5a5282162b590b1e446958d97bf268915b3c23') {
        throw 'Compatibility matrix is not pinned to the final gui-v2 commit.'
    }
    & $maintenance -SelfTest -ReportDirectory $temporary
    if ($LASTEXITCODE -ne 0) { throw "Maintenance self-test exited with $LASTEXITCODE." }
    foreach ($requiredReport in @('report.json', 'report.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $temporary $requiredReport))) { throw "Missing $requiredReport" }
    }
    $report = Get-Content -LiteralPath (Join-Path $temporary 'report.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($report.schema -ne 'campercontrol-maintenance-report-v1' -or $report.summary.error -ne 0) {
        throw 'Self-test report contract failed.'
    }
    'MAINTENANCE_OFFLINE_TESTS_OK'
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
    if (Test-Path -LiteralPath "$temporary.zip") { Remove-Item -LiteralPath "$temporary.zip" -Force }
}
