#!/bin/bash
# Squirrel（语音输入）卸载脚本 —— 双击本文件即可卸载。
# 用户目录安装（~/Library/Input Methods + ~/Applications）不需要管理员权限；
# 只有存在 /Library、/Applications 下的系统级副本时才会请求授权（可跳过）。
set -e

ime_root_user="$HOME/Library/Input Methods"
ime_root_sys="/Library/Input Methods"
exec_user="$ime_root_user/Squirrel.app/Contents/MacOS/Squirrel"
exec_sys="$ime_root_sys/Squirrel.app/Contents/MacOS/Squirrel"
lsregister="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

echo "=== 卸载 Squirrel 语音输入 ==="

ask() {
    printf "%s [y/N] " "$1"
    read -r ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

clean_squirrelvoice=no
clean_rime=no
ask "一并删除 ~/.squirrelvoice（声纹、API key、日志）？" && clean_squirrelvoice=yes
ask "一并删除 ~/Library/Rime（词库与配置）？（若还用其他鼠须管系输入法请选 no）" && clean_rime=yes

# 先停用输入源（任选一个还活着的本体）
if [ -x "$exec_user" ]; then
    "$exec_user" --disable-input-source 2>/dev/null || true
elif [ -x "$exec_sys" ]; then
    "$exec_sys" --disable-input-source 2>/dev/null || true
fi
killall Squirrel 2>/dev/null || true
sleep 1

# 用户级位置：无需管理员，直接删
rm -rf "$ime_root_user/Squirrel.app" "$HOME/Applications/Squirrel.app" "$HOME/Applications/Squirrel-Uninstaller.app"

# 系统级位置：存在才处理
if [ -d "$ime_root_sys/Squirrel.app" ] || [ -d "/Applications/Squirrel.app" ] || [ -d "/Applications/Squirrel-Uninstaller.app" ]; then
    if ask "检测到 /Library、/Applications 下还有系统级安装（pkg 方式），需要管理员密码，现在删除？"; then
        sudo /bin/bash <<'EOF'
set -e
killall Squirrel 2>/dev/null || true
rm -rf "/Library/Input Methods/Squirrel.app" /Applications/Squirrel.app /Applications/Squirrel-Uninstaller.app
EOF
    else
        echo "已跳过系统级副本（之后可让管理员运行本脚本再删）。"
    fi
fi

"$lsregister" -f "$HOME/Applications" 2>/dev/null || true
"$lsregister" -f "$ime_root_user" 2>/dev/null || true

[ "$clean_squirrelvoice" = yes ] && rm -rf "$HOME/.squirrelvoice"
[ "$clean_rime" = yes ] && rm -rf "$HOME/Library/Rime"

# 清掉本用户下 Squirrel 的权限授权记录（麦克风/语音识别/输入监控），重装后会重新弹窗
tccutil reset Microphone im.rime.inputmethod.Squirrel 2>/dev/null || true
tccutil reset SpeechRecognition im.rime.inputmethod.Squirrel 2>/dev/null || true
tccutil reset ListenEvent im.rime.inputmethod.Squirrel 2>/dev/null || true

echo
echo "=== 卸载完成 ==="
echo "  • 若输入法列表仍有残留：系统设置 → 键盘 → 输入法，点「-」移除"
printf "  • 现在注销一次以刷新输入法/权限列表吗？（会关闭所有应用，请先保存工作）[y/N] "
read -r ans
case "$ans" in
    y|Y|yes|YES)
        osascript -e 'display notification "3 秒后注销，请确认工作已保存" with title "Squirrel 卸载完成"' || true
        sleep 3
        osascript -e 'tell application "System Events" to log out'
        ;;
    *)
        echo "已跳过。建议稍后手动注销一次。"
        read -r "按回车退出..."
        ;;
esac
