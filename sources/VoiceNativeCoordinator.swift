//
//  VoiceNativeCoordinator.swift
//  Squirrel (SquirrelVoice fork)
//
//  macOS 原生语音输入协调器（全本地管线，无 Python 后端；替代早期版本的
//  「后端进程 + SSE 转写」路径，那段历史见 CHANGELOG 1.1.x 之前的 VoiceSift 时期）。
//
//  职责：
//  - 读配置（UserDefaults + credentials.yaml），创建并持有各组件；
//  - 热键（默认 option+`）走 IME 内「切换模式」：在 SquirrelInputController.handle()
//    里匹配按键 → 按一次 beginRecording、再按一次 endRecording。
//    不用 CGEventTap，因此不需要「输入监控」权限（该权限开关需管理员认证）。
//  - 录音中：VoiceNativeAudioSource(AVCaptureSession) → TranscriptionSession(SpeechAnalyzer，
//    vendored from TranscriberKit) 流式转写 → partial 实时预览到候选窗；
//  - 松手后：定稿 → (可选)FluidAudio 说话人过滤 → (可选)云端 LLM 清洗 → final 到候选窗；
//  - 事件路由到激活的输入控制器（SquirrelInputController+VoiceNative）。
//
//  官方 Squirrel 代码不感知本模块：delegate 只保留 voiceNative 属性 +
//  启动/退出两处调用，其余逻辑全部收敛在这里。
//

import AppKit
import AVFoundation
import Foundation
import InputMethodKit
import Speech

final class VoiceNativeCoordinator {
  private let speakerFilter = VoiceNativeSpeakerFilter()
  private var llmPolisher: VoiceNativeLLMPolisher?

  private weak var delegate: SquirrelApplicationDelegate?
  private var config: VoiceNativeConfig
  private var sessionID = ""
  private var isRecording = false
  /// 已按下结束（松手/再按一次）→ 候选窗第 2 行从"录音中"提示切为"正在定稿"。
  private var hasReleased = false
  /// 防 .ended 回调与超时兜底重复定稿。
  private var finalInFlight = false
  /// 最后一次 partial 文本：final 段为空时（过短/竞态）回退用它，防空 final 把候选窗藏掉。
  private var lastPartialText = ""
  /// 最近一次收到转写事件（partial/final/ended）的时刻。看门狗用它区分
  /// 「analyzer 还在正常 finalize（慢但持续出事件）」和「真卡死（事件停流）」。
  private var lastEventTime = Date.distantPast
  /// 本次松手（endRecording）时刻，看门狗据此算总等待时长。
  private var endRecordingTime = Date.distantPast
  /// 待投递的 final 结果：无激活输入控制器时（如进程刚重启、客户端尚未重新激活 IME），
  /// 缓存 final，等下次 activateServer（用户点进输入框）投递；30s 过期。
  private var pendingFinal: (text: String, status: String?, at: Date)?

  // 会话组件
  private var audioSource: VoiceNativeAudioSource?
  private var transcriberSession: TranscriptionSession?
  private var eventTask: Task<Void, Never>?

  // 累积的 final 段（text + start + end），供说话人过滤时间戳对齐。
  private let segQueue = DispatchQueue(label: "voicenative.seg")
  private var finalSegments: [(text: String, start: Double, end: Double)] = []

  // 16kHz 累积（说话人过滤用）。
  private let audioQueue = DispatchQueue(label: "voicenative.audio")
  private var accumulated16k: [Float] = []

  /// 读配置并启动；enabled=false 时返回 nil。
  static func start(delegate: SquirrelApplicationDelegate) -> VoiceNativeCoordinator? {
    let cfg = VoiceNativeConfig.load()
    guard cfg.enabled else {
      SquirrelVoiceLog.write("voice_native.enabled=false，原生语音输入已禁用")
      return nil
    }
    let coordinator = VoiceNativeCoordinator(delegate: delegate, config: cfg)
    coordinator.start()
    return coordinator
  }

  private init(delegate: SquirrelApplicationDelegate, config: VoiceNativeConfig) {
    self.delegate = delegate
    self.config = config
  }

  /// 解析配置里的热键串；失败回退 option+grave。
  static func parseHotkey(_ raw: String) -> VoiceNativeHotkeyCombo {
    let (combo, err) = VoiceNativeHotkeyCombo.parse(raw)
    if let combo { return combo }
    if let err { SquirrelVoiceLog.write("热键配置无效（\(err)），回退 option+grave") }
    return VoiceNativeHotkeyCombo(modifiers: .maskAlternate, keyCode: 50, display: "option+grave")
  }

  func start() {
    speakerFilter.loadVoiceprint()
    if config.llmEnabled, !config.llmBaseUrl.isEmpty, !config.llmModel.isEmpty,
       let key = VoiceNativeCredentials.loadKey(), !key.isEmpty {
      llmPolisher = VoiceNativeLLMPolisher(baseURL: config.llmBaseUrl, model: config.llmModel, apiKey: key, systemPrompt: config.llmPrompt)
      SquirrelVoiceLog.write("VoiceNative LLM 清洗启用：model=\(config.llmModel)")
    } else if config.llmEnabled {
      SquirrelVoiceLog.write("VoiceNative LLM enabled 但配置/key 缺失，降级为不清洗")
    }
    prewarmPermissions()
    SquirrelVoiceLog.write("VoiceNative 协调器已启动（hotkey=\(config.hotkey) 切换模式 speakerFilter=\(config.speakerFilterEnabled)）")
  }

  /// 启动时主动触发 麦克风 / 语音识别 的系统授权弹窗。
  /// 否则这两个弹窗要等用户第一次按热键（且输入监控已授权、热键生效）才出现，
  /// 从用户视角看就是"权限弹窗很晚才来"。输入法无 UI 前台，弹窗可能被压在其他窗口后，
  /// 故延迟 1s 等系统稳定后请求，并在被拒时给出引导面板。
  private func prewarmPermissions() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self else { return }
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        SquirrelVoiceLog.write("prewarm 麦克风权限：\(granted ? "已授权" : "未授权")")
        if !granted {
          DispatchQueue.main.async { self.showPermissionNeededAlert(kind: .microphone) }
        }
      }
      SFSpeechRecognizer.requestAuthorization { status in
        SquirrelVoiceLog.write("prewarm 语音识别权限：\(status.rawValue)")
        if status != .authorized {
          DispatchQueue.main.async { self.showPermissionNeededAlert(kind: .speech) }
        }
      }
    }
  }

  func stop() {
    if isRecording { teardownSession() }
  }

  /// 设置窗口保存后调用：重新加载配置（热键 + LLM 开关/端点/模型 + 说话人过滤开关）。
  func reloadConfig() {
    let newCfg = VoiceNativeConfig.load()
    self.config = newCfg
    speakerFilter.loadVoiceprint()
    // 热键改动即时生效：matchesImeHotkey 每次按配置解析，无需重建监听。

    // LLM polisher 按需重建
    if newCfg.llmEnabled, !newCfg.llmBaseUrl.isEmpty, !newCfg.llmModel.isEmpty,
       let key = VoiceNativeCredentials.loadKey(), !key.isEmpty {
      llmPolisher = VoiceNativeLLMPolisher(baseURL: newCfg.llmBaseUrl, model: newCfg.llmModel, apiKey: key, systemPrompt: newCfg.llmPrompt)
      SquirrelVoiceLog.write("VoiceNative 配置已重载（LLM 启用）")
    } else {
      llmPolisher = nil
      SquirrelVoiceLog.write("VoiceNative 配置已重载（LLM 禁用）")
    }
  }

  fileprivate enum PermissionKind {
    case microphone, speech
  }

  /// 缺权限时的引导弹窗（同类权限每次启动最多弹一次）。
  private func showPermissionNeededAlert(kind: PermissionKind) {
    let alert = NSAlert()
    switch kind {
    case .microphone:
      alert.messageText = "需要「麦克风」权限"
      alert.informativeText = """
      语音输入需要麦克风权限。

      请打开：系统设置 → 隐私与安全性 → 麦克风，勾选「鼠须管 / Squirrel」。
      """
    case .speech:
      alert.messageText = "需要「语音识别」权限"
      alert.informativeText = """
      语音输入需要语音识别权限。

      请打开：系统设置 → 隐私与安全性 → 语音识别，允许「鼠须管 / Squirrel」。
      """
    }
    alert.addButton(withTitle: "打开系统设置")
    alert.addButton(withTitle: "稍后")
    let anchorURL: String
    switch kind {
    case .microphone: anchorURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    case .speech: anchorURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
    }
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: anchorURL) {
      NSWorkspace.shared.open(url)
    }
  }

  /// 用户提交语音文本后记录进 LLM 上下文窗口。
  func reportCommit(text: String) {
    llmPolisher?.addCommitted(text)
  }

  /// Enter/空格/数字 1、2 / 点候选行 → 提前结束录音（等价再按一次热键）。
  /// 之后的定稿、声纹过滤、LLM 清洗照常进行；已在定稿中则忽略。
  func stopRecordingEarly() {
    guard isRecording, !hasReleased else { return }
    SquirrelVoiceLog.write("stopRecordingEarly（用户选择候选/确认键）")
    endRecording()
  }

  // MARK: - 热键（IME 内切换模式，不需要输入监控权限）

  /// 热键触发方式：SquirrelInputController.handle() 收到 keyDown 后询问是否命中
  /// 配置组合；命中则切换录音状态（按一次开始、再按一次结束）。
  /// 只在 Squirrel 激活的输入框里有效，不依赖 CGEventTap，也就不需要
  /// 「输入监控」权限（该权限开关需 Touch ID / 管理员认证）。

  /// 录音中候选窗第 2 行提示文案（含热键显示名，如 "录音中（按 option+` 结束）"）。
  var recordingHint: String { "录音中（按 \(Self.parseHotkey(config.hotkey).display) 结束）" }

  /// 该按键事件是否命中配置的热键组合（keyCode + 修饰键完全一致）。
  func matchesImeHotkey(_ event: NSEvent) -> Bool {
    let combo = Self.parseHotkey(config.hotkey)
    guard event.keyCode == UInt16(truncatingIfNeeded: combo.keyCode) else { return false }
    let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    return event.modifierFlags.intersection(relevant) == combo.nsModifierFlags.intersection(relevant)
  }

  /// IME 侧热键按下：切换录音状态（未在录 → 开始；在录 → 结束）。
  func imeHotkeyToggle() {
    if isRecording {
      guard !finalInFlight else { return }   // 已在定稿中，忽略
      SquirrelVoiceLog.write("imeHotkeyToggle → 结束录音（切换模式）")
      endRecording()
    } else {
      SquirrelVoiceLog.write("imeHotkeyToggle → 开始录音（切换模式）")
      beginRecording()
    }
  }

  /// activateServer 时调用：投递暂存的 final 结果（进程重启后首次激活）。
  func inputControllerDidActivate(_ ic: SquirrelInputController) {
    guard let pending = pendingFinal else { return }
    pendingFinal = nil
    if Date().timeIntervalSince(pending.at) > 30 {
      SquirrelVoiceLog.write("暂存 final 已过期（>30s），丢弃")
      return
    }
    SquirrelVoiceLog.write("投递暂存 final 到新激活的输入控制器")
    ic.voiceShowCandidate(pending.text, sessionId: sessionID, isFinal: true, status: pending.status, confidence: nil)
  }

  // MARK: - 录音会话

  private func beginRecording() {
    guard !isRecording else { return }
    // 双保险：热键本就在 SquirrelInputController.handle() 里拦截（只有 Squirrel 激活
    // 才会收到事件），这里再确认当前输入法是 Squirrel，防止其他输入法下的边缘情况。
    let currentID = SquirrelInstaller.currentInputSourceID() ?? ""
    guard currentID.hasPrefix("im.rime.inputmethod.Squirrel") else {
      SquirrelVoiceLog.write("beginRecording 忽略：当前输入法非 Squirrel（\(currentID)）")
      return
    }
    SquirrelVoiceLog.write("beginRecording")
    // 录音开始：关掉可能残留的候选窗（如误触 ` 弹出的符号分组菜单），并清掉 Rime 残留组合。
    route(.start)
    sessionID = UUID().uuidString
    isRecording = true
    hasReleased = false
    lastPartialText = ""
    pendingFinal = nil   // 新录音使旧暂存结果失效
    segQueue.sync { finalSegments = [] }
    audioQueue.sync { accumulated16k = [] }
    // 重置看门狗计时：避免残留的旧看门狗用上一会话的 endRecordingTime/lastEventTime 误判。
    lastEventTime = Date()
    endRecordingTime = Date.distantPast

    AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
      guard let self else { return }
      if !granted {
        SquirrelVoiceLog.write("麦克风权限被拒")
        // route 里有 UI 操作，必须主线程（回调在后台线程）。
        DispatchQueue.main.async {
          self.route(.final(text: "", status: "未授予麦克风权限"))
          self.teardownSession()
        }
        return
      }
      SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async {
          if status != .authorized {
            SquirrelVoiceLog.write("语音识别权限状态：\(status.rawValue)")
            self.route(.final(text: "", status: "未授予语音识别权限"))
            self.teardownSession()
            return
          }
          self.startSession()
        }
      }
    }
  }

  private func startSession() {
    let source = VoiceNativeAudioSource(deviceUID: config.audioDeviceUID)
    self.audioSource = source
    if config.speakerFilterEnabled {
      source.onFloat16k = { [weak self] f in
        guard let self else { return }
        self.audioQueue.async { self.accumulated16k.append(contentsOf: f) }
      }
    }

    let options = TranscriptionOptions(
      locale: Locale(identifier: "zh-CN"),
      enableDiarization: false,   // diarization 由 VoiceNativeSpeakerFilter 单独做（需 embedding）
      maxSpeakers: 10,
      enableVolatileResults: true
    )
    let session = TranscriptionSession(source: source, options: options)
    self.transcriberSession = session

    eventTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let events = await session.start()
      for await event in events {
        // 看门狗判据：任何转写事件（含 volatile/final/ended）都说明 analyzer 还在产出，
        // 松手后 finalize 期间 partial 会持续进来 → 不算卡死，继续等真正的 .ended。
        self.lastEventTime = Date()
        switch event {
        case .volatile(let r):
          if !r.text.isEmpty { self.lastPartialText = r.text }
          self.route(.partial(text: r.text, confidence: nil))
        case .final_(let r):
          self.segQueue.sync {
            self.finalSegments.append((text: r.text, start: r.startTime, end: r.endTime))
          }
          // 用已定稿全文刷新预览
          let full = self.segQueue.sync { self.finalSegments.map { $0.text }.joined() }
          if !full.isEmpty { self.lastPartialText = full }
          self.route(.partial(text: full, confidence: nil))
        case .diarization:
          break
        case .ended(let reason):
          SquirrelVoiceLog.write("转写会话结束：\(reason)")
          await self.processFinal()
        }
      }
    }
  }

  private func endRecording() {
    guard isRecording else { return }
    SquirrelVoiceLog.write("endRecording")
    hasReleased = true
    // 刷新面板第 2 行：录音中提示 → 正在定稿（此时可能还没有新 partial 进来）。
    if !lastPartialText.isEmpty {
      route(.partial(text: lastPartialText, confidence: nil))
    }
    // 尾部捕获：松手后别立刻停采集。语气助词（啊/吧/呢/吗）短、能量低，常落在松手后
    // 那几百毫秒里；立刻 stopRunning 会把这段尾音截断 → ASR 拿不到 → 最后几个字丢失。
    // 多采 400ms：补全尾音 + 给一点收尾静音让引擎有把握定稿最后一个词。期间 isRecording
    // 仍为 true，重复按热键会被 beginRecording 的 guard 挡住，不会开新会话。
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
      Task { [weak self] in
        await self?.transcriberSession?.stop()
      }
    }
    // 智能兜底（看门狗）：松手后 analyzer finalize 可能慢（实测 ~6s，期间 partial 持续进来），
    // 但偶尔会真卡死（事件停流、.ended 永不来）。区分两者：
    //   - 慢但有进展（最近 3s 内还有转写事件）→ 继续等真正的 .ended，拿到完整定稿；
    //   - 真卡死（已等 >5s 且最近 3s 无任何事件）→ 强制定稿，防 isRecording 永久卡死。
    // 旧版固定 5s 超时会在 finalize 慢时抢跑定稿 → 只抓到半句 + 清洗提前启动（用户反馈的 bug）。
    endRecordingTime = Date()
    scheduleFinalWatchdog()
  }

  /// 每秒检查一次：会话是否已结束 / 是否真卡死。主线程执行（与事件循环同 actor，无竞态）。
  private func scheduleFinalWatchdog() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
      guard let self, self.isRecording else { return }   // 已定稿/新会话 → 停止看门狗
      let totalWait = Date().timeIntervalSince(self.endRecordingTime)
      let idle = Date().timeIntervalSince(self.lastEventTime)
      if totalWait > 5, idle > 3 {
        SquirrelVoiceLog.write("endRecording 看门狗：已等 \(String(format: "%.1f", totalWait))s 且 \(String(format: "%.1f", idle))s 无事件 → 判定卡死，强制定稿")
        Task { @MainActor in await self.processFinal() }
      } else {
        // 仍在正常 finalize（慢但有事件）→ 继续等
        SquirrelVoiceLog.write("endRecording 看门狗：等待中（已等 \(String(format: "%.1f", totalWait))s，idle \(String(format: "%.1f", idle))s）")
        self.scheduleFinalWatchdog()
      }
    }
  }

  /// 松手后：取定稿段 → (可选)说话人过滤 → (可选)LLM 清洗 → final 到候选窗。
  /// @MainActor：route() 里有 NSWindow/面板操作，必须主线程；
  /// 非隔离 async 会在 await（LLM 清洗）挂起恢复后跳到后台线程 → SIGTRAP 崩溃。
  @MainActor
  private func processFinal() async {
    guard !finalInFlight else { return }
    finalInFlight = true
    let segments = segQueue.sync { finalSegments }
    let samples: [Float] = audioQueue.sync { accumulated16k }

    var text = segments.filter { !$0.text.isEmpty }.map { $0.text }.joined()
    SquirrelVoiceLog.write("processFinal 段数=\(segments.count) finalText=\"\(text.prefix(50))\" lastPartial=\"\(lastPartialText.prefix(50))\"")
    if text.isEmpty {
      // final 段为空（录音过短 / .ended 与最后 final_ 竞态）：回退最后 partial，
      // 否则空 final 会走 voiceDiscard 把已显示的候选窗藏掉（"一闪就没"）。
      text = lastPartialText
      SquirrelVoiceLog.write("processFinal final 段为空 → 回退 lastPartial")
    }
    var status: String? = nil

    // 说话人过滤（松手后离线）
    if config.speakerFilterEnabled, speakerFilter.hasVoiceprint, !samples.isEmpty {
      if let result = await speakerFilter.myTimeRanges(fromAudio16k: samples) {
        if !result.myRanges.isEmpty {
          // 有本人区间 → 只保留本人段（旁人段被剔除）
          let filtered = Self.filterSegments(segments, by: result.myRanges)
          let fText = filtered.filter { !$0.text.isEmpty }.map { $0.text }.joined()
          if !fText.isEmpty {
            text = fText
            status = "已过滤旁人"
          } else {
            status = "未检测到本人语音"
          }
        } else if result.maxSimilarity < VoiceNativeSpeakerFilter.notMeFloor {
          // 方案 A（激进删旁人）：0 段本人且全段最高 sim < 0.3（明显不是你）
          // → 判定整段都是旁人，清空文本（不提交别人声音）。text="" 会走 voiceDiscard 关窗。
          text = ""
          status = "已过滤旁人（未检测到你的声音）"
          SquirrelVoiceLog.write("processFinal 说话人过滤：全段非本人（maxSim=\(String(format: "%.3f", result.maxSimilarity)) < \(VoiceNativeSpeakerFilter.notMeFloor)）→ 清空")
        }
        // 0 段本人但 maxSim ≥ 0.3（拿不准，可能是你没被匹配上）→ 保留全部原文，不冒险删你说的话。
      }
    }

    // LLM 清洗（可选）
    if let polisher = llmPolisher, !text.isEmpty {
      // 有激活输入控制器才做两阶段刷新：先刷"清洗中"到第 2 行，让用户知道在处理、
      // 可提前 Enter 提交原文不必等。无 IC 时跳过中间态，直接走末尾 route（会缓存
      // 清洗后的文本到 pendingFinal），避免把"清洗中"的原文缓存进去。
      let hadIC = (delegate?.activeInputController ?? delegate?.panel?.inputController) != nil
      if hadIC {
        route(.final(text: text, status: "清洗中"))
      }
      do {
        let cleaned = try await polisher.clean(text)
        if !cleaned.isEmpty { text = cleaned; status = "清洗完成" }
      } catch {
        SquirrelVoiceLog.write("LLM 清洗失败，回退原文：\(error.localizedDescription)")
        status = "清洗失败，已用原文"
      }
      // 守卫：曾显示"清洗中"（hadIC）时，LLM 往返期间用户可能已 Enter 提交原文 /
      // Esc 丢弃（resetVoiceState 清空 voiceSessionId）。此时不能再刷面板，否则文本
      // 已提交、面板却又弹出来。无 IC（hadIC=false）不拦截，让末尾 route 正常缓存。
      if hadIC, !sessionStillActive() {
        SquirrelVoiceLog.write("LLM 完成但会话已结束（用户已提交/丢弃），跳过最终刷新")
        teardownSession()
        return
      }
    }

    route(.final(text: text, status: status))
    teardownSession()
  }

  /// 该语音会话是否仍"活着"：输入控制器存在且其 voiceSessionId 仍是当前 sessionID。
  /// 用户在 LLM 往返期间提交/丢弃会 resetVoiceState 清空 voiceSessionId → 返回 false。
  private func sessionStillActive() -> Bool {
    guard let ic = delegate?.activeInputController ?? delegate?.panel?.inputController else { return false }
    return ic.voiceSessionId == sessionID
  }

  private func teardownSession() {
    isRecording = false
    finalInFlight = false
    eventTask?.cancel()
    eventTask = nil
    // 显式停采集会话：不能只靠置 nil。TranscriptionSession 的 feedingTask 闭包强引用着
    // audioSource，对象不会立刻释放 → deinit 不触发 → AVCaptureSession 继续跑 →
    // 系统麦克风占用指示器一直亮。stop() 幂等（stopInternal 查 isRunning），重复调用安全。
    if let source = audioSource {
      Task { await source.stop() }
    }
    transcriberSession = nil
    audioSource = nil
    segQueue.sync { finalSegments = [] }
    audioQueue.sync { accumulated16k = [] }
  }

  // MARK: - 事件路由（到激活输入控制器）

  private func route(_ event: VoiceNativeEvent) {
    switch event {
    case .start:
      SquirrelVoiceLog.write("route .start")
    case .partial(let t, _):
      SquirrelVoiceLog.write("route .partial text=\"\(t.prefix(50))\"")
    case .final(let t, let s):
      SquirrelVoiceLog.write("route .final text=\"\(t.prefix(50))\" status=\(s ?? "nil")")
    case .done:
      break
    }
    guard let ic = delegate?.activeInputController ?? delegate?.panel?.inputController else {
      if case .final(let text, let status) = event, !text.isEmpty {
        // 进程刚重启时客户端尚未重新激活 IME：缓存 final，等 activateServer 投递。
        pendingFinal = (text, status, Date())
        SquirrelVoiceLog.write("无激活输入控制器，暂存 final 待下次激活投递")
      } else {
        SquirrelVoiceLog.write("无激活输入控制器，丢弃事件")
      }
      return
    }
    switch event {
    case .start:
      ic.voiceShowStatus("聆听中")
    case .partial(let text, let conf):
      ic.voiceShowCandidate(text, sessionId: sessionID, isFinal: false,
                            status: hasReleased ? "正在定稿" : recordingHint,
                            confidence: conf.map { String(format: "%.2f", $0) })
    case .final(let text, let status):
      if text.isEmpty {
        ic.voiceDiscard()
      } else {
        ic.voiceShowCandidate(text, sessionId: sessionID, isFinal: true, status: status, confidence: nil)
      }
    case .done:
      break
    }
  }

  // MARK: - 时间戳对齐过滤

  /// 只保留与「我的时间区间」有重叠的转写段。
  static func filterSegments(_ segments: [(text: String, start: Double, end: Double)],
                             by myRanges: [(start: Float, end: Float)]) -> [(text: String, start: Double, end: Double)] {
    return segments.filter { seg in
      guard seg.end > seg.start else { return true }   // 无时间戳：保留（宁多勿漏）
      let s = Float(seg.start)
      let e = Float(seg.end)
      return myRanges.contains { r in
        Swift.min(e, r.end) - Swift.max(s, r.start) > 0
      }
    }
  }
}
