# SquirrelVoice —— 带 macOS 原生语音输入的鼠须管

[![Download](https://img.shields.io/github/v/release/Jackie-Shen/squirrel-voice)](https://github.com/Jackie-Shen/squirrel-voice/releases/latest)
[![Build Status](https://github.com/Jackie-Shen/squirrel-voice/actions/workflows/commit-ci.yml/badge.svg)](https://github.com/Jackie-Shen/squirrel-voice/actions/workflows)

**SquirrelVoice** 是 [rime/squirrel（鼠须管）](https://github.com/rime/squirrel) 的 fork：
在完整的 Rime 拼音输入能力之上，叠加了一个 **纯原生、无后端进程** 的 macOS 语音输入模块
（代码中称 **VoiceNative**）。按一次热键开始说话、再按一次结束定稿，转写结果直接进
Squirrel 候选窗，可选择叠加「离线声纹过滤」和「云端 LLM 书面化清洗」。

- **一个 App 两种用法**：正常拼音输入照常工作；语音输入是叠加层，删掉 `VoiceNative*` /
  `TK*` 源码即可还原上游。
- **全本地语音管线**：AVCaptureSession 采集 → SpeechAnalyzer 流式转写（zh-CN），
  不依赖 Python 后端、不依赖 SSE，也 **不需要「输入监控」权限**。
- **可选声纹过滤**：FluidAudio + CoreML 模型（已打包进 app），离线识别"哪些话是我说的"，
  剔除旁人插话。
- **可选 LLM 清洗**：任意 OpenAI 兼容端点，把口语润色成书面语；失败自动回退原文。

## 环境要求

| 项目 | 要求 | 原因 |
|---|---|---|
| macOS | **26+** | SpeechAnalyzer API |
| 硬件 | **Apple Silicon (arm64)** | 预构建依赖与模型均按 arm64 分发 |
| 构建 | Xcode 26+（仅开发者需要） | — |

> App 内部 bundle 标识仍为 `im.rime.inputmethod.Squirrel`（输入法必须沿用 Squirrel 标识）；
> 面向用户的分发名、配置与日志目录统一为 **SquirrelVoice**（`~/.squirrelvoice/`）。

## 快速开始（普通用户）

1. 到 [Releases](https://github.com/Jackie-Shen/squirrel-voice/releases/latest) 下载
   `SquirrelVoice-<版本>.dmg`，双击挂载；
2. 双击卷内 **`安装.command`**（若提示被隔离：右键 → 打开）。全程 **不需要管理员密码**，
   等待词库预构建完成，按提示可注销一次以刷新输入法列表；
3. 系统设置 → 键盘 → 输入法 →「+」添加 **鼠须管 - 简体中文**；
4. 首次触发语音时按提示授予 **麦克风** 和 **语音识别** 两项权限（约 1 秒后会自动弹授权框）。

## 使用语音输入

**默认热键 `option+\``**（可配置；注意 `cmd+\`` 被系统「切换窗口」占用，勿用）：

```
焦点放到任意输入框 → 切到 Squirrel →
按 option+`  开始说话（候选窗显示"聆听中/录音中"+ 实时转写预览）
再按 option+`  结束 → 自动定稿 →
Enter / 空格  提交上屏        Esc  丢弃
```

结束后的定稿管线（第 2 行状态可见）：`正在定稿 → [已过滤旁人] → [清洗中 → 清洗完成]`。
LLM 清洗期间不必等待，按 Enter 可立即提交原文。

**设置**：点输入法菜单（🌐/ㄓ）→ **Settings...** 打开 SquirrelVoice 设置窗口，可配置：

| 功能 | 默认 | 说明 |
|---|---|---|
| 语音输入开关 | 开 | 总开关 |
| 热键 | `option+\`` | 自定义组合键（解析见 `VoiceNativeHotkeyCombo.swift`） |
| 说话人过滤 | 关 | 需在设置窗口先 **注册声纹**（安静环境录 10s+）；声纹带版本号，升级后需重录属正常 |
| LLM 清洗 | 关 | 填 OpenAI 兼容的 base URL / model / prompt；API key 单独存 `~/.squirrelvoice/credentials.yaml`（600 权限），不进 UserDefaults |

### 配置与数据位置

| 内容 | 位置 |
|---|---|
| 语音模块配置（开关/热键/LLM/过滤） | UserDefaults，key 前缀 `voice_native.` |
| LLM API key | `~/.squirrelvoice/credentials.yaml` |
| 声纹 | `~/.squirrelvoice/voiceprint_native.json` |
| 日志（**排查问题第一入口**） | `~/.squirrelvoice/squirrel-voicenative.log` |
| Rime 用户配置与词库 | `~/Library/Rime/`（上游机制） |

## 开发者指南

完整流程（首次准备、构建、pkg/DMG 打包、开发安装、干净系统验收、卸载、排障）见
**[BUILD_AND_INSTALL.md](BUILD_AND_INSTALL.md)**；架构与关键设计决策见 **[DESIGN.md](DESIGN.md)**。

常用命令：

```bash
bash action-install.sh   # 首次准备：下载预构建 librime 产物（或 make deps 源码编译）
make debug               # Debug 构建 → build/Build/Products/Debug/Squirrel.app
make release             # Release 构建（自动检查依赖）
make install-debug       # 开发热替换：构建 + 覆盖到 /Library/Input Methods
make dmg                 # 打包 → releases/SquirrelVoice-<版本>.dmg（分发包统一输出根目录 releases/）
```

仓库布局要点：

```
squirrel-voice/
├── sources/                # Swift 源码；VoiceNative* / TK* 为语音模块，其余为上游 Squirrel
│   ├── VoiceNativeCoordinator.swift      # 语音模块总协调
│   ├── SquirrelInputController+VoiceNative.swift  # 事件路由到候选窗
│   └── TKTranscriptionSession.swift 等   # vendored TranscriberKit（SpeechAnalyzer 封装，MIT）
├── resources/models/       # CoreML 声纹模型（已提交，离线加载）
├── lib/ bin/ Frameworks/   # 预构建依赖（已提交，免重复下载）
├── data/                   # plum / opencc 数据 + rime-ice 雾凇词库（已提交）
├── package/                # 打包脚本：make_package / make_dmg / make_uninstaller
├── scripts/postinstall     # pkg 安装后脚本
├── DESIGN.md / BUILD_AND_INSTALL.md / CHANGELOG.md
└── build/                  # 构建产物（git 忽略）
```

说明：

- 默认方案为 `rime_ice`（雾凇拼音），随包分发；`` Ctrl+` `` 或 `F4` 呼出方案菜单切换其他方案；
- `librime/`、`plum/`、`Sparkle/` 不随仓库提交，新机器按 BUILD_AND_INSTALL.md 第 1 节获取；
- 官方上游代码刻意保持最小侵入：delegate 仅 2 处感知语音模块，便于持续跟随上游。

## 常见问题（速查）

| 症状 | 处理 |
|---|---|
| 热键无反应 | 当前输入法必须是 Squirrel 且焦点在文本框；检查麦克风/语音识别权限；看日志 |
| 松手后不出文字 | 看 `~/.squirrelvoice/squirrel-voicenative.log`（有全链路日志与看门狗记录） |
| 提示"未检测到你的声音" | 到设置窗口重新注册声纹 |
| LLM 清洗失败 | 状态行显示"清洗失败，已用原文"；检查 credentials.yaml 与网络 |

更多见 BUILD_AND_INSTALL.md 第 6 节。

## 已知限制

- 仅 arm64；SpeechAnalyzer 要求 macOS 26+；
- 声纹过滤在结束录音后离线执行，会增加约 1~3s 定稿延迟；
- LLM 清洗依赖网络与 API key。

## 许可证与致谢

- 本项目基于上游 **鼠须管 Squirrel**（[rime/squirrel](https://rime.im)，GPL v3，见 `LICENSE.txt`），
  语法引擎由 [中州韵 librime](https://rime.im) 驱动；输入法菜单、词库定制、plum 方案生态均沿用上游。
- 语音转写封装 vendored 自 [TranscriberKit](https://github.com/glebis/TranscriberKit)（MIT）；
  说话人分段/嵌入使用 [FluidAudio](https://github.com/FluidInference/FluidAudio)（pyannote 分段 +
  WeSpeaker v2 嵌入的 CoreML 版）；自动更新使用 Sparkle。
- 上游鸣谢（程序、美术、依赖库、反馈渠道等）见 [rime/squirrel](https://github.com/rime/squirrel) README。
