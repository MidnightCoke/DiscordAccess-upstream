@echo off
setlocal
"%~dp0DiscordAccess.exe" %*
set "DiscordAccessResult=%errorlevel%"
if not "%DiscordAccessResult%"=="0" if not "%DiscordAccessResult%"=="130" (
    echo.
    echo DiscordAccess v4.16 baslatilamadi veya bir hata olustu. Yukaridaki aciklamayi kontrol edin.
    pause
)
exit /b %DiscordAccessResult%
