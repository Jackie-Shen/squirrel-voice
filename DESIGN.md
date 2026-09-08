# SquirrelVoice macOS 语音输入设计文档

> 基于 [Squirrel](https://github.com/rime/squirrel)（鼠须管）fork 的 macOS 原生语音输入法。
> 核心模块 **VoiceNative**：无 Python 后端、无 SSE，全本地管线 + 可选云端 LLM 清洗。
> 当前版本 1.2.1，arm64，要求 macOS 26（SpeechAnalyzer API）。
> 命名：软件名与仓库名（`squirrel-voice`）一致，为 **SquirrelVoice**；
> 用户数据目录 `~/.squirrelvoice/`（曾用名 VoiceSift / `~/.voicesift`，不自动迁移）。

---

## 1. 产品形态

- 一个 Rime 输入法（`im.rime.inputmethod.Squirrel`），保留拼音输入能力；
- 叠加语音输入：**按 `option+`` 开始说话，再按一次结束并定稿**（切换式，非按住；`cmd+`` 被系统「切换窗口」占用，勿用）；
- 转写结果进入 Squirrel 候选窗：实时预览 partial → final 定稿 → **Enter 提交 / Esc 丢弃**；
- 可选能力：
  - **说话人过滤**（本地离线）：只保留"我"说的话，剔除旁人插话；
  - **LLM 清洗**（云端可选）：口语 → 书面语润色。

## 2. 总体架构

```
┌──────────────────────────────────────────────────────────────────┐
│ Squirrel.app（Input Method Kit 输入法进程）                       │
│                                                                  │
│  SquirrelApplicationDelegate                                     │
│    └─ VoiceNativeCoordinator.start()   ← 官方代码仅 2 处感知      │
│         │                                                        │
│         ├─ 热键(输入法内部监听)  option+` 切换式 · 无需输入监控   │
│         ├─ VoiceNativeAudioSource   AVCaptureSession → 16kHz      │
│         ├─ TranscriptionSession     SpeechAnalyzer 流式 ASR       │
│         │    (vendored from TranscriberKit, macOS 26)            │
│         ├─ VoiceNativeSpeakerFilter FluidAudio 离线说话人过滤      │
│         └─ VoiceNativeLLMPolisher   可选云端 LLM 清洗             │
│                                                                  │
│  SquirrelInputController+VoiceNative  ← 事件路由到候选窗          │
└──────────────────────────────────────────────────────────────────┘
```

**隔离原则**：官方 Squirrel 代码不感知语音模块——delegate 只保留 `voiceNative` 属性 +
启动/退出两处调用，其余逻辑全部收敛在 VoiceNative* 文件里。删除这些文件即可还原上游。

## 3. 核心流程（切换式录音）

```
按下 option+`             录音中                  再按一次结束
   │                       │                        │
   ▼                       ▼                        ▼
beginRecording      AVCaptureSession 持续采集     endRecording
  ├ 校验当前输入法是 Squirrel    │                        ├ 尾部捕获：多采 400ms
  ├ 请求麦克风权限               ▼                        │   （防"啊/吧/呢"尾音截断）
  └ 请求语音识别权限      TranscriptionSession           ├ 看门狗（每秒检查）：
       │                  (SpeechAnalyzer zh-CN)        │   总等待>5s 且 3s 无事件
       ▼                       │                        │   → 判定卡死，强制定稿
 startSession                  ├ volatile → partial     └ .ended → processFinal
                               │    → 候选窗实时预览
                               └ final_ 段 → 累积 (text, start, end)
                                                          │
                                                          ▼
                                              processFinal（@MainActor）
                                               ├ 1. 拼接 final 段文本
                                               │     （空则回退 lastPartial，防空 final 藏窗）
                                               ├ 2. 说话人过滤（可选，离线）
                                               │     整段 16kHz → diarization →
                                               │     每段 embedding 与"我"声纹算余弦相似度
                                               │     ≥0.55 判本人 → 只保留本人转写段
                                               ├ 3. LLM 清洗（可选，云端）
                                               │     先刷"清洗中"到候选窗第 2 行，
                                               │     用户可提前 Enter 提交原文不必等
                                               └ 4. route(.final) → 候选窗定稿
                                                     Enter 提交 / Esc 丢弃
```

### 3.1 关键设计决策

| 问题 | 方案 |
|---|---|
| 结束录音后 ASR finalize 慢（实测 ~6s）偶尔真卡死 | **智能看门狗**：区分"慢但有事件"（继续等 .ended）与"事件停流"（>5s 且 idle>3s → 强制定稿）。旧版固定 5s 超时会在 finalize 慢时抢跑，只抓到半句 |
| 尾音截断（最后几个字丢失） | 结束录音后**多采 400ms** 再停采集：补全语气助词 + 给引擎收尾静音 |
| final 段为空（录音过短 / .ended 竞态） | 回退 `lastPartialText`，避免空 final 走 discard 把已显示的候选窗"一闪就没" |
| 进程重启后 IME 未激活，final 无处投递 | `pendingFinal` 缓存 30s，等下次 `activateServer` 投递 |
| LLM 往返期间用户已 Enter/Esc | `sessionStillActive()` 校验 voiceSessionId，会话已结束则跳过最终刷新，防止文本已提交面板又弹出 |
| 麦克风占用指示器不灭 | teardown 时**显式 stop()** AVCaptureSession（不能只置 nil：feedingTask 闭包强引用 audioSource，deinit 不触发） |
| 其他输入法下的误触发 | 热键改走输入法内部监听后天然只在 Squirrel 激活时生效；`beginRecording` 仍保留输入源前缀（`im.rime.inputmethod.Squirrel`）双保险 |
| `cmd+\`` 被系统「切换窗口」菜单占用、事件收不到 | 默认热键改为 `option+\``；设置窗口内提示勿用 `cmd+\``（`VoiceNativeSettingsWindow.swift` 中的 hotkeyHint 文案） |

## 4. 模块说明（sources/ 下 VoiceNative* / TK* 文件）

| 文件 | 职责 |
|---|---|
| `VoiceNativeCoordinator.swift` | 总协调：配置加载、热键回调、录音会话生命周期、看门狗、final 管线（过滤→清洗→路由）、事件路由 |
| `VoiceNativeTypes.swift` | `VoiceNativeConfig`（UserDefaults，key 前缀 `voice_native.`）、`VoiceNativeCredentials`（API key → `~/.squirrelvoice/credentials.yaml`，chmod 600）、`VoiceNativeEvent` |
| 热键监听（无独立文件） | 由 `SquirrelInputController` 的 `flagsChanged`/`keyDown` 捕获 → `matchesImeHotkey`/`imeHotkeyToggle` 切换录音；走输入法内部事件，**不用 CGEventTap、不需要「输入监控」权限**（默认 `option+\``，可配置） |
| `VoiceNativeHotkeyCombo.swift` | 热键串解析（如 `option+grave`），含 keyCode 映射 |
| `VoiceNativeAudioSource.swift` | AVCaptureSession 采集，输出 16kHz float（说话人过滤用旁路 `onFloat16k`） |
| `VoiceNativeSpeakerFilter.swift` | FluidAudio 离线说话人过滤：声纹注册/加载/作废、diarization、相似度判定 |
| `VoiceNativeLLMPolisher.swift` | 云端 LLM 清洗（OpenAI 兼容 chat/completions），带已提交文本上下文窗口 |
| `VoiceNativeSettingsWindow.swift` | 设置窗口：热键展示、说话人过滤开关 + 声纹注册/清除、LLM 开关/端点/模型/API key |
| `SquirrelInputController+VoiceNative.swift` | 输入控制器扩展：候选窗语音态（partial 预览 / final + 状态行）、Enter/Esc 处理 |
| `TKTranscriptionSession.swift` 等 TK* | vendored from [TranscriberKit](https://github.com/glebis/TranscriberKit)（MIT）：SpeechAnalyzer 流式转写会话、模型管理（AssetInventory 下载 zh-CN 语言包）、事件类型 |
| `SquirrelVoiceLog.swift` | 统一日志 → `~/.squirrelvoice/squirrel-voicenative.log` |

## 5. 说话人过滤（声纹）细节

- **模型**：CoreML 编译版，打包进 app（`resources/models/` → `Contents/Resources/`），本地加载、全程离线：
  - `pyannote_segmentation.mlmodelc` — 语音活动分段；
  - `wespeaker_v2.mlmodelc` — 说话人嵌入（256 维，L2 归一化）。
- **注册**：设置窗口录一段本人语音 → 走与过滤相同的 diarization 分段路径，取**最长段**的 embedding 作为"我"声纹 → 存 `~/.squirrelvoice/voiceprint_native.json`（带版本号）。
- **过滤**（结束录音后离线执行）：整段录音 `performCompleteDiarization` → 每个说话人段的 embedding 与"我"声纹算余弦相似度，**≥ 0.55 判本人**（本人通常 0.6~0.8，旁人 ≤ 0.5）→ 合并成"我的时间区间" → 协调器按 `audioTimeRange` 对齐转写段，只保留有重叠的段。
- **激进删旁人策略**：0 段本人且全段最高相似度 < 0.3 → 判定整段都是旁人，清空文本（不提交别人的声音）；0 段本人但 maxSim ≥ 0.3（拿不准）→ 保留全部原文，不冒险删用户自己的话。
- **声纹版本**：当前 v3。v1/v2 因采样率错误（48kHz 注册）或注册路径不一致（整段全 1 mask 被静音稀释）已作废——加载时版本不符自动删除并提示重录。

## 6. 配置与数据位置

| 内容 | 位置 | 说明 |
|---|---|---|
| 语音模块开关/热键/LLM 参数/过滤开关 | UserDefaults（`voice_native.*`） | 设置窗口读写，保存后 `reloadConfig()` 热生效 |
| LLM API key | `~/.squirrelvoice/credentials.yaml`（600） | `llm_api_key: <key>`；不进 UserDefaults / squirrel.yaml |
| 声纹 | `~/.squirrelvoice/voiceprint_native.json` | `{version, embedding[256]}`，版本不符自动作废 |
| 日志 | `~/.squirrelvoice/squirrel-voicenative.log` | 排查问题第一入口 |
| Rime 用户数据 | `~/Library/Rime/` | squirrel.yaml 等（上游机制） |

## 7. 权限清单

| 权限 | 用途 | 缺失时行为 |
|---|---|---|
| 麦克风 | 录音 | 候选窗提示"未授予麦克风权限" |
| 语音识别（Speech） | SpeechAnalyzer 转写 | 候选窗提示"未授予语音识别权限" |

自 1.2.x 起热键改走输入法内部事件监听，**不再需要「输入监控」（TCC ListenEvent）权限**，
普通账号即可自行授权。postinstall / 安装脚本仍会在 `/Applications`（或用户 `~/Applications`）
放一份副本，仅为历史遗留与系统权限列表展示一致（见 BUILD_AND_INSTALL.md）。

## 8. 构建依赖

| 依赖 | 来源 | 说明 |
|---|---|---|
| librime + 插件 | `librime/` 子模块（源码编译）或 `action-install.sh`（预构建下载） | 仓库不提交，clone 后需获取 |
| Sparkle.framework | `Frameworks/`（已提交）或 `make sparkle` 下载 | 自动更新框架 |
| FluidAudio | SPM 远程包（github.com/FluidInference/FluidAudio） | 说话人过滤；SPM 状态在 `build/SourcePackages/`（不提交，首次构建自动解析） |
| TranscriberKit | vendored（TK* 文件，已提交） | MIT |
| CoreML 声纹模型 | `resources/models/`（已提交，~14MB） | 不再从 Hugging Face 下载（国内网络常超时） |

## 9. 已知限制

- 仅 arm64（Apple Silicon）；universal 构建需 `ARCHS='arm64 x86_64' make package`；
- SpeechAnalyzer 要求 macOS 26+；
- 说话人过滤是结束录音后离线执行，会增加定稿延迟（整段 diarization，通常 1~3s）；
- LLM 清洗依赖网络与 API key，失败自动回退原文（候选窗状态行提示"清洗失败，已用原文"）。
