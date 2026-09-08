//
//  SquirrelInputController+VoiceNative.swift
//  Squirrel (SquirrelVoice fork)
//
//  原生语音候选接口（语音模块专用扩展）。
//
//  由 VoiceNativeCoordinator 的事件路由驱动（主线程），把 ASR 结果以「原生候选行」
//  形式展示：1. 文本 —— 确认方式与普通打字完全一致（Enter / 空格 / 数字 1 = 提交；
//  Esc = 丢弃）。
//
//  注意：Swift 扩展不能声明存储属性，语音会话状态（voiceActive 等）仍留在
//  SquirrelInputController 类体内；本文件只承载行为。
//

import AppKit
import InputMethodKit

extension SquirrelInputController {

  // MARK: - 展示

  /// start：录音开始 → 立即弹面板：第 1 行状态文案，第 2 行"录音中（按 xxx 结束）"提示。
  func voiceShowStatus(_ message: String) {
    voiceActive = true
    voiceReady = false
    voiceText = ""
    voiceClearStaleComposition(hidePanel: true)
    let hint = NSApp.squirrelAppDelegate.voiceNative?.recordingHint ?? "录音中"
    voiceShowPanel(candidates: [message, hint], comments: ["", ""])
    SquirrelVoiceLog.write("voiceShowStatus：\(message) / \(hint)")
  }

  /// 清掉残留的 Rime 组合（拼音、或按 ` 触发的符号组候选窗），避免语音会话
  /// 开始前/提交/丢弃后旧候选窗滞留或被下一次按键复活。
  func voiceClearStaleComposition(hidePanel: Bool) {
    if voiceSession != 0, voiceRimeAPI.find_session(voiceSession) {
      voiceRimeAPI.clear_composition(voiceSession)
    }
    if hidePanel {
      hidePalettes()
    }
  }

  /// partial / final：实时文本或最终文本 → 候选窗显示（Enter 提交 / Esc 丢弃）。
  func voiceShowCandidate(_ text: String, sessionId: String, isFinal: Bool,
                          status: String? = nil, confidence: String? = nil) {
    voiceActive = true
    voiceText = text
    voiceSessionId = sessionId
    voiceReady = isFinal && !text.isEmpty
    let secondRow = Self.voiceSecondRow(status: status, confidence: confidence)
    showVoiceRow(text, secondRow: secondRow)
  }

  /// 第 2 行候选文本：录音中 → "置信度 87%"；松手后 → status 文案；定稿/无信息 → nil。
  private static func voiceSecondRow(status: String?, confidence: String?) -> String? {
    if let s = status, !s.isEmpty { return s }
    if let c = confidence, let v = Double(c) {
      return "置信度 \(Int(v * 100))%"
    }
    return nil
  }

  private func showVoiceRow(_ text: String, secondRow: String?) {
    guard !text.isEmpty else {
      SquirrelVoiceLog.write("showVoiceRow 跳过：text空")
      return
    }
    SquirrelVoiceLog.write("showVoiceRow client=\(voiceClient == nil ? "无" : "有") text=\"\(text.prefix(40))\" secondRow=\(secondRow ?? "nil")")
    if voiceClient != nil {
      // 正常路径：client 可用，走与普通打字完全相同的 showPanel（定位到光标处）。
      let cands: [String] = secondRow != nil ? [text, secondRow!] : [text]
      let cmnts: [String] = Array(repeating: "", count: cands.count)
      voiceShowPanel(candidates: cands, comments: cmnts)
    } else {
      // fallback：client 失效（焦点不在 IME 输入框）。用最后已知光标位置定位面板。
      let pos = voiceHasLastInputPos ? voiceLastInputPos : Self.defaultPanelPosition()
      let cands: [String] = secondRow != nil ? [text, secondRow!] : [text]
      let cmnts: [String] = Array(repeating: "", count: cands.count)
      if let panel = NSApp.squirrelAppDelegate.panel {
        panel.position = pos
        panel.inputController = self
        panel.update(preedit: "", selRange: .empty, caretPos: 0,
                     candidates: cands, comments: cmnts, labels: [],
                     highlighted: 0, page: 0, lastPage: true, update: true)
      }
    }
  }

  /// client 不可用时的默认面板位置（主屏中上区域）。
  private static func defaultPanelPosition() -> NSRect {
    guard let screen = NSScreen.main else { return NSRect(x: 200, y: 400, width: 0, height: 0) }
    let sf = screen.frame
    return NSRect(x: sf.midX - 100, y: sf.midY + 50, width: 0, height: 0)
  }

  // MARK: - 提交 / 丢弃

  /// Enter / 空格 / 点击候选行：把最终文本插入当前输入框（insertText，光标不动、焦点不丢）。
  func voiceCommit() {
    guard voiceReady, !voiceText.isEmpty else { return }
    let text = voiceText
    SquirrelVoiceLog.write("voiceCommit text=\(text) client=\(voiceClient == nil ? "无" : "有")")
    guard voiceClient != nil else {
      // 焦点不在 IME 输入框，无法 insertText；丢弃本次结果。
      resetVoiceState()
      voiceClearStaleComposition(hidePanel: true)
      return
    }
    resetVoiceState()
    voiceClearStaleComposition(hidePanel: true)
    voiceCommitText(text)
    NSApp.squirrelAppDelegate.voiceNative?.reportCommit(text: text)
  }

  /// Esc：丢弃本次语音结果。
  func voiceDiscard() {
    SquirrelVoiceLog.write("voiceDiscard text=\"\(voiceText.prefix(40))\"")
    resetVoiceState()
    voiceClearStaleComposition(hidePanel: true)
  }

  /// internal（非 private）：类体 handle() 的语音按键分支也会调用它，跨文件需可见。
  func resetVoiceState() {
    voiceActive = false
    voiceReady = false
    voiceText = ""
    voiceSessionId = ""
  }
}
