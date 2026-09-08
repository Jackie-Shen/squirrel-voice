//
//  VoiceNativeHotkeyCombo.swift
//  Squirrel (SquirrelVoice fork)
//
//  热键组合的字符串解析与表示（如 "option+grave"、"cmd+shift+f9"）。
//
//  格式：修饰键+...+按键，用 + 连接。
//  - 修饰键：cmd/command、shift、option/alt/opt、ctrl/control（可多个）
//  - 按键：字母 a-z、数字 0-9、f1-f24、grave/space/tab/enter/esc/delete 等常用键
//  - 至少需要一个修饰键（避免单键全局劫持）
//

import AppKit
import CoreGraphics
import Foundation

struct VoiceNativeHotkeyCombo: Equatable {
  /// 必需的修饰键掩码（CGEventFlags，如 .maskCommand）。
  let modifiers: CGEventFlags
  /// 目标按键的虚拟键码。
  let keyCode: Int64
  /// 规范化字符串（用于回显与存储），如 "option+grave"。
  let display: String

  /// CGEventFlags → NSEvent.ModifierFlags（IME 侧按键回退匹配用）。
  var nsModifierFlags: NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if modifiers.contains(.maskCommand) { f.insert(.command) }
    if modifiers.contains(.maskShift) { f.insert(.shift) }
    if modifiers.contains(.maskAlternate) { f.insert(.option) }
    if modifiers.contains(.maskControl) { f.insert(.control) }
    return f
  }

  /// 解析；成功时 error 为 nil，失败时 combo 为 nil。
  static func parse(_ raw: String) -> (combo: VoiceNativeHotkeyCombo?, error: String?) {
    let parts = raw.lowercased()
      .split(separator: "+")
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard !parts.isEmpty else { return (nil, "热键为空") }

    var mods: CGEventFlags = []
    var keyName: String?
    for p in parts {
      switch p {
      case "cmd", "command": mods.insert(.maskCommand)
      case "shift": mods.insert(.maskShift)
      case "option", "alt", "opt": mods.insert(.maskAlternate)
      case "ctrl", "control": mods.insert(.maskControl)
      default:
        if keyName != nil { return (nil, "格式错误：多个按键（\(raw)）") }
        keyName = p
      }
    }
    guard let key = keyName else { return (nil, "缺少按键（如 option+grave）") }
    guard mods != [] else { return (nil, "至少需要一个修饰键（cmd/shift/option/ctrl）") }
    guard let code = keyCode(for: key) else { return (nil, "无法识别的按键：\(key)") }

    let display = Self.canonical(modifiers: mods, keyName: key)
    return (VoiceNativeHotkeyCombo(modifiers: mods, keyCode: code, display: display), nil)
  }

  /// 修饰键按固定顺序拼回显示串。
  static func canonical(modifiers: CGEventFlags, keyName: String) -> String {
    var names: [String] = []
    if modifiers.contains(.maskCommand) { names.append("cmd") }
    if modifiers.contains(.maskShift) { names.append("shift") }
    if modifiers.contains(.maskAlternate) { names.append("option") }
    if modifiers.contains(.maskControl) { names.append("ctrl") }
    // grave 显示为 ` 更直观（parse 两种写法都认）。
    names.append(keyName == "grave" ? "`" : keyName)
    return names.joined(separator: "+")
  }

  /// ANSI 虚拟键码表（macOS 标准键盘布局）。
  static func keyCode(for name: String) -> Int64? {
    switch name {
    case "grave", "`": return 50
    case "space": return 49
    case "tab": return 48
    case "delete", "backspace": return 51
    case "esc", "escape": return 53
    case "enter", "return": return 36
    case "capslock": return 57
    case "f1": return 122
    case "f2": return 120
    case "f3": return 99
    case "f4": return 118
    case "f5": return 96
    case "f6": return 97
    case "f7": return 98
    case "f8": return 100
    case "f9": return 101
    case "f10": return 109
    case "f11": return 103
    case "f12": return 111
    default: break
    }
    if name.count == 1, let scalar = name.unicodeScalars.first {
      let c = Character(scalar)
      if let code = letterKeyCode(c) { return code }
    }
    return nil
  }

  private static func letterKeyCode(_ c: Character) -> Int64? {
    switch c {
    case "a": return 0
    case "s": return 1
    case "d": return 2
    case "f": return 3
    case "h": return 4
    case "g": return 5
    case "z": return 6
    case "x": return 7
    case "c": return 8
    case "v": return 9
    case "b": return 11
    case "q": return 12
    case "w": return 13
    case "e": return 14
    case "r": return 15
    case "y": return 16
    case "t": return 17
    case "1": return 18
    case "2": return 19
    case "3": return 20
    case "4": return 21
    case "6": return 22
    case "5": return 23
    case "=": return 24
    case "9": return 25
    case "7": return 26
    case "-": return 27
    case "8": return 28
    case "0": return 29
    case "]": return 30
    case "o": return 31
    case "u": return 32
    case "[": return 33
    case "i": return 34
    case "p": return 35
    case "l": return 37
    case "j": return 38
    case "'": return 39
    case "k": return 40
    case ";": return 41
    case "\\": return 42
    case ",": return 43
    case "/": return 44
    case "n": return 45
    case "m": return 46
    case ".": return 47
    default: return nil
    }
  }
}
