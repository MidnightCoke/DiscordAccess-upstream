#Requires -Version 7.0
# CI-only: validate the exact generated runtime policies with the pinned engine.
# sing-box check constructs and closes the options; it never calls Start or
# PreStart. These policies contain no file logging, cache, TUN or system proxy.
# Verified in cmd/sing-box/cmd_check.go and the HTTP/DoH constructors at pinned
# upstream source commit 7054cac5124465ffdb145870d7c01885566711b1.
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
    -not [Environment]::Is64BitProcess) { throw 'Engine configuration smoke tests run only in GitHub Actions Windows x64. No local test executable was started.' }

$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$workRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'work'))
$fixtureRoot = Join-Path $workRoot ('engine-config-' + [Guid]::NewGuid().ToString('N'))
$configRoot = Join-Path $fixtureRoot 'configs'
$exporter = Join-Path $fixtureRoot 'EngineConfigExport.exe'
$engine = Join-Path $repoRoot 'engine\sing-box.exe'
$report = Join-Path $workRoot 'engine-config-results.txt'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

function Assert-RepositoryPath([string] $Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
        -not [String]::Equals($full, $repoRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Smoke fixture path escaped the repository.' }
    if ($full.StartsWith('\\', [StringComparison]::Ordinal) -or $full.IndexOf(':', 2) -ge 0) { throw 'Smoke fixture paths must be local.' }
    for ($current = $full; $current; $current = [IO.Path]::GetDirectoryName($current)) {
        try {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Smoke fixture paths must not contain reparse points.' }
        } catch [IO.FileNotFoundException] { } catch [IO.DirectoryNotFoundException] { }
    }
}

function Run-Bounded([string] $Executable, [string[]] $Arguments, [int] $Seconds, [string] $Label) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.WorkingDirectory = $fixtureRoot
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw ($Label + ': process did not start.') }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($Seconds * 1000)) {
            # Only this fixture child is terminated. No running Discord,
            # helper instance or unrelated process is enumerated or touched.
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(2000)
            throw ($Label + ': bounded configuration check timed out.')
        }
        $output = $stdout.GetAwaiter().GetResult(); $errors = $stderr.GetAwaiter().GetResult()
        if ($output.Trim()) { Add-Content -LiteralPath $report -Value $output.Trim() -Encoding utf8 }
        if ($errors.Trim()) { Add-Content -LiteralPath $report -Value $errors.Trim() -Encoding utf8 }
        if ($process.ExitCode -ne 0) { throw ($Label + ': exit code ' + $process.ExitCode + '.') }
    } finally { $process.Dispose() }
}

Assert-RepositoryPath $workRoot
[void][IO.Directory]::CreateDirectory($workRoot)
Assert-RepositoryPath $fixtureRoot
[void][IO.Directory]::CreateDirectory($fixtureRoot)
Assert-RepositoryPath $report
Set-Content -LiteralPath $report -Value 'Generated engine configuration smoke test: 6 DNS variants, synthetic credentials; check only, no engine run.' -Encoding utf8
$engineLease = $null
try {
    if (-not [IO.File]::Exists($compiler)) { throw '.NET Framework x64 compiler not found.' }
    Assert-RepositoryPath $engine
    Assert-RepositoryPath $exporter
    Assert-RepositoryPath $configRoot
    $source = Get-Content -LiteralPath (Join-Path $repoRoot 'src\DiscordAccess.cs') -Raw
    $hashMatch = [regex]::Match($source, 'internal const string EngineSha256 = "([0-9a-fA-F]{64})";')
    # Keep the verified image closed to write/delete sharing throughout every
    # checker invocation, matching the runtime's package-image lease.
    $engineLease = [IO.File]::Open($engine, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    Assert-RepositoryPath $engine
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $engineHash = [BitConverter]::ToString($sha.ComputeHash($engineLease)).Replace('-', '') } finally { $sha.Dispose() }
    if (-not $hashMatch.Success -or $engineHash -ne $hashMatch.Groups[1].Value) {
        throw 'Engine did not match the runtime SHA-256 pin; it was not executed.'
    }
    $compileArguments = @('/nologo','/target:exe','/platform:x64','/optimize+','/define:TEST_BUILD','/main:DiscordAccess.EngineConfigExport',
        ('/out:' + $exporter),'/r:System.Web.Extensions.dll','/r:System.Windows.Forms.dll','/r:System.Drawing.dll',
        ('/resource:' + (Join-Path $repoRoot 'bridge\attachment-download.cjs') + ',DiscordAccess.AttachmentDownloadHook'))
    $compileArguments += @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'src') -Filter '*.cs' -File | Sort-Object Name | ForEach-Object { $_.FullName })
    $compileArguments += (Join-Path $repoRoot 'tests\EngineConfigExport.cs')
    Run-Bounded $compiler $compileArguments 60 'Fixture compilation'
    Run-Bounded $exporter @($repoRoot, $configRoot) 60 'Configuration export'
    $variants = @('cloudflare-plain','cloudflare-fragment','cloudflare-ip-plain','cloudflare-ip-fragment','google-plain','google-fragment')
    if (@(Get-ChildItem -LiteralPath $configRoot -File).Count -ne $variants.Count) { throw 'Exporter produced an unexpected configuration set.' }
    foreach ($variant in $variants) {
        $config = Join-Path $configRoot ($variant + '.json')
        Assert-RepositoryPath $config
        # Explicit -c avoids any ambient config.json/config directory. The
        # native checker is never invoked with run, daemon or service options.
        Run-Bounded $engine @('check','-c',$config) 10 ('Engine check ' + $variant)
        Add-Content -LiteralPath $report -Value ($variant + ': PASS') -Encoding utf8
    }
    Add-Content -LiteralPath $report -Value 'PASS: pinned engine accepted all 6 generated policies without starting listeners or sending a request.' -Encoding utf8
} catch {
    Add-Content -LiteralPath $report -Value ('FAIL: ' + $_.Exception.Message) -Encoding utf8
    throw
} finally {
    if ($null -ne $engineLease) { $engineLease.Dispose() }
    Get-Content -LiteralPath $report
}
