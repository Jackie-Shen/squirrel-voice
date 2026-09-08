//
//  VoiceNativeTypes.swift
//  Squirrel (SquirrelVoice fork)
//
//  macOS 原生语音输入模块（无 Python 后端）的共享类型与配置存取。
//
//  架构：AVCaptureSession 采集 → SpeechAnalyzer(macOS26) 流式转写 →
//        FluidAudio 离线说话人过滤(松手后，可选) → 云端 LLM 清洗(可选) →
//        回调到输入控制器候选窗（Enter 提交 / Esc 丢弃）。
//
//  配置存储：
//  - 非密钥参数 → UserDefaults（suite 默认）
//  - LLM API key → ~/.squirrelvoice/credentials.yaml（权限 600，不进 yaml/UserDefaults）
//

import Foundation

/// 语音原生模块配置（从 UserDefaults 读取；API key 单独走 credentials.yaml）。
struct VoiceNativeConfig {
  var enabled: Bool
  /// 触发热键描述（如 "option+grave"）。默认 option+`（左手、单修饰、无冲突）。
  /// 不要用纯 cmd+`：它是 macOS 各应用「窗口」菜单的切换窗口快捷键
  /// （performKeyEquivalent），事件到不了输入法。可在设置窗口修改。
  var hotkey: String
  var llmEnabled: Bool
  var llmBaseUrl: String
  var llmModel: String
  /// 自定义 LLM 清洗系统提示词；空 = 用 VoiceNativeLLMPolisher.defaultSystemPrompt。
  var llmPrompt: String
  /// 录音麦克风设备 UID；空 = 跟随系统默认输入设备。
  var audioDeviceUID: String
  /// 说话人过滤（FluidAudio 离线 diarization + 声纹匹配）开关。
  var speakerFilterEnabled: Bool

  static let defaults = VoiceNativeConfig(
    enabled: true,
    hotkey: "option+grave",
    llmEnabled: false,
    llmBaseUrl: "",
    llmModel: "",
    llmPrompt: "",
    audioDeviceUID: "",
    speakerFilterEnabled: false
  )

  private enum Key {
    static let enabled = "voice_native.enabled"
    static let hotkey = "voice_native.hotkey"
    static let llmEnabled = "voice_native.llm_enabled"
    static let llmBaseUrl = "voice_native.llm_base_url"
    static let llmModel = "voice_native.llm_model"
    static let llmPrompt = "voice_native.llm_prompt"
    static let audioDeviceUID = "voice_native.audio_device_uid"
    static let speakerFilterEnabled = "voice_native.speaker_filter_enabled"
  }

  static func load() -> VoiceNativeConfig {
    let d = UserDefaults.standard
    return VoiceNativeConfig(
      enabled: d.object(forKey: Key.enabled) as? Bool ?? true,
      hotkey: d.string(forKey: Key.hotkey) ?? "option+grave",
      llmEnabled: d.object(forKey: Key.llmEnabled) as? Bool ?? false,
      llmBaseUrl: d.string(forKey: Key.llmBaseUrl) ?? "",
      llmModel: d.string(forKey: Key.llmModel) ?? "",
      llmPrompt: d.string(forKey: Key.llmPrompt) ?? "",
      audioDeviceUID: d.string(forKey: Key.audioDeviceUID) ?? "",
      speakerFilterEnabled: d.object(forKey: Key.speakerFilterEnabled) as? Bool ?? false
    )
  }

  func save() {
    let d = UserDefaults.standard
    d.set(enabled, forKey: Key.enabled)
    d.set(hotkey, forKey: Key.hotkey)
    d.set(llmEnabled, forKey: Key.llmEnabled)
    d.set(llmBaseUrl, forKey: Key.llmBaseUrl)
    d.set(llmModel, forKey: Key.llmModel)
    d.set(llmPrompt, forKey: Key.llmPrompt)
    d.set(audioDeviceUID, forKey: Key.audioDeviceUID)
    d.set(speakerFilterEnabled, forKey: Key.speakerFilterEnabled)
  }
}

/// LLM API key 存取（~/.squirrelvoice/credentials.yaml，权限 600）。
/// LLM API key 文件约定（沿用第一代 Python 后端）：`llm_api_key: <key>`。
/// 密钥不进 UserDefaults / squirrel.yaml。
enum VoiceNativeCredentials {
  static func dir() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".squirrelvoice", isDirectory: true)
  }

  static func fileURL() -> URL {
    dir().appendingPathComponent("credentials.yaml")
  }

  /// 读取已保存的 API key；未设置返回 nil。
  static func loadKey() -> String? {
    let url = fileURL()
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    for line in content.split(separator: "\n") {
      let t = line.trimmingCharacters(in: .whitespaces)
      if t.hasPrefix("llm_api_key:") {
        let v = t.dropFirst("llm_api_key:".count)
          .trimmingCharacters(in: .whitespaces)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return v.isEmpty ? nil : String(v)
      }
    }
    return nil
  }

  /// 保存 API key（创建目录 + 写文件 + chmod 600）。返回 (成功, 错误)。
  @discardableResult
  static func saveKey(_ key: String) -> (Bool, String?) {
    do {
      let fm = FileManager.default
      try fm.createDirectory(at: dir(), withIntermediateDirectories: true)
      // 保留其他键：读旧内容，替换 llm_api_key 行。
      var lines: [String] = []
      if let old = try? String(contentsOf: fileURL(), encoding: .utf8) {
        lines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      }
      var replaced = false
      for i in lines.indices {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("llm_api_key:") {
          lines[i] = "llm_api_key: \(key)"
          replaced = true
        }
      }
      if !replaced { lines.append("llm_api_key: \(key)") }
      let content = lines.joined(separator: "\n") + "\n"
      try content.write(to: fileURL(), atomically: true, encoding: .utf8)
      try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL().path)
      return (true, nil)
    } catch {
      return (false, error.localizedDescription)
    }
  }

  /// 脱敏展示（前 4 + 后 4，中间 ***）；过短只返回长度提示。
  static func mask(_ key: String) -> String {
    guard key.count > 8 else { return "已设置(\(key.count) 字符)" }
    let f = key.prefix(4), l = key.suffix(4)
    return "\(f)***\(l)"
  }
}

/// 语音会话事件（协调器 → 输入控制器；事件语义沿用第一代 SSE 管线的 start/partial/final）。
enum VoiceNativeEvent {
  case start
  case partial(text: String, confidence: Double?)
  case final(text: String, status: String?)
  case done
}
