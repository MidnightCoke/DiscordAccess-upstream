@echo off
setlocal
pushd "%~dp0..\.." || exit /b 1
if not exist work\launcher mkdir work\launcher
set "LauncherCompiler=%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
"%LauncherCompiler%" /nologo /target:exe /platform:x64 /optimize+ /out:work\launcher\FixtureApplication.exe tests\launcher\FixtureApplication.cs
if errorlevel 1 goto failed
"%LauncherCompiler%" /nologo /target:exe /platform:x64 /optimize+ /out:work\launcher\LauncherChecks.exe tests\launcher\LauncherChecks.cs
if errorlevel 1 goto failed
powershell.exe -NoLogo -NoProfile -Command "$ErrorActionPreference = 'Stop'; & '.\work\launcher\LauncherChecks.exe' $PWD.Path; exit $LASTEXITCODE"
set "LauncherTestResult=%errorlevel%"
popd
exit /b %LauncherTestResult%
:failed
popd
exit /b 1
