//
//  VoiceNativeSettingsWindow.swift
//  Squirrel (SquirrelVoice fork)
//
//  原生语音输入设置界面（替代原「用户设定...」打开文件夹的行为）。
//
//  分组：
//  - 热键（可配置，格式 修饰键+按键，如 option+grave）
//  - LLM 语义清洗（开关 + base_url + model + API key + 测试连通性）
//  - 说话人过滤（FluidAudio；开关 + 声纹注册/清除 + 状态）
//
//  配置存储：UserDefaults（voice_native.*）+ ~/.squirrelvoice/credentials.yaml（API key，600）。
//  纯程序化布局（翻转视图），不依赖 xib/storyboard。
//

import AppKit
import AVFoundation

private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

final class VoiceNativeSettingsWindow: NSWindow, NSWindowDelegate {
  // LLM 区块
  private var llmEnabledCheck: NSButton!
  private var llmBaseUrlField: NSTextField!
  private var llmModelField: NSTextField!
  private var llmPromptField: NSTextField!
  private var resetPromptButton: NSButton!
  private var llmKeyField: NSSecureTextField!
  private var llmTestButton: NSButton!
  private var llmStatusLabel: NSTextField!

  // 说话人过滤区块
  private var speakerEnabledCheck: NSButton!
  private var speakerStatusLabel: NSTextField!
  private var registerButton: NSButton!
  private var clearSpeakerButton: NSButton!

  // 热键
  private var hotkeyField: NSTextField!

  // 录音麦克风
  private var micPopup: NSPopUpButton!
  private var micRefreshButton: NSButton!

  // 通用
  private var saveButton: NSButton!
  private var statusLabel: NSTextField!

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: false
    )
    title = "语音输入设置"
    isReleasedWhenClosed = false
    delegate = self
    center()
    installEditMenu()
    buildUI()
    reload()
  }

  /// 输入法进程平时没有主菜单，⌘C/⌘V/⌘X/⌘A 这些 key equivalent 无处解析，
  /// 文本框里就复制粘贴不了。打开设置窗口时装一个只含「编辑」菜单的最小
  /// 主菜单，动作沿响应链走到字段编辑器。
  private func installEditMenu() {
    guard NSApp.mainMenu == nil else { return }
    let mainMenu = NSMenu()
    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "编辑")
    editItem.submenu = editMenu
    editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    NSApp.mainMenu = mainMenu
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

  /// 声纹注册是否正在进行（防止重复点击 + 关窗重开时正确恢复按钮态）。
  private var isRegistering = false
  /// 是否正在录声纹（点「注册声纹」后进入录音态，按钮变「停止录音」）。
  private var isRecordingVoiceprint = false
  /// 声纹录音器（手动开始/停止，不限时长）。
  private let voiceprintRecorder = VoiceprintRecorder()

  override func makeKeyAndOrderFront(_ sender: Any?) {
    super.makeKeyAndOrderFront(sender)
    reload()
    // 窗口是单例复用：若上次注册已结束（成功/失败/异常），确保按钮恢复可点，
    // 避免"关窗重开后按钮仍灰着点不了"。注册进行中则保持禁用。
    if !isRegistering { registerButton.isEnabled = true }
  }

  func windowWillClose(_ notification: Notification) {
    // 关窗时若正在录声纹，停止录音释放麦克风，并复位按钮态（避免重开窗口卡在「停止录音」）。
    if isRecordingVoiceprint {
      isRecordingVoiceprint = false
      voiceprintRecorder.onTick = nil
      _ = voiceprintRecorder.stop()
      registerButton.title = "注册声纹"
      registerButton.isEnabled = true
    }
    if NSApp.activationPolicy() == .regular {
      NSApp.setActivationPolicy(.accessory)
    }
  }

  // MARK: - UI 构建

  private func buildUI() {
    guard let content = contentView else { return }

    let scroll = NSScrollView(frame: content.bounds)
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false

    let form = FlippedView()
    scroll.documentView = form

    let leftMargin: CGFloat = 24
    let labelWidth: CGFloat = 76
    let fieldX = leftMargin + labelWidth
    let fieldWidth: CGFloat = 230
    let hintX = fieldX + fieldWidth + 12
    let hintWidth: CGFloat = 640 - hintX - 20

    var y: CGFloat = 20

    // ── 热键（可配置）──
    y = sectionTitle("热键（按一次开始，再按一次结束）", form: form, y: y, x: leftMargin)
    let hotkeyLabel = makeLabel("快捷键", bold: false)
    hotkeyLabel.frame = NSRect(x: leftMargin, y: y + 2, width: labelWidth, height: 20)
    form.addSubview(hotkeyLabel)
    hotkeyField = NSTextField(frame: NSRect(x: fieldX, y: y, width: fieldWidth, height: 24))
    hotkeyField.font = NSFont.systemFont(ofSize: 12)
    hotkeyField.placeholderString = "option+`"
    form.addSubview(hotkeyField)
    let hotkeyHint = makeHint("格式：修饰键+按键，如 option+`、ctrl+space、cmd+shift+f9。注意 cmd+` 被系统「切换窗口」菜单占用、收不到事件，勿用")
    hotkeyHint.frame = NSRect(x: hintX, y: y, width: hintWidth, height: 32)
    form.addSubview(hotkeyHint)
    y += 32

    // ── 录音麦克风 ──
    y += 14
    y = sectionTitle("录音麦克风", form: form, y: y, x: leftMargin)
    let micLabel = makeLabel("设备", bold: false)
    micLabel.frame = NSRect(x: leftMargin, y: y + 2, width: labelWidth, height: 20)
    form.addSubview(micLabel)
    micPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: y - 2, width: fieldWidth, height: 28), pullsDown: false)
    micPopup.font = NSFont.systemFont(ofSize: 12)
    micPopup.target = self
    micPopup.action = #selector(micChangedTapped)
    form.addSubview(micPopup)
    micRefreshButton = NSButton(title: "刷新列表", target: self, action: #selector(refreshMicsTapped))
    micRefreshButton.bezelStyle = .rounded
    micRefreshButton.frame = NSRect(x: fieldX + fieldWidth + 8, y: y - 2, width: 90, height: 28)
    form.addSubview(micRefreshButton)
    let micHint = makeHint("默认跟随 系统设置→声音→输入 的默认设备；指定设备拔线后自动回落系统默认。换设备后点「刷新列表」")
    micHint.frame = NSRect(x: hintX + 100, y: y, width: hintWidth - 100, height: 32)
    form.addSubview(micHint)
    y += 34

    // ── LLM 语义清洗 ──
    y += 14
    y = sectionTitle("LLM 语义清洗（云端 API）", form: form, y: y, x: leftMargin)

    llmEnabledCheck = NSButton(checkboxWithTitle: "启用 LLM 清洗", target: nil, action: nil)
    llmEnabledCheck.frame = NSRect(x: leftMargin, y: y, width: fieldWidth, height: 24)
    form.addSubview(llmEnabledCheck)
    y += 30

    let baseUrlLabel = makeLabel("API 端点", bold: false)
    baseUrlLabel.frame = NSRect(x: leftMargin, y: y + 2, width: labelWidth, height: 20)
    form.addSubview(baseUrlLabel)
    llmBaseUrlField = NSTextField(frame: NSRect(x: fieldX, y: y, width: fieldWidth, height: 24))
    llmBaseUrlField.font = NSFont.systemFont(ofSize: 12)
    llmBaseUrlField.placeholderString = "https://api.openai.com/v1"
    form.addSubview(llmBaseUrlField)
    let baseUrlHint = makeHint("OpenAI 兼容 base_url（不带末尾 /chat/completions）")
    baseUrlHint.frame = NSRect(x: hintX, y: y, width: hintWidth, height: 32)
    form.addSubview(baseUrlHint)
    y += 32

    let modelLabel = makeLabel("模型名", bold: false)
    modelLabel.frame = NSRect(x: leftMargin, y: y + 2, width: labelWidth, height: 20)
    form.addSubview(modelLabel)
    llmModelField = NSTextField(frame: NSRect(x: fieldX, y: y, width: fieldWidth, height: 24))
    llmModelField.font = NSFont.systemFont(ofSize: 12)
    llmModelField.placeholderString = "gpt-4o-mini / deepseek-chat"
    form.addSubview(llmModelField)
    y += 32

    // 清洗提示词（多行；空 = 内置默认）
    let promptLabel = makeLabel("清洗提示词", bold: false)
    promptLabel.frame = NSRect(x: leftMargin, y: y + 2, width: labelWidth, height: 20)
    form.addSubview(promptLabel)
    let promptWidth: CGFloat = 640 - fieldX - 24
    llmPromptField = NSTextField(frame: NSRect(x: fieldX, y: y, width: promptWidth, height: 110))
    llmPromptField.font = NSFont.systemFont(ofSize: 11)
    llmPromptField.cell?.wraps = true
    llmPromptField.cell?.isScrollable = false
    llmPromptField.usesSingleLineMode = false
    llmPromptField.maximumNumberOfLines = 0
    llmPromptField.lineBreakMode = .byWordWrapping
    form.addSubview(llmPromptField)
    y += 114
    let promptHint = makeHint("LLM system prompt，可直接修改；改坏了点「恢复默认」")
    promptHint.frame = NSRect(x: fieldX, y: y, width: promptWidth - 110, height: 18)
    form.addSubview(promptHint)
    resetPromptButton = NSButton(title: "恢复默认", target: self, action: #selector(resetPromptTapped))
    resetPromptButton.bezelStyle = .rounded
    resetPromptButton.frame = NSRect(x: 640 - 24 - 100, y: y - 6, width: 100, height: 28)
    form.addSubview(resetPromptButton)
    y += 28

    let keyLabel = makeLabel("API Key", bold: false)
    keyLabel.frame = NSRect(x: leftMargin, y: y + 2, width: labelWidth, height: 20)
    form.addSubview(keyLabel)
    llmKeyField = NSSecureTextField(frame: NSRect(x: fieldX, y: y, width: fieldWidth, height: 24))
    llmKeyField.font = NSFont.systemFont(ofSize: 12)
    llmKeyField.placeholderString = "未设置（sk-...）"
    form.addSubview(llmKeyField)
    let keyHint = makeHint("存 ~/.squirrelvoice/credentials.yaml（600）；留空=保持不变")
    keyHint.frame = NSRect(x: hintX, y: y, width: hintWidth, height: 32)
    form.addSubview(keyHint)
    y += 36

    llmTestButton = NSButton(title: "测试连通性", target: self, action: #selector(testLlmTapped))
    llmTestButton.bezelStyle = .rounded
    llmTestButton.frame = NSRect(x: leftMargin, y: y, width: 110, height: 30)
    form.addSubview(llmTestButton)

    llmStatusLabel = makeLabel("", bold: false)
    llmStatusLabel.frame = NSRect(x: leftMargin + 120, y: y + 5, width: 480, height: 20)
    form.addSubview(llmStatusLabel)
    y += 38

    // ── 说话人过滤（FluidAudio）──
    y += 14
    y = sectionTitle("说话人过滤（FluidAudio 离线声纹）", form: form, y: y, x: leftMargin)

    speakerEnabledCheck = NSButton(checkboxWithTitle: "启用说话人过滤", target: nil, action: nil)
    speakerEnabledCheck.frame = NSRect(x: leftMargin, y: y, width: fieldWidth, height: 24)
    form.addSubview(speakerEnabledCheck)
    let speakerHint = makeHint("松手后离线 diarization，只保留本人语音（需先注册声纹）")
    speakerHint.frame = NSRect(x: hintX, y: y, width: hintWidth, height: 32)
    form.addSubview(speakerHint)
    y += 30

    speakerStatusLabel = makeLabel("…", bold: false)
    speakerStatusLabel.frame = NSRect(x: leftMargin, y: y, width: 460, height: 20)
    form.addSubview(speakerStatusLabel)
    y += 28

    registerButton = NSButton(title: "注册声纹", target: self, action: #selector(registerTapped))
    registerButton.bezelStyle = .rounded
    registerButton.frame = NSRect(x: leftMargin, y: y, width: 100, height: 30)
    form.addSubview(registerButton)

    clearSpeakerButton = NSButton(title: "清除声纹", target: self, action: #selector(clearSpeakerTapped))
    clearSpeakerButton.bezelStyle = .rounded
    clearSpeakerButton.frame = NSRect(x: leftMargin + 110, y: y, width: 100, height: 30)
    form.addSubview(clearSpeakerButton)

    let registerHint = makeHint("点「注册声纹」开始录音，说完点「停止录音」。不限时长，建议录 10s+（越长声纹越准）")
    registerHint.frame = NSRect(x: leftMargin + 220, y: y + 5, width: hintWidth, height: 32)
    form.addSubview(registerHint)
    y += 38

    // ── 保存 ──
    y += 14
    saveButton = NSButton(title: "保存", target: self, action: #selector(saveTapped))
    saveButton.bezelStyle = .rounded
    saveButton.keyEquivalent = "\r"
    saveButton.frame = NSRect(x: leftMargin, y: y, width: 120, height: 30)
    form.addSubview(saveButton)

    statusLabel = makeLabel("", bold: false)
    statusLabel.frame = NSRect(x: leftMargin + 130, y: y + 5, width: 460, height: 20)
    form.addSubview(statusLabel)
    y += 44

    form.frame = NSRect(x: 0, y: 0, width: 640, height: max(y, 500))
    content.addSubview(scroll)
  }

  // MARK: - 布局辅助

  private func makeLabel(_ text: String, bold: Bool) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 12)
    return l
  }

  /// 右侧灰色注释：允许换行，避免长文本被截断。
  private func makeHint(_ text: String) -> NSTextField {
    let l = makeLabel(text, bold: false)
    l.textColor = NSColor.secondaryLabelColor
    l.lineBreakMode = .byWordWrapping
    l.maximumNumberOfLines = 0
    return l
  }

  private func sectionTitle(_ text: String, form: NSView, y: CGFloat, x: CGFloat) -> CGFloat {
    let l = makeLabel(text, bold: true)
    l.frame = NSRect(x: x, y: y, width: 590, height: 20)
    form.addSubview(l)
    return y + 30
  }

  // MARK: - 数据加载 / 保存

  /// 重建设备下拉列表；selectedUID 不在列表里（拔线等）时选中"系统默认"并提示。
  private func populateMics(selectedUID: String) {
    micPopup.removeAllItems()
    micPopup.addItem(withTitle: "系统默认（跟随声音设置）")
    micPopup.lastItem?.representedObject = ""
    var targetIndex = 0
    var matched = selectedUID.isEmpty
    for dev in VoiceNativeAudioDevices.inputDevices() {
      micPopup.addItem(withTitle: dev.name)
      micPopup.lastItem?.representedObject = dev.uid
      if dev.uid == selectedUID {
        matched = true
        targetIndex = micPopup.numberOfItems - 1
      }
    }
    micPopup.selectItem(at: targetIndex)
    if !matched {
      speakerStatusLabel.stringValue = "指定麦克风不在线，暂用系统默认"
    }
  }

  /// 下拉框一选即生效：立刻写入配置并 reload（语音输入、声纹注册都读这份配置，
  /// 不再依赖点「保存」——避免"选了没保存 → 还在用系统默认"的坑。
  @objc private func micChangedTapped() {
    var cfg = VoiceNativeConfig.load()
    cfg.audioDeviceUID = (micPopup.selectedItem?.representedObject as? String) ?? ""
    cfg.save()
    NSApp.squirrelAppDelegate.voiceNative?.reloadConfig()
    statusLabel.stringValue = "已切换麦克风：\(micPopup.titleOfSelectedItem ?? "")（立即生效）"
    SquirrelVoiceLog.write("设置：切换麦克风 → \(micPopup.titleOfSelectedItem ?? "") uid=\(cfg.audioDeviceUID)")
  }

  @objc private func refreshMicsTapped() {
    populateMics(selectedUID: VoiceNativeConfig.load().audioDeviceUID)
    statusLabel.stringValue = "设备列表已刷新"
  }

  private func reload() {
    let cfg = VoiceNativeConfig.load()
    // 显示规范化形式（grave → `），与保存后的回显一致。
    hotkeyField.stringValue = VoiceNativeHotkeyCombo.parse(cfg.hotkey).combo?.display ?? cfg.hotkey
    populateMics(selectedUID: cfg.audioDeviceUID)
    llmEnabledCheck.state = cfg.llmEnabled ? .on : .off
    llmBaseUrlField.stringValue = cfg.llmBaseUrl
    llmModelField.stringValue = cfg.llmModel
    // 框里直接显示当前生效的提示词：自定义为空时展示内置默认全文。
    llmPromptField.stringValue = cfg.llmPrompt.isEmpty
      ? VoiceNativeLLMPolisher.defaultSystemPrompt : cfg.llmPrompt
    speakerEnabledCheck.state = cfg.speakerFilterEnabled ? .on : .off

    if let key = VoiceNativeCredentials.loadKey() {
      llmKeyField.placeholderString = "已设置（\(VoiceNativeCredentials.mask(key))）；留空保持不变"
    } else {
      llmKeyField.placeholderString = "未设置（sk-...）"
    }

    refreshSpeakerStatus()
  }

  private func refreshSpeakerStatus() {
    let filter = VoiceNativeSpeakerFilter()
    filter.loadVoiceprint()
    if filter.hasVoiceprint {
      speakerStatusLabel.stringValue = "已注册声纹"
    } else {
      speakerStatusLabel.stringValue = "未注册声纹（点「注册声纹」开始）"
    }
  }

  @objc private func saveTapped() {
    // 热键校验：无效则拒绝保存。
    let hotkeyRaw = hotkeyField.stringValue.trimmingCharacters(in: .whitespaces)
    let (combo, hotkeyErr) = VoiceNativeHotkeyCombo.parse(hotkeyRaw)
    guard combo != nil else {
      statusLabel.stringValue = "热键无效：\(hotkeyErr ?? "未知错误")"
      return
    }

    var cfg = VoiceNativeConfig.load()
    cfg.hotkey = combo!.display
    cfg.audioDeviceUID = (micPopup.selectedItem?.representedObject as? String) ?? ""
    cfg.llmEnabled = llmEnabledCheck.state == .on
    cfg.llmBaseUrl = llmBaseUrlField.stringValue.trimmingCharacters(in: .whitespaces)
    cfg.llmModel = llmModelField.stringValue.trimmingCharacters(in: .whitespaces)
    // 与内置默认一致时存空串：继续跟随内置默认（将来默认升级自动受益）。
    let promptText = llmPromptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    cfg.llmPrompt = promptText == VoiceNativeLLMPolisher.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
      ? "" : promptText
    cfg.speakerFilterEnabled = speakerEnabledCheck.state == .on
    cfg.save()
    hotkeyField.stringValue = combo!.display

    let keyText = llmKeyField.stringValue.trimmingCharacters(in: .whitespaces)
    if !keyText.isEmpty {
      let (ok, err) = VoiceNativeCredentials.saveKey(keyText)
      if ok {
        llmKeyField.stringValue = ""
        llmKeyField.placeholderString = "已设置（\(VoiceNativeCredentials.mask(keyText))）；留空保持不变"
      } else {
        statusLabel.stringValue = "API Key 保存失败：\(err ?? "")"
        return
      }
    }

    // 通知协调器重新加载配置
    NSApp.squirrelAppDelegate.voiceNative?.reloadConfig()
    statusLabel.stringValue = "已保存"
  }

  @objc private func resetPromptTapped() {
    llmPromptField.stringValue = VoiceNativeLLMPolisher.defaultSystemPrompt
    statusLabel.stringValue = "已填入默认提示词（点「保存」生效）"
  }

  @objc private func testLlmTapped() {
    llmTestButton.isEnabled = false
    llmStatusLabel.stringValue = "正在测试连通性…"
    let baseUrl = llmBaseUrlField.stringValue.trimmingCharacters(in: .whitespaces)
    let model = llmModelField.stringValue.trimmingCharacters(in: .whitespaces)
    let keyText = llmKeyField.stringValue.trimmingCharacters(in: .whitespaces)
    let key = keyText.isEmpty ? (VoiceNativeCredentials.loadKey() ?? "") : keyText

    guard !baseUrl.isEmpty, !model.isEmpty, !key.isEmpty else {
      llmStatusLabel.stringValue = "请先填写端点、模型和 API Key"
      llmTestButton.isEnabled = true
      return
    }

    let polisher = VoiceNativeLLMPolisher(baseURL: baseUrl, model: model, apiKey: key)
    Task { @MainActor in
      let (ok, err, latency) = await polisher.testConnectivity()
      if ok {
        llmStatusLabel.stringValue = "连接成功（延迟 \(latency ?? 0) ms）"
      } else {
        llmStatusLabel.stringValue = "连接失败：\(err ?? "未知错误")"
      }
      llmTestButton.isEnabled = true
    }
  }

  // MARK: - 声纹管理

  /// 声纹注册按钮：两段式切换。
  ///   - 未录音 → 开始录音（不限时长，按钮变「停止录音」，实时显示已录秒数）；
  ///   - 录音中 → 停止并提取/保存声纹（按钮恢复「注册声纹」）。
  @objc private func registerTapped() {
    if isRecordingVoiceprint {
      stopAndEnroll()
    } else {
      startRecording()
    }
  }

  /// 开始录声纹：立即开麦（先确认麦克风可用，别让用户白说十几秒），不限时长。
  private func startRecording() {
    guard !isRegistering, !isRecordingVoiceprint else { return }
    do {
      try voiceprintRecorder.start()
    } catch {
      speakerStatusLabel.stringValue = "无法开始录音：\(error.localizedDescription)"
      return
    }
    isRecordingVoiceprint = true
    registerButton.title = "停止录音"
    registerButton.isEnabled = true
    // 每秒刷新已录时长；≥10s 提示已足够（模型只用前 10s）。
    voiceprintRecorder.onTick = { [weak self] secs in
      guard let self else { return }
      let hint = secs >= 10 ? "（已足够，可停止）" : ""
      self.speakerStatusLabel.stringValue = "正在录音…请说话，说完点「停止录音」（已录 \(secs)s）\(hint)"
    }
    speakerStatusLabel.stringValue = "正在录音…请说话，说完点「停止录音」（已录 0s）"
  }

  /// 停止录音并提取/保存声纹。
  private func stopAndEnroll() {
    guard isRecordingVoiceprint else { return }
    isRecordingVoiceprint = false
    voiceprintRecorder.onTick = nil
    let samples = voiceprintRecorder.stop()
    let secs = max(1, Int(Double(samples.count) / 16000.0))
    // 太短（<1s）声纹不可靠，提示重录。
    guard samples.count > 16000 else {
      registerButton.title = "注册声纹"
      speakerStatusLabel.stringValue = "录音太短（<1s），请重新录制"
      return
    }
    isRegistering = true
    registerButton.isEnabled = false
    speakerStatusLabel.stringValue = "正在提取声纹（\(secs)s 样本）…"
    Task { @MainActor in
      defer {
        // 无论成功 / 失败 / 异常，都恢复按钮——杜绝"卡灰点不了"。
        isRegistering = false
        registerButton.title = "注册声纹"
        registerButton.isEnabled = true
      }
      let filter = VoiceNativeSpeakerFilter()
      let (rok, rerr, _) = await filter.enroll(fromAudio16k: samples)
      if rok {
        speakerStatusLabel.stringValue = "声纹注册成功（\(secs)s 样本）"
        NSApp.squirrelAppDelegate.voiceNative?.reloadConfig()
      } else {
        speakerStatusLabel.stringValue = "注册失败：\(rerr ?? "")"
      }
    }
  }

  @objc private func clearSpeakerTapped() {
    let alert = NSAlert()
    alert.messageText = "清除声纹"
    alert.informativeText = "将删除已注册的声纹（voiceprint_native.json），此操作不可撤销。确定继续？"
    alert.addButton(withTitle: "清除")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let filter = VoiceNativeSpeakerFilter()
    filter.clearVoiceprint()
    speakerStatusLabel.stringValue = "声纹已清除"
  }

  /// 录 3 秒 mono Float 音频（用 AVAudioEngine，macOS 无 AVAudioSession）。
}

/// 声纹录音器：手动控制开始/停止，累积 16kHz mono 采样。
///
/// 【关键】必须复用 VoiceNativeAudioSource（AVCaptureSession），不能用 AVAudioEngine！
/// 实测：注册用 AVAudioEngine、过滤用 AVCaptureSession，两者系统音频处理不同（降噪/AGC），
/// 同一人说话产出的 embedding 方向都不同 → 声纹 vs 过滤段 sim 掉到 ~0.03（而注册内部各段
/// 互相 sim 0.888）。改用和过滤完全相同的采集+降采样路径后，两条路径音频特征一致，sim 才可靠。
///
/// 为什么不限时、让用户自己录十几秒：FluidAudio 声纹模型固定吃 160_000 采样（=16kHz×10s）。
/// 短音频会被「重复填充」到 10s（3s 录音 → 同一段话重复 3 遍），embedding 被稀释、质量差；
/// 录满 ~10s 真实语音则填满 buffer，声纹更稳。超过 10s 的部分会被截断（无害）。所以让用户
/// 自由录到满意为止（十几秒最佳），比固定 3s 效果好得多。
private final class VoiceprintRecorder {
    // 【关键】每次 start 都新建 VoiceNativeAudioSource：它的 configureAndStart() 有
    // `guard !configured else { return }`，同一实例只能 start 一次（stop 不重置 configured）。
    // 复用单例会导致第二次录音 session 不重启 → 0 采样。所以每次录音用全新实例。
    private var source: VoiceNativeAudioSource?
    private var accumulated: [Float] = []
    private let lock = NSLock()
    private var timer: Timer?
    private var startTime: Date?
    private var drainTask: Task<Void, Never>?
    private var lastLogCount = 0

    /// 每秒回调，参数为已录秒数（供 UI 显示进度）。
    var onTick: ((Int) -> Void)?

    func start() throws {
        lock.lock(); accumulated = []; lastLogCount = 0; lock.unlock()
        SquirrelVoiceLog.write("VoiceprintRecorder [诊断] start：开始 AVCaptureSession 采集")
        // 每次录音用全新实例（见 source 属性注释）。
        let src = VoiceNativeAudioSource(deviceUID: VoiceNativeConfig.load().audioDeviceUID)
        self.source = src
        // 与过滤路径完全相同：onFloat16k 旁路累积 16kHz mono（同一 AVCaptureSession + 同一降采样）。
        src.onFloat16k = { [weak self] f in
            guard let self else { return }
            self.lock.lock()
            self.accumulated.append(contentsOf: f)
            let n = self.accumulated.count
            // 每累积 ~1s（16000 采样）记一次，确认 onFloat16k 在触发。
            if n - self.lastLogCount >= 16000 {
                self.lastLogCount = n
                SquirrelVoiceLog.write("VoiceprintRecorder [诊断] onFloat16k 累积 \(n) 采样（\(String(format: "%.1f", Double(n)/16000.0))s）")
            }
            self.lock.unlock()
        }
        // start() 返回的 PCM stream 是给 ASR 消费的；这里只靠 onFloat16k 旁路，
        // 但必须排空 stream（否则 continuation 无限缓冲 PCM buffer）。
        let stream = src.start()
        drainTask = Task { [weak self] in
            do { for try await _ in stream { /* 丢弃 PCM，只要 onFloat16k */ } }
            catch { SquirrelVoiceLog.write("VoiceprintRecorder [诊断] stream 结束/出错：\(String(describing: (error as? Error)?.localizedDescription))") }
            self?.drainTask = nil
        }
        startTime = Date()
        // 每秒刷新一次已录时长（主 runloop）。
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            self.onTick?(Int(Date().timeIntervalSince(start)))
        }
    }

    /// 停止录音，返回累积的 16kHz mono 采样（已由 onFloat16k 降好采样）。
    func stop() -> [Float] {
        timer?.invalidate()
        timer = nil
        if let src = source {
            Task { await src.stop() }   // 异步停 AVCaptureSession + finish stream
        }
        lock.lock()
        let result = accumulated
        lock.unlock()
        SquirrelVoiceLog.write("VoiceprintRecorder [诊断] stop：共累积 \(result.count) 采样（\(String(format: "%.2f", Double(result.count)/16000.0))s）")
        return result
    }

    /// 已录秒数（供 UI / 关窗时判断）。
    var elapsedSeconds: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }
}
