@echo off
setlocal
if not exist "%~dp0DiscordAccess.exe" (
    echo Bu klasor kaynak kodudur; DiscordAccess.exe bulunamadi.
    echo Hazir calisan ZIP paketini Releases sayfasindan indirin:
    echo https://github.com/alpertknn/DiscordAccess/releases/latest
    echo.
    echo Gelistirici olarak bu klasorde CMD acip sirayla calistirin:
    echo powershell -NoProfile -File scripts\Fetch-Engine.ps1
    echo Build.cmd
    pause
    exit /b 2
)
"%~dp0DiscordAccess.exe" %*
set "DiscordAccessResult=%errorlevel%"
if not "%DiscordAccessResult%"=="0" if not "%DiscordAccessResult%"=="130" (
    if not "%DiscordAccessResult%"=="64" if not exist "%~dp0engine\sing-box.exe" (
        echo Motor dosyasi engine\sing-box.exe bulunamadi.
        echo Tam hazir ZIP: https://github.com/alpertknn/DiscordAccess/releases/latest
        echo Kaynak koddan hazirlamak icin bu klasorde CMD acip sirayla:
        echo powershell -NoProfile -File scripts\Fetch-Engine.ps1
        echo Build.cmd
    )
    echo.
    echo DiscordAccess v4.16 baslatilamadi veya bir hata olustu. Yukaridaki aciklamayi kontrol edin.
    pause
)
exit /b %DiscordAccessResult%
