#!/usr/bin/env bash
# 一键编译 debug APK：./build_apk.sh
set -e
cd "$(dirname "$0")"
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter build apk --debug
echo "APK 位置: $(pwd)/build/app/outputs/flutter-apk/app-debug.apk"
