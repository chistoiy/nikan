@echo off
rem 一键编译 debug APK（双击运行）
set FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
cd /d %~dp0
flutter build apk --debug
echo.
echo APK 位置: %~dp0buildpp\outputslutter-apkpp-debug.apk
pause
