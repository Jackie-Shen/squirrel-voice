#!/bin/bash
# Squirrel（语音输入）安装脚本 —— 双击本文件即可安装，无需管理员权限。
#
# 双位置安装（与 pkg 方案同思路）：
#   • 输入法本体 → ~/Library/Input Methods/Squirrel.app（若 /Library/Input Methods 可写则优先用它）
#   • 授权用副本 → ~/Applications/Squirrel.app（若 /Applications 可写则优先用它）
#     macOS 26 上 ad-hoc/自签 app 要有这份"普通 app 位置"的副本，才会出现在「输入监控」权限列表。
set -e

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/Squirrel.app"
if [ ! -d "$src" ]; then
    echo "错误：没找到 Squirrel.app（应与本脚本在同一目录）。请重新挂载安装包。"
    read -r "按回车退出..."
    exit 1
fi

ime_root="$HOME/Library/Input Methods"
[ -w "/Library/Input Methods" ] && ime_root="/Library/Input Methods"
grant_dir="$HOME/Applications"
[ -w "/Applications" ] && grant_dir="/Applications"

dst="$ime_root/Squirrel.app"
grant="$grant_dir/Squirrel.app"
exec_bin="$dst/Contents/MacOS/Squirrel"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

echo "=== 安装 Squirrel 语音输入（用户目录，无需管理员）==="
echo "输入法本体：$dst"
echo "授权用副本：$grant"
echo

killall Squirrel 2>/dev/null || true
sleep 1

rm -rf "$dst"
mkdir -p "$ime_root"
cp -R "$src" "$dst"

# 授权用副本（路径与本体不同才需要复制）
if [ "$grant" != "$dst" ]; then
    mkdir -p "$grant_dir"
    rm -rf "$grant"
    cp -R "$dst" "$grant"
fi

"$exec_bin" --register-input-source
"$lsregister" -f "$dst" || true
"$lsregister" -f "$grant" || true

echo "预构建 Rime 词库（雾凇大词库，首次约需 1~3 分钟）..."
(cd "$dst/Contents/SharedSupport" && "$exec_bin" --build)

"$exec_bin" --enable-input-source
"$exec_bin" --select-input-source
open "$dst" 2>/dev/null || true

echo
echo "=== 安装完成 ==="
echo "还差手动授权（首次按热键时系统也会弹窗）："
echo "  1. 系统设置 → 隐私与安全性 → 麦克风     勾选 Squirrel"
echo "  2. 系统设置 → 隐私与安全性 → 语音识别   允许 Squirrel"
echo "用法：在任意输入框按 option+\` 开始说话，再按一次结束（无需输入监控权限）。"
echo "若输入法列表里找不到 Squirrel：注销一次再登录（脚本末尾可选）。"

# 输入法是登录后新装/新注册的，「系统设置 → 输入法 → +」列表要注销重登才会刷新。
printf "\n现在注销一次以刷新输入法列表吗？（会关闭所有应用，请先保存工作）[y/N] "
read -r ans
case "$ans" in
    y|Y|yes|YES)
        # 用户级注销，无需管理员；先延迟 3 秒让用户回到自己的工作界面
        osascript -e 'display notification "3 秒后注销，请确认工作已保存" with title "Squirrel 安装完成"' || true
        sleep 3
        osascript -e 'tell application "System Events" to log out'
        ;;
    *)
        echo "已跳过。手动注销：  → 退出登录…"
        read -r "按回车退出..."
        ;;
esac
