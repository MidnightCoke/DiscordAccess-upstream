@echo off
setlocal
pushd "%~dp0" || exit /b 1
if not exist work mkdir work
"%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe /platform:x64 /optimize+ /define:TEST_BUILD /main:DiscordAccess.TestRunner /out:work\DiscordAccess.Tests.exe /r:System.Web.Extensions.dll /resource:bridge\attachment-download.cjs,DiscordAccess.AttachmentDownloadHook src\*.cs tests\TestRunner.cs
if errorlevel 1 goto failed
work\DiscordAccess.Tests.exe > work\offline-test-results.txt 2>&1
set "DiscordAccessTestResult=%errorlevel%"
type work\offline-test-results.txt
popd
exit /b %DiscordAccessTestResult%
:failed
popd
exit /b 1
