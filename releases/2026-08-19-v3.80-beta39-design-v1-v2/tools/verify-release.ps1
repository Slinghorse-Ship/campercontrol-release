[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$releaseRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$checksumFile = Join-Path $releaseRoot "checksums.sha256"
$manifestFile = Join-Path $releaseRoot "release.json"
$temporaryRoot = $null

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

if (-not (Test-Path -LiteralPath $checksumFile -PathType Leaf)) {
    throw "checksums.sha256 does not exist"
}
if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) {
    throw "release.json does not exist"
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

$manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
Assert-Equal $manifest.release (Split-Path $releaseRoot -Leaf) "Release directory"
Assert-Equal $manifest.deployed $false "Deployment state"
Assert-Equal $manifest.designs.default "v2" "Default design"

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

$flowPath = Resolve-ReleaseFile $manifest.artifacts.nodeRedFlow.path
$flowNodes = @(Get-Content -LiteralPath $flowPath -Raw | ConvertFrom-Json)
Assert-Equal $flowNodes.Count $manifest.artifacts.nodeRedFlow.nodes "Node-RED node count"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$syncPath = Resolve-ReleaseFile $manifest.artifacts.syncArchive.path
$syncZip = [IO.Compression.ZipFile]::OpenRead($syncPath)
try {
    Assert-Equal $syncZip.Entries.Count $manifest.artifacts.syncArchive.entries "SYNC ZIP entry count"
} finally {
    $syncZip.Dispose()
}

$gxPath = Resolve-ReleaseFile $manifest.artifacts.gxArchive.path
$wasmPath = Resolve-ReleaseFile $manifest.artifacts.wasmArchive.path
$gxEntries = @(Get-SafeTarEntries $gxPath)
$wasmEntries = @(Get-SafeTarEntries $wasmPath)
$gxFileEntries = @($gxEntries | Where-Object { -not $_.EndsWith("/") })
$wasmFileEntries = @($wasmEntries | Where-Object { -not $_.EndsWith("/") })
Assert-Equal $gxFileEntries.Count $manifest.artifacts.gxArchive.files "GX archive file count"
Assert-Equal $wasmFileEntries.Count $manifest.artifacts.wasmArchive.files "WASM archive file count"

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

    $wasmGzip = Join-Path $wasmExtract $manifest.artifacts.wasmArchive.wasmGzipPath
    Assert-Equal (Get-Sha256 $wasmGzip) $manifest.artifacts.wasmArchive.wasmGzipSha256 "WASM gzip"

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

    $sidecar = Get-Content -LiteralPath (Join-Path $wasmExtract "venus-gui-v2.wasm.sha256") -Raw
    $sidecarHash = ($sidecar -split '\s+')[0].ToLowerInvariant()
    Assert-Equal $sidecarHash $manifest.artifacts.wasmArchive.wasmSha256 "WASM sidecar"

    $wasmIndex = Get-Content -LiteralPath (Join-Path $wasmExtract "index.html") -Raw
    if ($wasmIndex -notmatch "const nodeRedUrl = location\.protocol === 'https:'" -or
        $wasmIndex -notmatch "':1881'" -or $wasmIndex -notmatch "':1880'") {
        throw "WASM index.html does not contain the expected Node-RED port selection"
    }
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
