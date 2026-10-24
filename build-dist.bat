@echo off
rem Gera os pacotes de distribuicao, uma pasta por plataforma, cada uma com
rem tudo o que precisa:
rem   dist\windows-servidor\  vmsserver.exe + DLLs do FFmpeg e do ONNX + modelo
rem   dist\windows-cliente\   rtsplayer.exe (precisa so do WebView2 Runtime,
rem                           que ja vem no Windows 10/11 atualizado)
rem   dist\android\           RTSPlayer.apk (Android 9+, armv7 e arm64)
rem
rem O Android precisa do que o android\build-apk.bat pede. Para pular:
rem   build-dist.bat sem-android
setlocal
cd /d "%~dp0"
cargo build --release -p vmsserver -p rtsplayer || exit /b 1
if /i not "%~1"=="sem-android" (
    call "%~dp0android\build-apk.bat" || exit /b 1
)
if exist dist rmdir /s /q dist
mkdir dist\windows-servidor dist\windows-cliente || exit /b 1
copy /y target\release\vmsserver.exe dist\windows-servidor\ >nul || exit /b 1
copy /y server\runtime\* dist\windows-servidor\ >nul || exit /b 1
copy /y target\release\rtsplayer.exe dist\windows-cliente\ >nul || exit /b 1
if /i not "%~1"=="sem-android" (
    mkdir dist\android
    copy /y android\app\build\outputs\apk\release\app-release.apk dist\android\RTSPlayer.apk >nul || exit /b 1
)
echo.
echo Pacotes em %~dp0dist
dir /s /b dist
