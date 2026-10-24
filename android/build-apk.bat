@echo off
rem Gera o APK release do RTSPlayer: a biblioteca Rust (armv7 e arm64) e depois
rem o Gradle. Saida: app\build\outputs\apk\release\app-release.apk
rem
rem Precisa de: rustup targets armv7-linux-androideabi aarch64-linux-android,
rem cargo-ndk, o SDK do Android com NDK 27 e build-tools 34, e o JDK 17.
rem O SDK fica no lugar padrao (%LOCALAPPDATA%\Android\Sdk); outro caminho vai
rem em ANDROID_SDK. A assinatura vem de keystore.properties (fora do git).
setlocal
if "%ANDROID_SDK%"=="" set "ANDROID_SDK=%LOCALAPPDATA%\Android\Sdk"
if "%JAVA_HOME%"=="" set "JAVA_HOME=C:\Program Files\Eclipse Adoptium\jdk-17.0.9.9-hotspot"
set "ANDROID_HOME=%ANDROID_SDK%"
set "ANDROID_NDK_HOME=%ANDROID_SDK%\ndk\27.2.12479018"
cd /d "%~dp0"
echo sdk.dir=%ANDROID_SDK:\=/%> local.properties
if not exist keystore.properties echo AVISO: sem keystore.properties, o APK release sai sem assinatura.
cargo ndk -t armeabi-v7a -t arm64-v8a -P 28 -o app\src\main\jniLibs build --release -p rtsplayer-android || exit /b 1
call "%~dp0gradlew.bat" -p "%~dp0." assembleRelease || exit /b 1
echo.
echo APK: %~dp0app\build\outputs\apk\release\app-release.apk
