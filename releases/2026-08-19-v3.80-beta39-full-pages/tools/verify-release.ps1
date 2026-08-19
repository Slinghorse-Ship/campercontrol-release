[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$releaseRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$checksumFile = Join-Path $releaseRoot "checksums.sha256"
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
    $relativePath = $parts[1].Replace("/", [IO.Path]::DirectorySeparatorChar)
    $filePath = Join-Path $releaseRoot $relativePath
    $actual = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($actual -ne $expected) {
        Write-Error "Checksum mismatch: $relativePath" -ErrorAction Continue
        $failures++
    } else {
        Write-Host "OK  $relativePath"
    }
}

if ($failures -gt 0) {
    throw "$failures release file(s) failed verification."
}

Write-Host "Release verification passed."

