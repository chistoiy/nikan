#!/usr/bin/env bash
# 一键构建。用法：
#   ./build_apk.sh             编 debug → build/app/outputs/flutter-apk/app-debug.apk
#   ./build_apk.sh release     编 release 分 ABI 包（基号自动递增）
#
# ⚠️ release 必须用 --split-per-abi：
#   `--target-platform android-arm,android-x64` 打的是**一个通用包**，而
#   build/app/outputs/flutter-apk/ 下会**残留上一版的 per-ABI 文件**——照名字拷就会
#   把旧版本包当成新的发出去（1.0.1 发版时真实踩到）。详见
#   docs/AI交接文档.md §3「发版 / 建 Release」。
set -e
cd "$(dirname "$0")"
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

if [ "${1:-debug}" != "release" ]; then
  flutter build apk --debug
  echo "APK 位置: $(pwd)/build/app/outputs/flutter-apk/app-debug.apk"
  exit 0
fi

# 基号自增。Flutter 会按 ABI 叠加 versionCode 偏移（arm32=+1000 / arm64=+2000 /
# x86_64=+4000），所以基号只要递增，三个包的 versionCode 就都高于上一版，
# 老机器升级不会被 INSTALL_FAILED_VERSION_DOWNGRADE 拒绝。
NUM_FILE=.build_number
BASE=$(cat "$NUM_FILE" 2>/dev/null | tr -dc '0-9')
[ -z "$BASE" ] && BASE=2040
BASE=$((BASE + 1))
echo "$BASE" > "$NUM_FILE"
echo "构建基号 = $BASE"

flutter build apk --release --split-per-abi --build-number "$BASE"

OUT=build/app/outputs/flutter-apk
cat <<EOF

产物（三个都要作为 Release 附件上传）：
  $OUT/app-arm64-v8a-release.apk     ← 绝大多数手机
  $OUT/app-armeabi-v7a-release.apk   ← 32 位老设备
  $OUT/app-x86_64-release.apk        ← 模拟器

上传前务必逐个核对版本（否则可能把旧包发出去）：
  aapt2 dump badging <apk> | grep -E '^package:|^native-code:'
EOF
