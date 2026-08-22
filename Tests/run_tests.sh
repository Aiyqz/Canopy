#!/bin/bash
# run_tests.sh — Canopy 回归测试一键运行脚本
#
# 背景：本机只有 CommandLineTools（无完整 Xcode），Swift Testing 框架虽存在于
#   /Library/Developer/CommandLineTools/Library/Developer/Frameworks/Testing.framework
# 但其内置 rpath 与实际安装路径不匹配，导致 swift test 运行时 dyld 找不到
#   Testing.framework 和 lib_TestingInterop.dylib。
#
# 本脚本在 .build/ 输出目录中创建指向这两个文件的 symlink，使 dyld 的相对路径
# 搜索能命中（CanopyPackageTests.xctest 的 rpath 包含 ../../../）。
#
# 用法： bash Tests/run_tests.sh

set -euo pipefail
cd "$(dirname "$0")/.."

FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
BUILD_DIR=.build/arm64-apple-macosx/debug

echo "==> Preparing Testing.framework runtime symlinks..."
mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR/Testing.framework" "$BUILD_DIR/lib_TestingInterop.dylib"
ln -s "$FW/Testing.framework" "$BUILD_DIR/Testing.framework"
ln -s "$LIB/lib_TestingInterop.dylib" "$BUILD_DIR/lib_TestingInterop.dylib"
echo "   done."

echo "==> Running swift test..."
swift test --disable-sandbox -Xswiftc -F -Xswiftc "$FW"
