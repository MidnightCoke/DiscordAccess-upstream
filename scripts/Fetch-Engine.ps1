# Download the exact unmodified upstream dependency. Never executes it.
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$workRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'work'))
$engineRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'engine'))
$enginePath = [IO.Path]::GetFullPath((Join-Path $engineRoot 'sing-box.exe'))
$version = '1.14.3'
$url = 'https://github.com/SagerNet/sing-box/releases/download/v1.14.3/sing-box-1.14.3-windows-amd64.zip'
$zipSha256 = 'D8B86EF58936DBA9230EC6A57FFA4243933F3C14EF4809828B6C553440ED1518'
$exeSha256 = '5C19BB3F8C12D4E85B3D47FE63123A7624B314B58DD7A8E32F51004F1C4D2FAF'
$entryName = 'sing-box-1.14.3-windows-amd64/sing-box.exe'

function Assert-LocalPath([string] $path) {
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
        -not [String]::Equals($full, $repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Dependency path escaped the repository.'
    }
    if ($full.StartsWith('\\', [StringComparison]::Ordinal) -or $full.IndexOf(':', 2) -ge 0) {
        throw 'Use a local repository path.'
    }
    for ($current = $full; $current; $current = [IO.Path]::GetDirectoryName($current)) {
        try {
            $attributes = [IO.File]::GetAttributes($current)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Dependency download paths must not contain reparse points.'
            }
        } catch [IO.FileNotFoundException] {
        } catch [IO.DirectoryNotFoundException] {
        }
    }
}

Assert-LocalPath $enginePath
if ([IO.File]::Exists($enginePath)) {
    if ((Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash -ne $exeSha256) {
        throw 'An existing engine has an unexpected hash; it was not replaced.'
    }
    Write-Output "sing-box $version Windows amd64 already verified."
    return
}
Assert-LocalPath $workRoot
[void][IO.Directory]::CreateDirectory($workRoot)
$temporaryRoot = [IO.Path]::GetFullPath((Join-Path $workRoot ('engine-fetch-' + [Guid]::NewGuid().ToString('N'))))
Assert-LocalPath $temporaryRoot
[void][IO.Directory]::CreateDirectory($temporaryRoot)
$zipPath = Join-Path $temporaryRoot 'upstream.zip'
$verifiedExe = Join-Path $temporaryRoot 'sing-box.exe'
try {
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
    if ((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash -ne $zipSha256) {
        throw 'Upstream ZIP hash did not match the pinned release.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        # Read exactly one known entry; never extract arbitrary archive paths.
        $entry = $archive.GetEntry($entryName)
        if ($null -eq $entry -or $entry.Length -ne 81987584) { throw 'Expected engine ZIP entry missing or changed.' }
        $inputStream = $entry.Open()
        try {
            $outputStream = [IO.File]::Open($verifiedExe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
        } finally { $inputStream.Dispose() }
    } finally { $archive.Dispose() }
    if ((Get-FileHash -LiteralPath $verifiedExe -Algorithm SHA256).Hash -ne $exeSha256) {
        throw 'Extracted engine hash did not match the application dependency.'
    }
    Assert-LocalPath $engineRoot
    Assert-LocalPath $enginePath
    [void][IO.Directory]::CreateDirectory($engineRoot)
    [IO.File]::Move($verifiedExe, $enginePath)
    Write-Output "sing-box $version Windows amd64 downloaded and verified; no executable was run."
} finally {
    # Delete only this generated directory inside this repository's work folder.
    $cleanupRoot = [IO.Path]::GetFullPath($temporaryRoot)
    if (-not $cleanupRoot.StartsWith($workRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cleanup path escaped the repository work directory.'
    }
    Assert-LocalPath $cleanupRoot
    if ([IO.Directory]::Exists($cleanupRoot)) { Remove-Item -LiteralPath $cleanupRoot -Recurse -Force }
}
