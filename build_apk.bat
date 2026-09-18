@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
rem 一键构建。用法：
rem   build_apk.bat            编 debug
rem   build_apk.bat release    编 release 分 ABI 包（基号自动递增）
rem
rem release 必须用 --split-per-abi：--target-platform 打的是一个通用包，而 build 目录下
rem 会残留上一版的 per-ABI 文件，照名字拷会把旧包当成新的发出去。
rem 详见 docs\AI交接文档.md 的「发版 / 建 Release」一节。
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
cd /d %~dp0

if /i not "%~1"=="release" goto debug

set NUM_FILE=%~dp0.build_number
set BASE=2040
if exist "%NUM_FILE%" set /p BASE=<"%NUM_FILE%"
set /a BASE=BASE+1
> "%NUM_FILE%" echo !BASE!
echo 构建基号 = !BASE!

flutter build apk --release --split-per-abi --build-number !BASE!
if errorlevel 1 goto fail

echo.
echo 产物（三个都要作为 Release 附件上传）:
echo   %~dp0build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
echo   %~dp0build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk
echo   %~dp0build\app\outputs\flutter-apk\app-x86_64-release.apk
echo.
echo 上传前务必逐个核对版本（否则可能把旧包发出去）:
echo   aapt2 dump badging ^<apk^> ^| findstr /b "package: native-code:"
pause
exit /b 0

:debug
flutter build apk --debug
if errorlevel 1 goto fail
echo.
echo APK 位置: %~dp0build\app\outputs\flutter-apk\app-debug.apk
pause
exit /b 0

:fail
echo.
echo 构建失败，未产出 APK。
pause
exit /b 1
