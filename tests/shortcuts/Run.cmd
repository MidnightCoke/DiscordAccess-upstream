@echo off
setlocal
pushd "%~dp0..\.." || exit /b 1
if not exist work\shortcuts mkdir work\shortcuts
"%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe /platform:x64 /optimize+ /out:work\shortcuts\FixtureChecks.exe /r:System.Web.Extensions.dll src\DiscordShortcuts.cs tests\shortcuts\FixtureChecks.cs
if errorlevel 1 goto failed
powershell.exe -NoLogo -NoProfile -Command "$ErrorActionPreference = 'Stop'; $fixtureRoot = [IO.Path]::GetFullPath((Join-Path $PWD ('work\shortcuts\fixtures-' + [Guid]::NewGuid().ToString('N')))); & '.\work\shortcuts\FixtureChecks.exe' $fixtureRoot; exit $LASTEXITCODE"
set "ShortcutTestResult=%errorlevel%"
popd
exit /b %ShortcutTestResult%
:failed
popd
exit /b 1
