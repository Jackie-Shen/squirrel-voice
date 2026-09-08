//
//  SquirrelVoiceLog.swift
//  Squirrel (SquirrelVoice fork)
//
//  SquirrelVoice 诊断日志（语音模块专用工具类）。
//
//  输入法进程的 NSLog 在统一日志里不可见，直接追加写 ~/.squirrelvoice/squirrel-voicenative.log
//  便于排查候选窗问题（与其他用户数据同目录，卸载时可一并清理）。串行队列保证多来源写入不乱行。
//

import Foundation

enum SquirrelVoiceLog {
  private static let url: URL = {
    let dir = VoiceNativeCredentials.dir()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("squirrel-voicenative.log")
  }()
  private static let queue = DispatchQueue(label: "squirrelvoice.log")

  static func write(_ message: String) {
    let line = "\(Date()) [pid \(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
    queue.async {
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        handle.write(line.data(using: .utf8)!)
      } else {
        try? line.data(using: .utf8)!.write(to: url)
      }
    }
  }
}
