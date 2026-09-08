# SquirrelVoice（Squirrel）构建 / 打包 / 安装 / 卸载指南

> 适用版本 1.2.1。环境要求：**macOS 26 + Apple Silicon (arm64) + Xcode 26+**。
> 源码目录：`squirrel-voice/`（下文命令均在该目录下执行）。
> 产物名为 **SquirrelVoice-<版本>.dmg**（软件曾用名 VoiceSift，用户数据目录现为 `~/.squirrelvoice/`）。

---

## 1. 仓库内容与首次准备

| 内容 | 是否在 git 里 | 说明 |
|---|---|---|
| 全部源码 / 工程 / 脚本 | ✅ | — |
| CoreML 声纹模型 `resources/models/`（~14MB） | ✅ | 本地加载，无需下载 |
| 预构建依赖 `lib/` `bin/` `Frameworks/` `data/plum/` `data/opencc/`（~30MB） | ✅ | 避免每次重新下载 |
| 雾凇词库 `data/rime-ice/`（~56MB） | ✅ | 由 `package/add_rime_ice` 在构建后 rsync 进 bundle |
| `build/`（构建产物，~1.5GB） | ❌ | 本地生成 |
| `librime/`（源码 + 其构建，~190MB） | ❌ | 需获取（见下） |
| `releases/SquirrelVoice-*.dmg`（DMG 分发包） / `package/Squirrel*.pkg`（打包产物） | ❌ | `make dmg` 统一输出到根目录 `releases/`；走 GitHub Releases 分发，勿提交 |

**新机器 clone 后首次准备**（二选一）：

```bash
# 方式 A：下载预构建 rime 产物（快，需能访问 GitHub）
bash action-install.sh

# 方式 B：从源码编译 librime（慢，~10min+，需 CMake/clang）
git submodule update --init librime   # 或手动 clone 到 librime/
make deps
```

SPM 依赖（FluidAudio）首次 `xcodebuild` 时自动解析，无需手动处理。

## 2. 构建

```bash
make debug     # Debug 版 → build/Build/Products/Debug/Squirrel.app
make release   # Release 版 → build/Build/Products/Release/Squirrel.app
```

- `make release` 会自动先检查依赖（librime 库 / plum 词库 / opencc 数据 / Sparkle），缺失则触发对应构建；
- 雾凇词库（rime-ice，48MB：全拼/双拼方案 + base/ext/腾讯大词库 + lua 滤镜）放在
  `data/rime-ice/`，`make release/debug` 构建后由 `package/add_rime_ice` rsync 进
  SharedSupport（保留 cn_dicts/lua 等子目录，Xcode Copy 阶段只支持平铺文件）；
  默认方案为 `rime_ice`，首次部署编译大词库约 1~3 分钟；
- 版本号在 `Squirrel.xcodeproj/project.pbxproj` 的 `CURRENT_PROJECT_VERSION`（当前 1.2.1）；
- 出 universal 包（含 Intel）：`ARCHS='arm64 x86_64' make package`。

## 3. 打包（生成 .pkg）

```bash
make release
# 清理 Products/Release 里的 SPM 中间产物（静态库/.o/头文件，~58MB），
# 否则会被 pkgbuild 一起打进安装包：
cd build/Build/Products/Release && ls | grep -v '^Squirrel.app$' | xargs rm -rf && cd -
bash package/make_package build
# → package/Squirrel.pkg（约 32MB）
```

> 注意：不要直接 `make package`——它会先跑 `release` 重新生成中间产物。
> 正确顺序是 **release → 清理 → make_package**。

pkg 结构（两个组件，安装界面「自定义安装」里可见/可勾选）：

| 组件 | 安装位置 | 说明 |
|---|---|---|
| Squirrel 输入法 | `/Library/Input Methods/` | 必装项；内嵌 postinstall 脚本（以 root 运行） |
| Squirrel-Uninstaller.app | `/Applications/` | 可选（默认勾选）；双击即可卸载，见第 5 节 |

卸载器由 `package/make_uninstaller` 生成（纯 shell + osascript GUI，无需编译）。

### 打包为 DMG（含 安装.command / 卸载.command 双脚本）

```sh
make release   # 若未构建
cd build/Build/Products/Release && ls | grep -v '^Squirrel.app$' | xargs rm -rf && cd -
bash package/make_dmg build        # 或 make dmg
# → releases/SquirrelVoice-<版本号>.dmg
```

DMG 挂载后内容：`Squirrel.app`、`安装.command`、`重装.command`、`卸载.command`、`说明.txt`。
用户双击脚本即在终端运行，**全程不需要管理员权限**，不依赖 pkg 安装向导：

- `安装.command`：双位置复制到用户目录（本体 `~/Library/Input Methods/Squirrel.app`、
  应用副本 `~/Applications/Squirrel.app`；若系统目录恰好可写则自动优先系统目录）
  → 注册输入源 → 预构建词库 → 启用并选中输入源；
- `卸载.command`：停用输入源 → 删除用户级副本；检测到 /Library、/Applications 下的
  pkg 版副本时可选择 sudo 删除（没有管理员也能跳过，只删用户级）→ 可选清理
  `~/.squirrelvoice` / `~/Library/Rime` → `tccutil reset` 三项授权记录。

> 分发给他人时 .command 会带 quarantine，说明.txt 里已写「右键 → 打开」的绕过方法。

## 4. 安装

### 方式 A：pkg 安装包

双击 `Squirrel.pkg` 走安装向导。postinstall 自动完成：

1. 停掉正在运行的 Squirrel；
2. TIS 注册输入源 + Rime 数据预构建（`RIME_NO_PREBUILD=1` 可跳过）；
3. **拷贝一份到 `/Applications/Squirrel.app`**（历史遗留：旧版全局热键需要它出现在「输入监控」列表；现版本热键已改走输入法内部监听，保留仅为权限列表展示一致）；
4. LaunchServices 双位置注册（`lsregister -f`）；
5. 以登录用户身份启用并选中 Squirrel 输入源。

**安装后授权**：自 1.2.x 起，Squirrel 启动约 1 秒后会**主动弹出**麦克风、语音识别的
系统授权框。若错过弹窗，仍可手动去 系统设置 → 隐私与安全性：

| 权限 | 页面 |
|---|---|
| 麦克风 | 麦克风 → 勾选 Squirrel |
| 语音识别 | 语音识别 → 允许 |

热键（默认 option+\`；`cmd+\`` 被系统「切换窗口」占用、收不到事件，勿用）由输入法内部监听：
在任意输入框**按一次开始说话、再按一次结束**，不需要「输入监控」权限（该权限开关需 Touch ID / 管理员认证，普通用户给不了）。

### 方式 B：开发安装（make install-debug）

```bash
make install-debug
# = make debug + 权限检查 + 覆盖 /Library/Input Methods/Squirrel.app + postinstall（跳过 Rime 预构建）
```

改代码后重复执行即可热替换；声纹/配置在 `~/.squirrelvoice/`，不受影响。

### 方式 C：干净系统 DMG 安装测试清单

拿一台没装过的 macOS 26 (arm64) 机器，按此流程验收：

1. 拷贝 `SquirrelVoice-<版本>.dmg` 过去；双击挂载。
   （若经下载/网盘传输带 quarantine：右键 安装.command → 打开；或 `xattr -dr com.apple.quarantine /Volumes/...`）
2. 双击 `安装.command`（全程无管理员密码），等词库预构建完成，按提示可选注销一次
   （输入法「+」列表要重登才刷新）。
3. 重新登录后：系统设置 → 键盘 → 输入法 →「+」添加 **鼠须管 - 简体中文**。
4. 首次触发语音会弹 麦克风 / 语音识别 授权框，允许即可（无「输入监控」要求）。
5. 输入法基本功能：打字出候选；`` ` `` 直接输出 `` ` ``、`\` 直接输出 `、`（不弹候选窗）。
6. 语音主流程：焦点在输入框 → 按 `option+\`` → 面板立即出现
   「聆听中 / 录音中（按 option+\` 结束）」→ 说话出实时字 →
   再按热键 / Enter / 空格 / 1 / 2 / 点第 2 行 → 结束录音，第 2 行「正在定稿」→
   定稿出文字 → Enter/1 提交上屏。
7. 开了声纹过滤 / LLM 清洗时：第 2 行依次显示「正在定稿 → 已过滤旁人 / 清洗中 → 清洗完成」，
   清洗期间按 Enter 可提前提交原文。
8. 卸载验收：双击 `卸载.command`，确认两处 app、输入源、（可选）用户数据全部清除。

## 5. 卸载

### 方式 A：卸载器（推荐）

安装 pkg 时默认会装上 **`/Applications/Squirrel-Uninstaller.app`**（安装界面「自定义安装」里可取消勾选）。
双击运行：

1. 弹出确认框，列出将删除的文件，可勾选是否一并清理 `~/.squirrelvoice`（声纹/API key/日志）和 `~/Library/Rime`（词库配置）；
2. 点「继续卸载」→ 一次管理员授权 → 自动删除两个位置的 Squirrel.app + 卸载器自身 + 刷新 LaunchServices；
3. 完成框提示后续事项（输入源残留移除、注销重启、权限列表清理）。

### 方式 B：DMG 里的 卸载.command

用第 3 节的 DMG（或重新挂载）双击 `卸载.command`，按提示确认；同样能删掉 pkg 方式装的
全部文件，可选择是否一并清理 `~/.squirrelvoice` 与 `~/Library/Rime`。

### 方式 C：手动卸载

```bash
# 1. 移除输入源：系统设置 → 键盘 → 输入法 → 编辑 → 选中 Squirrel → 点「-」
# 2. 删除应用（两个位置都要删）：
sudo rm -rf "/Library/Input Methods/Squirrel.app"
rm -rf /Applications/Squirrel.app
rm -rf /Applications/Squirrel-Uninstaller.app

# 3.（可选）清除用户数据：
rm -rf ~/.squirrelvoice/        # 声纹、LLM API key、日志
rm -rf ~/Library/Rime/      # Rime 用户配置与词库（若不再用鼠须管系输入法）

# 4.（可选）系统设置 → 隐私与安全性：从 麦克风 / 语音识别 列表中移除 Squirrel
```

## 6. 排查问题

| 症状 | 处理 |
|---|---|
| 热键无反应 | ① 当前输入法必须是 Squirrel 且焦点在文本输入框（热键走输入法内部监听，切到别的输入法/焦点不在输入框时收不到）；② 麦克风/语音识别权限是否已给；③ 看日志 |
| 松手后没出文字 / 卡住 | 看 `~/.squirrelvoice/squirrel-voicenative.log`（每次录音都有 beginRecording/endRecording/看门狗/processFinal 全链路日志） |
| 提示"未检测到你的声音" | 声纹与现场差异大；设置窗口里**重新注册声纹**（安静环境、说 10s+） |
| 声纹突然失效要重录 | 正常：声纹带版本号，升级后旧版自动作废（v3 为当前版） |
| LLM 清洗失败 | 状态行显示"清洗失败，已用原文"；检查 `~/.squirrelvoice/credentials.yaml` 的 key 与网络 |
| 麦克风占用指示器不灭 | 已知修复点：teardown 显式 stop 采集会话；若复现看日志里 teardownSession 是否执行 |
| 新机器构建失败（SPM 路径错误） | 删掉 `build/SourcePackages/` 重新解析，或修正 workspace-state.json 里的绝对路径 |

## 7. 目录速查

```
squirrel-voice/              # 源码仓库（Squirrel fork + 语音模块）
├── DESIGN.md                  # 设计文档
├── BUILD_AND_INSTALL.md       # 本文档
├── sources/                   # Swift 源码（VoiceNative* 为语音模块）
├── resources/models/          # CoreML 声纹模型（已提交）
├── lib/ bin/ Frameworks/      # 预构建依赖（已提交）
├── data/plum|opencc/          # Rime 词库数据（已提交）
├── scripts/postinstall        # pkg 安装后脚本
├── package/make_package       # 打包脚本（输入法 + 卸载器两个组件）→ package/Squirrel.pkg
├── package/make_dmg           # 生成 DMG → releases/SquirrelVoice-<版本>.dmg
│                              #   （卷内含 Squirrel.app + 安装/重装/卸载 三个 .command + 说明.txt）
├── package/make_uninstaller   # 生成 Squirrel-Uninstaller.app
└── build/                     # 构建产物（git 忽略）
```
