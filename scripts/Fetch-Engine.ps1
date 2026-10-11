# Prepare the byte-pinned security build from verified source. Never runs it.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$engineRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'engine'))
$enginePath = [IO.Path]::GetFullPath((Join-Path $engineRoot 'sing-box.exe'))
$builderPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Build-SecurityEngine.ps1'))
$version = '1.14.3-discordaccess.1'
$exeSha256 = '22B6FC758FB36108486819259A3DF7C46381819F3B312E504BF979796FEE5D14'
$exeBytes = 36209152

function Assert-LocalPath([string] $Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Dependency path escaped the repository.'
    }
    if ($full.StartsWith('\\', [StringComparison]::Ordinal) -or $full.IndexOf(':', 2) -ge 0) {
        throw 'Use a local repository path.'
    }
    for ($current = $full; $current; $current = [IO.Path]::GetDirectoryName($current)) {
        try {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Dependency paths must not contain reparse points.'
            }
        } catch [IO.FileNotFoundException] { } catch [IO.DirectoryNotFoundException] { }
    }
}

function Assert-Engine {
    Assert-LocalPath $enginePath
    if (-not [IO.File]::Exists($enginePath) -or
        (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash -ne $exeSha256 -or
        ([IO.FileInfo]$enginePath).Length -ne $exeBytes) {
        throw 'An existing or prepared engine differs from the pinned security build; it was not replaced or executed.'
    }
}

Assert-LocalPath $engineRoot
Assert-LocalPath $enginePath
if ([IO.Directory]::Exists($enginePath)) { throw 'The engine path is a directory; it was not changed.' }
if ([IO.File]::Exists($enginePath)) {
    Assert-Engine
    Write-Output "sing-box $version Windows amd64 already verified; no executable was run."
    return
}
Assert-LocalPath $builderPath
if (-not [IO.File]::Exists($builderPath)) { throw 'Pinned source builder is missing.' }
& $builderPath -OutFile $enginePath
Assert-Engine
Write-Output "sing-box $version Windows amd64 built from pinned source and verified; no engine was run."
