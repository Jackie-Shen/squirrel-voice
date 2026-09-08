#!/bin/bash
# Squirrel（语音输入）重装脚本 —— 升级 / 覆盖安装用。
#
# 只替换 app 本体，以下内容全部保留：
#   • 设置界面配置（热键、LLM 端点/模型/提示词、麦克风选择、说话人过滤开关）→ UserDefaults
#   • 声纹、API key、日志 → ~/.squirrelvoice
#   • 用户词库 / 打字习惯 → ~/Library/Rime（--build 只重编译词库，不动 userdb）
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

new_ver=$(plutil -extract CFBundleVersion raw "$src/Contents/Info.plist" 2>/dev/null || echo "?")
cur_ver=""
[ -d "$dst" ] && cur_ver=$(plutil -extract CFBundleVersion raw "$dst/Contents/Info.plist" 2>/dev/null || echo "?")
echo "=== 重装 Squirrel 语音输入 ==="
echo "当前已装版本：${cur_ver:-无} → 本次安装：$new_ver"
echo "配置、声纹、用户词库都会保留。"
echo

killall Squirrel 2>/dev/null || true
sleep 1

rm -rf "$dst"
mkdir -p "$ime_root"
cp -R "$src" "$dst"
if [ "$grant" != "$dst" ]; then
    mkdir -p "$grant_dir"
    rm -rf "$grant"
    cp -R "$dst" "$grant"
fi

"$exec_bin" --register-input-source
"$lsregister" -f "$dst" || true
"$lsregister" -f "$grant" || true

# 重编译词库（雾凇大词库首次约 1~3 分钟；已有缓存时很快）
echo "重编译 Rime 词库（用户词库保留）..."
(cd "$dst/Contents/SharedSupport" && "$exec_bin" --build) 2>/dev/null || true

"$exec_bin" --enable-input-source
"$exec_bin" --select-input-source
open "$dst" 2>/dev/null || true

echo
echo "=== 重装完成（v$new_ver）==="
echo "设置窗口里的热键 / LLM / 麦克风选择、已注册声纹、打字习惯词库均不受影响。"
printf "输入法列表或版本显示异常时，注销一次即可刷新。现在注销吗？（会关闭所有应用）[y/N] "
read -r ans
case "$ans" in
    y|Y|yes|YES)
        osascript -e 'display notification "3 秒后注销，请确认工作已保存" with title "Squirrel 重装完成"' || true
        sleep 3
        osascript -e 'tell application "System Events" to log out'
        ;;
    *)
        read -r "按回车退出..."
        ;;
esac
