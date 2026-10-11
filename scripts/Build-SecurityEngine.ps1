# Build the pinned stable source with byte-pinned dependency locks. This script
# never runs sing-box, edits Windows settings, or installs a system toolchain.
[CmdletBinding()]
param([string] $OutFile)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$workRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'work'))
$sourceCommit = '7054cac5124465ffdb145870d7c01885566711b1'
$sourceUrl = 'https://github.com/SagerNet/sing-box/archive/7054cac5124465ffdb145870d7c01885566711b1.zip'
$sourceSha = 'CD8A3508F36D74EF7C9C515BDC8586F048FD06C22499D38EE3787FAA7D220F74'
$goVersion = 'go1.26.9'
$goUrl = 'https://go.dev/dl/go1.26.9.windows-amd64.zip'
$goSha = 'D722201A9C0C086D1610E111C48203009AF690892ED708072BD5AE20160E7A59'
$engineVersion = '1.14.3-discordaccess.1'
$engineSha256 = '22B6FC758FB36108486819259A3DF7C46381819F3B312E504BF979796FEE5D14'
$engineBytes = 36209152
$lockMod = Join-Path $repoRoot 'engine-build\go.mod'
$lockSum = Join-Path $repoRoot 'engine-build\go.sum'
$lockModSha = '2C335DF61E036819C4A0694E32748B4A3998C0FAF898FC05BCC7C0213C27BAF5'
$lockSumSha = 'C391D32564C5C66C7EB76FAE8595129E234784B03A0E4100ECB762BEEC9A103E'
# HTTP inbound, direct outbound, DoH and TLS record fragmentation are ordinary
# upstream features. Optional VPN, QUIC, SSH API, ACME and driver integrations
# are not enabled by feature tags. Linkname compatibility matches upstream.
$buildTags = 'with_purego,badlinkname,tfogo_checklinkname0'
$linkerFlags = '-X github.com/sagernet/sing-box/constant.Version=' + $engineVersion + ' -checklinkname=0 -s -w -buildid='

function Assert-LocalPath([string] $Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
        -not [String]::Equals($full, $repoRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Build path escaped the repository.' }
    if ($full.StartsWith('\\', [StringComparison]::Ordinal) -or $full.IndexOf(':', 2) -ge 0) { throw 'Build paths must be local.' }
    for ($current = $full; $current; $current = [IO.Path]::GetDirectoryName($current)) {
        try {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Build paths must not contain reparse points.' }
        } catch [IO.FileNotFoundException] { } catch [IO.DirectoryNotFoundException] { }
    }
}

function Fetch-Verified([string] $Url, [string] $Path, [string] $Sha) {
    Assert-LocalPath $Path
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Sha) { throw 'Downloaded source/toolchain archive did not match its pinned SHA-256.' }
}

function Assert-Locks([string] $ModPath, [string] $SumPath) {
    Assert-LocalPath $ModPath
    Assert-LocalPath $SumPath
    if (-not [IO.File]::Exists($ModPath) -or -not [IO.File]::Exists($SumPath) -or
        (Get-FileHash -LiteralPath $ModPath -Algorithm SHA256).Hash -ne $lockModSha -or
        (Get-FileHash -LiteralPath $SumPath -Algorithm SHA256).Hash -ne $lockSumSha) {
        throw 'Dependency lock bytes did not match the pinned build. No upgrades or rewritten locks are accepted.'
    }
}

function Expand-VerifiedZip([string] $ZipPath, [string] $Destination, [string] $Prefix, [long] $MaximumBytes) {
    Assert-LocalPath $Destination
    [void][IO.Directory]::CreateDirectory($Destination)
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        [long] $total = 0; $count = 0
        foreach ($entry in $archive.Entries) {
            if (++$count -gt 40000 -or $entry.Length -gt 268435456) { throw 'Source/toolchain archive size limit exceeded.' }
            $total += $entry.Length
            if ($total -gt $MaximumBytes) { throw 'Source/toolchain archive size limit exceeded.' }
            $name = $entry.FullName.Replace('\', '/')
            if (-not $name.StartsWith($Prefix, [StringComparison]::Ordinal) -or
                $name.Contains(':') -or $name.Contains([char]0) -or $name.StartsWith('/')) { throw 'Unexpected source/toolchain archive path.' }
            $relative = $name.Substring($Prefix.Length)
            if ($relative.Split('/') | Where-Object { $_ -eq '..' -or $_ -eq '.' }) { throw 'Archive traversal is forbidden.' }
            if ($relative.Length -eq 0) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $relative.Replace('/', '\')))
            if (-not $target.StartsWith($Destination.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive path escaped its extraction directory.' }
            Assert-LocalPath $target
            if ($name.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($target); continue }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            $inputStream = $entry.Open()
            try {
                $outputStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
            } finally { $inputStream.Dispose() }
        }
    } finally { $archive.Dispose() }
}

function Run-Go([string[]] $GoArguments) {
    & $script:goExe @GoArguments
    if ($LASTEXITCODE -ne 0) { throw ('Pinned Go command failed (exit ' + $LASTEXITCODE + '): ' + ($GoArguments -join ' ') + '. GOTOOLCHAIN=local; no automatic toolchain switch is permitted.') }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This reproducible target requires Windows x64.' }
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell to build the Windows amd64 engine.' }
Assert-Locks $lockMod $lockSum
Assert-LocalPath $workRoot
[void][IO.Directory]::CreateDirectory($workRoot)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $workRoot ('security-engine-build-' + [Guid]::NewGuid().ToString('N'))))
Assert-LocalPath $buildRoot
[void][IO.Directory]::CreateDirectory($buildRoot)
$sourceRoot = Join-Path $buildRoot 'source'
$goRoot = Join-Path $buildRoot 'go'
$artifactRoot = Join-Path $buildRoot 'artifacts'
[void][IO.Directory]::CreateDirectory($artifactRoot)
if ($OutFile) {
    $OutFile = if ([IO.Path]::IsPathRooted($OutFile)) { [IO.Path]::GetFullPath($OutFile) } else { [IO.Path]::GetFullPath((Join-Path $repoRoot $OutFile)) }
    Assert-LocalPath $OutFile
    if ([IO.Path]::GetFileName($OutFile) -ne 'sing-box.exe' -or
        (-not $OutFile.StartsWith($workRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
         $OutFile -ne (Join-Path $repoRoot 'engine\sing-box.exe'))) { throw '-OutFile must be engine\sing-box.exe or a sing-box.exe path under work.' }
    if ([IO.Directory]::Exists($OutFile)) { throw 'The output engine path is a directory; it was not changed.' }
    if ([IO.File]::Exists($OutFile) -and (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ne $engineSha256) {
        throw 'An existing output engine differs from the pinned build; it was not replaced.'
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$sourceZip = Join-Path $artifactRoot 'upstream-source.zip'
$goZip = Join-Path $buildRoot 'toolchain.zip'
Fetch-Verified $sourceUrl $sourceZip $sourceSha
Fetch-Verified $goUrl $goZip $goSha
Expand-VerifiedZip $sourceZip $sourceRoot ('sing-box-' + $sourceCommit + '/') 268435456
Expand-VerifiedZip $goZip $goRoot 'go/' 1073741824
$script:goExe = Join-Path $goRoot 'bin\go.exe'
Assert-LocalPath $script:goExe
if (-not [IO.File]::Exists($script:goExe)) { throw 'Pinned Go executable was not present in its verified archive.' }
$sourceMod = Join-Path $sourceRoot 'go.mod'; $sourceSum = Join-Path $sourceRoot 'go.sum'
[IO.File]::Copy($sourceMod, (Join-Path $artifactRoot 'upstream-go.mod'))
[IO.File]::Copy($sourceSum, (Join-Path $artifactRoot 'upstream-go.sum'))
[IO.File]::Copy($lockMod, $sourceMod, $true)
[IO.File]::Copy($lockSum, $sourceSum, $true)
Assert-Locks $sourceMod $sourceSum
$environmentNames = @('GOENV','GOAUTH','GOROOT','GOPATH','GOCACHE','GOMODCACHE','GOTOOLCHAIN','GOOS','GOARCH','GOAMD64','CGO_ENABLED','GOFLAGS','GOEXPERIMENT','GOWORK','GOPROXY','GOSUMDB','GONOSUMDB','GONOPROXY','GOPRIVATE','GOINSECURE','GOVCS','GODEBUG')
$savedEnvironment = @{}
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $buildEnvironment = @{
        GOENV='off'; GOAUTH='off'
        GOROOT=$goRoot; GOPATH=(Join-Path $buildRoot 'gopath'); GOCACHE=(Join-Path $buildRoot 'gocache'); GOMODCACHE=(Join-Path $buildRoot 'modules')
        GOTOOLCHAIN='local'; GOOS='windows'; GOARCH='amd64'; GOAMD64='v1'; CGO_ENABLED='0'; GOFLAGS=''; GOEXPERIMENT=''; GOWORK='off'
        GOPROXY='https://proxy.golang.org'; GOSUMDB='sum.golang.org'; GONOSUMDB=''; GONOPROXY=''; GOPRIVATE=''; GOINSECURE=''; GOVCS='*:off'; GODEBUG=''
    }
    foreach ($pair in $buildEnvironment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($pair.Key, $pair.Value, 'Process') }
    Push-Location -LiteralPath $sourceRoot
    try {
        $toolchain = (Run-Go @('version')) -join "`n"
        if ($toolchain.Trim() -ne ('go version ' + $goVersion + ' windows/amd64')) { throw 'The pinned toolchain identity did not match.' }
        Run-Go @('mod','download')
        Run-Go @('mod','verify')
        Assert-Locks $sourceMod $sourceSum
        $moduleLines = @(Run-Go @('list','-mod=readonly','-m','all'))
        $selectedModules = [ordered]@{}
        foreach ($line in $moduleLines) {
            $parts = $line -split '\s+'
            if ($parts.Length -ge 2) { $selectedModules[$parts[0]] = $parts[1] }
        }
        $moduleLines | Set-Content -LiteralPath (Join-Path $artifactRoot 'selected-modules.txt') -Encoding utf8
        $packageLines = @(Run-Go @('list','-mod=readonly',('-tags=' + $buildTags),'-deps','./cmd/sing-box'))
        $packageLines | Set-Content -LiteralPath (Join-Path $artifactRoot 'compiled-packages.txt') -Encoding utf8
        if ($packageLines | Where-Object { $_ -eq 'golang.org/x/crypto/openpgp' -or $_.StartsWith('golang.org/x/crypto/openpgp/') }) { throw 'The unmaintained OpenPGP package must not be compiled into this target.' }
        $enginePath = Join-Path $artifactRoot 'sing-box.exe'
        Run-Go @('build','-trimpath','-buildvcs=false','-mod=readonly',('-tags=' + $buildTags),('-ldflags=' + $linkerFlags),'-o',$enginePath,'./cmd/sing-box')
        Assert-Locks $sourceMod $sourceSum
        $engineSha = (Get-FileHash -LiteralPath $enginePath -Algorithm SHA256).Hash
        if ($engineSha -ne $engineSha256 -or ([IO.FileInfo]$enginePath).Length -ne $engineBytes) {
            throw 'Built engine did not match the pinned SHA-256 and size. It was not published or copied to -OutFile; build evidence remains under work for review.'
        }
        $buildInfo = @(Run-Go @('version','-m',$enginePath))
        # The executable's first line includes an output path; keep the public
        # report path independent while preserving all actual build fields.
        $buildInfo[0] = 'sing-box.exe: ' + $goVersion
        $buildInfo | Set-Content -LiteralPath (Join-Path $artifactRoot 'go-version-m.txt') -Encoding utf8
        [IO.File]::Copy($sourceMod, (Join-Path $artifactRoot 'go.mod'))
        [IO.File]::Copy($sourceSum, (Join-Path $artifactRoot 'go.sum'))
        [IO.File]::Copy($PSCommandPath, (Join-Path $artifactRoot 'Build-SecurityEngine.ps1'))
        [IO.Compression.ZipFile]::CreateFromDirectory($sourceRoot, (Join-Path $artifactRoot 'modified-source.zip'), [IO.Compression.CompressionLevel]::Optimal, $true)
        $metadata = [ordered]@{
            schema=1; engine_version=$engineVersion; engine_sha256=$engineSha; engine_bytes=([IO.FileInfo]$enginePath).Length
            go_version=$goVersion; go_archive_url=$goUrl; go_archive_sha256=$goSha
            main_source_commit=$sourceCommit; source_archive_url=$sourceUrl; source_archive_sha256=$sourceSha
            source_go_mod_sha256=(Get-FileHash -LiteralPath (Join-Path $artifactRoot 'upstream-go.mod') -Algorithm SHA256).Hash
            source_go_sum_sha256=(Get-FileHash -LiteralPath (Join-Path $artifactRoot 'upstream-go.sum') -Algorithm SHA256).Hash
            modified_go_mod_sha256=(Get-FileHash -LiteralPath $sourceMod -Algorithm SHA256).Hash
            modified_go_sum_sha256=(Get-FileHash -LiteralPath $sourceSum -Algorithm SHA256).Hash
            dependency_lock_mode='engine-build-byte-pinned'; lock_go_mod_sha256=$lockModSha; lock_go_sum_sha256=$lockSumSha
            modified_source_sha256=(Get-FileHash -LiteralPath (Join-Path $artifactRoot 'modified-source.zip') -Algorithm SHA256).Hash
            build_tags=$buildTags; linker_flags=$linkerFlags; build_settings=@{trimpath=$true; buildvcs=$false; GOOS='windows'; GOARCH='amd64'; GOAMD64='v1'; CGO_ENABLED='0'; GOTOOLCHAIN='local'}
            selected_modules=$selectedModules
            build_script_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
            engine_executed=$false; windows_settings_changed=$false
        }
        $metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifactRoot 'build-metadata.json') -Encoding utf8
        Get-ChildItem -LiteralPath $artifactRoot -File | Sort-Object Name | ForEach-Object {
            (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name
        } | Set-Content -LiteralPath (Join-Path $artifactRoot 'SHA256SUMS.txt') -Encoding ascii
        if ($OutFile) {
            Assert-LocalPath $OutFile
            if ([IO.File]::Exists($OutFile)) {
                if ((Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ne $engineSha) { throw 'An existing output engine differs; it was not replaced. The new build remains in artifacts.' }
            } else {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($OutFile))
                [IO.File]::Copy($enginePath, $OutFile)
            }
        }
        Write-Output ('Security engine built; SHA-256 ' + $engineSha + '. No engine was executed.')
        Write-Output ('Artifacts: ' + $artifactRoot)
    } finally { Pop-Location }
} finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
}
