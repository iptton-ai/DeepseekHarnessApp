#!/usr/bin/env bash
# OHOS 依赖切换:通过仓库根 pubspec_overrides.yaml(gitignored)的存在与否,
# 决定 mobile_scanner 走 pub.dev 原版(默认,Android/iOS/桌面)还是 gitcode
# OHOS fork。fork 的 android Kotlin 源编译必炸,故不能用 pubspec.yaml 常驻 override。
# 用法:
#   ./tool/ohos_deps.sh on      # OHOS 构建前启用:cp 模板 → flutter pub get
#   ./tool/ohos_deps.sh off     # 构建后还原:删文件 → flutter pub get
#   ./tool/ohos_deps.sh status  # 查看当前模式
set -euo pipefail
cd "$(dirname "$0")/.."

OVERRIDES=pubspec_overrides.yaml
TEMPLATE=tool/pubspec_overrides.ohos.yaml

case "${1:-status}" in
  on)
    cp "$TEMPLATE" "$OVERRIDES"
    flutter pub get
    echo "[ohos_deps] OHOS 模式已启用(${OVERRIDES} 已生成,勿提交)。"
    echo "[ohos_deps] 构建完成后记得还原:./tool/ohos_deps.sh off"
    ;;
  off)
    rm -f "$OVERRIDES"
    flutter pub get
    echo "[ohos_deps] 已还原默认依赖(mobile_scanner=pub.dev 原版)。"
    echo "[ohos_deps] 若 git status 显示 pubspec.lock 有残留改动,请复查后再提交。"
    ;;
  status)
    if [[ -f "$OVERRIDES" ]]; then
      echo "OHOS 模式:开启(mobile_scanner=gitcode fork;Android/iOS 构建会炸)"
    else
      echo "OHOS 模式:关闭(mobile_scanner=pub.dev,适用 Android/iOS/桌面)"
    fi
    ;;
  *)
    echo "用法: $0 on|off|status" >&2
    exit 2
    ;;
esac
