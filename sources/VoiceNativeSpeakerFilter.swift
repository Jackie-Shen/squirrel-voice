//
//  VoiceNativeSpeakerFilter.swift
//  Squirrel (SquirrelVoice fork)
//
//  FluidAudio 离线说话人过滤（松手后执行，可选功能）。
//
//  设计（用 FluidAudio DiarizerManager）：
//  - 注册：录一段本人语音 → 走与过滤完全相同的 performCompleteDiarization 分段路径，
//    取「最长段」（并列取质量分高者）的 256 维 L2 归一化 embedding 作为「我」声纹，
//    存 ~/.squirrelvoice/voiceprint_native.json（带版本号，权限 600）。
//    不用 extractSpeakerEmbedding（整段全 1 mask）：会把静音平均进去，长录音下声纹被稀释。
//  - 过滤：结束录音后对整段录音 performCompleteDiarization → 每个 TimedSpeakerSegment 的
//    embedding 与「我」声纹算余弦相似度，≥ 阈值判为本人 → 合并成「我的时间区间」。
//  - 协调器用这些区间对齐 SpeechAnalyzer 转写段（audioTimeRange），只保留本人文字。
//
//  模型：CoreML（pyannote_segmentation 分段 + wespeaker_v2 声纹嵌入），已打包进 app
//  （resources/models/，随构建拷贝到 Contents/Resources），本地加载、全程离线。
//

import Foundation
import FluidAudio

final class VoiceNativeSpeakerFilter {
  /// 余弦相似度阈值：≥ 此值判为本人。本人通常 0.6~0.8，旁人 ≤ 0.5。
  var similarityThreshold: Float = 0.55

  private var diarizer: DiarizerManager?
  private var myEmbedding: [Float]?
  private let stateQueue = DispatchQueue(label: "voicenative.speaker")
  private(set) var isModelReady = false

  // MARK: - 声纹持久化（~/.squirrelvoice/voiceprint_native.json）

  /// 声纹文件格式：带版本号。旧版（纯 [Float] 数组 / v1）是用原生采样率（48kHz）注册的，
  /// 声纹错误（FluidAudio 模型只认 16kHz），必须作废强制重录。
  private struct VoiceprintFile: Codable {
    let version: Int
    let embedding: [Float]
  }

  /// 当前声纹版本。
  /// v2 = 16kHz 降采样修复（但注册用整段全 1 mask，长录音被静音稀释 → 本人 sim 掉到 ~0）。
  /// v3 = 注册改用「与过滤相同的 diarization 分段路径」取最长段 embedding，声纹与过滤段同空间，
  ///      相似度才可靠。旧 v2 作废强制重录。
  static let currentVoiceprintVersion = 3

  static func voiceprintURL() -> URL {
    VoiceNativeCredentials.dir().appendingPathComponent("voiceprint_native.json")
  }

  var hasVoiceprint: Bool {
    stateQueue.sync { myEmbedding != nil }
  }

  /// 从磁盘加载声纹（启动时调用）。版本不符（旧版错误采样率）→ 作废，需重新注册。
  func loadVoiceprint() {
    let url = Self.voiceprintURL()
    guard let data = try? Data(contentsOf: url) else { return }
    // 新格式：{ version, embedding }
    if let fp = try? JSONDecoder().decode(VoiceprintFile.self, from: data) {
      if fp.version == Self.currentVoiceprintVersion {
        stateQueue.sync { myEmbedding = fp.embedding }
        SquirrelVoiceLog.write("SpeakerFilter 声纹已加载（\(fp.embedding.count) 维，v\(fp.version)）")
      } else {
        invalidate(url, reason: "版本 v\(fp.version) ≠ 当前 v\(Self.currentVoiceprintVersion)")
      }
      return
    }
    // 兼容最老的纯数组格式（那也是错误采样率的 v1）→ 作废
    if (try? JSONDecoder().decode([Float].self, from: data)) != nil {
      invalidate(url, reason: "旧版纯数组格式（采样率错误）")
    }
  }

  /// 作废旧声纹：清内存 + 删文件，提示重新注册。
  private func invalidate(_ url: URL, reason: String) {
    stateQueue.sync { myEmbedding = nil }
    try? FileManager.default.removeItem(at: url)
    SquirrelVoiceLog.write("SpeakerFilter 声纹已作废（\(reason)），请在设置里重新注册")
  }

  func clearVoiceprint() {
    stateQueue.sync { myEmbedding = nil }
    try? FileManager.default.removeItem(at: Self.voiceprintURL())
    SquirrelVoiceLog.write("SpeakerFilter 声纹已清除")
  }

  // MARK: - 模型准备（本地加载内置 CoreML，离线）

  @discardableResult
  func prepareModels() async -> (Bool, String?) {
    if isModelReady { return (true, nil) }
    do {
      // 模型已打包进 app（resources/models/，随构建拷贝到 Contents/Resources），
      // 本地加载、全程离线——不再走 Hugging Face 下载（国内网络常超时）。
      guard let segURL = Bundle.main.url(forResource: "pyannote_segmentation", withExtension: "mlmodelc"),
            let embURL = Bundle.main.url(forResource: "wespeaker_v2", withExtension: "mlmodelc") else {
        let msg = "未找到内置声纹模型（pyannote_segmentation / wespeaker_v2）"
        SquirrelVoiceLog.write("SpeakerFilter \(msg)")
        return (false, msg)
      }
      // MLModel 编译可能耗时，放到后台线程，避免卡住主线程 UI。
      let models = try await Task.detached(priority: .userInitiated) {
        try DiarizerModels.load(localSegmentationModel: segURL, localEmbeddingModel: embURL)
      }.value
      let d = DiarizerManager(config: DiarizerConfig())
      d.initialize(models: models)
      diarizer = d
      isModelReady = true
      SquirrelVoiceLog.write("SpeakerFilter 模型就绪（本地加载，离线）")
      return (true, nil)
    } catch {
      let msg = error.localizedDescription
      SquirrelVoiceLog.write("SpeakerFilter 模型准备失败：\(msg)")
      return (false, msg)
    }
  }

  // MARK: - 注册（录入「我」的声音）

  @discardableResult
  func enroll(fromAudio16k samples: [Float]) async -> (Bool, String?, Int) {
    guard samples.count > 16000 else {   // 至少 1 秒
      return (false, "录音太短（<1s）", 0)
    }
    let (ok, err) = await prepareModels()
    guard ok, let d = diarizer else {
      return (false, err ?? "模型未就绪", 0)
    }
    do {
      // 关键：用「和过滤完全相同」的 diarization 分段路径提取声纹，而不是
      // extractSpeakerEmbedding（整段全 1 mask）。后者把开头静音/停顿一起平均进去，
      // 长录音时 embedding 被稀释 → 与过滤段不在同一质量水平 → 本人 sim 掉到 ~0。
      // 取「最长的一段」（最可能是你清晰连续说话）的 embedding 当声纹，保证与过滤段同算法同空间。
      let totalSecs = Double(samples.count) / 16000.0
      SquirrelVoiceLog.write("SpeakerFilter [诊断] enroll 输入：\(samples.count) 采样 = \(String(format: "%.2f", totalSecs))s @16kHz")
      let result = try d.performCompleteDiarization(samples, sampleRate: 16000)
      guard !result.segments.isEmpty else {
        SquirrelVoiceLog.write("SpeakerFilter [诊断] enroll：diarization 未产出任何段（整段被判为静音？）")
        return (false, "未检测到有效语音（请对着麦克风清晰说话）", 0)
      }
      // 逐段诊断：时长 / 质量分 / embedding 维度与 L2 范数。
      var segDesc: [String] = []
      for (i, seg) in result.segments.enumerated() {
        let norm = Self.l2Norm(seg.embedding)
        segDesc.append(String(format: "#\(i)[%.2f-%.2fs q=%.2f dim=%d |v|=%.3f]",
                              seg.startTimeSeconds, seg.endTimeSeconds, seg.qualityScore,
                              seg.embedding.count, norm))
      }
      SquirrelVoiceLog.write("SpeakerFilter [诊断] enroll 分段（共 \(result.segments.count)）：\(segDesc.joined(separator: " "))")
      // 选最长段；并列时取 qualityScore 更高者。
      let best = result.segments.max { a, b in
        if a.durationSeconds != b.durationSeconds { return a.durationSeconds < b.durationSeconds }
        return a.qualityScore < b.qualityScore
      }!
      let emb = best.embedding
      guard !emb.isEmpty else { return (false, "无法提取声纹", 0) }
      // 关键自检：声纹（=best 段）与录音里「每一段」的余弦相似度。
      // 若你独自连续说话，各段都应高相似（都是你）；若出现低值 → 有背景音/分段不一致。
      var selfSims: [String] = []
      for (i, seg) in result.segments.enumerated() {
        let s = Self.cosineSimilarity(emb, seg.embedding)
        selfSims.append(String(format: "#\(i)=%.3f", s))
      }
      SquirrelVoiceLog.write("SpeakerFilter [诊断] 声纹(取自 \(String(format: "%.2f", best.startTimeSeconds))-\(String(format: "%.2f", best.endTimeSeconds))s q=\(String(format: "%.2f", best.qualityScore))) vs 各段 sim：\(selfSims.joined(separator: " "))")
      // 【对照实验】用 extractSpeakerEmbedding（整段全 1 mask，绕过 diarization）算"整段声纹"，
      // 对比它和 diarization 声纹的 sim。若两者高 → 问题在 diarization 短段；若也低 → 音频/模型层面。
      do {
        let wholeEmb = try d.extractSpeakerEmbedding(from: samples)
        let s = Self.cosineSimilarity(emb, wholeEmb)
        SquirrelVoiceLog.write("SpeakerFilter [对照] 整段embedding vs diarization声纹 sim=\(String(format: "%.3f", s))（整段|v|=\(String(format: "%.3f", Self.l2Norm(wholeEmb)))）")
      } catch {
        SquirrelVoiceLog.write("SpeakerFilter [对照] extractSpeakerEmbedding 失败：\(error.localizedDescription)")
      }
      stateQueue.sync { myEmbedding = emb }
      // 持久化（带版本号，权限 600）
      let file = VoiceprintFile(version: Self.currentVoiceprintVersion, embedding: emb)
      let data = try JSONEncoder().encode(file)
      try VoiceNativeCredentials.saveDirIfNeeded()
      try data.write(to: Self.voiceprintURL(), options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                             ofItemAtPath: Self.voiceprintURL().path)
      SquirrelVoiceLog.write("SpeakerFilter 注册成功（\(emb.count) 维，v\(Self.currentVoiceprintVersion)，取自 \(String(format: "%.1f", best.durationSeconds))s 段，|v|=\(String(format: "%.3f", Self.l2Norm(emb)))）")
      return (true, nil, 1)
    } catch {
      SquirrelVoiceLog.write("SpeakerFilter 注册失败：\(error.localizedDescription)")
      return (false, error.localizedDescription, 0)
    }
  }

  // MARK: - 过滤（松手后）

  /// 过滤结果：本人时间区间 + 全段最高相似度（供调用方判断"是否完全没你"）。
  struct FilterResult {
    let myRanges: [(start: Float, end: Float)]
    let maxSimilarity: Float
  }

  /// 对整段录音做 diarization，返回「我的时间区间」+ 全段最高相似度（秒，相对录音起点）。
  /// 未注册声纹或模型未就绪时返回 nil（调用方跳过过滤，保留全部文本）。
  func myTimeRanges(fromAudio16k samples: [Float]) async -> FilterResult? {
    let emb = stateQueue.sync { myEmbedding }
    guard let myEmb = emb, !myEmb.isEmpty else { return nil }
    guard samples.count > 16000 else { return nil }
    let (ok, _) = await prepareModels()
    guard ok, let d = diarizer else { return nil }
    do {
      let totalSecs = Double(samples.count) / 16000.0

      // 【关键】整段 embedding（全 1 mask）是"我是否在这段音频里"的可靠信号。
      // 实测：本人短句 diarization 短段 sim 只有 0.1~0.3（不可靠 → 误清空，"一闪就没"），
      // 但整段法稳定 0.77~0.85。所以用整段法做主判断，diarization 段只用于多人时定位"我在哪"。
      var wholeSim: Float = -1
      do {
        let wholeEmb = try d.extractSpeakerEmbedding(from: samples)
        wholeSim = Self.cosineSimilarity(myEmb, wholeEmb)
      } catch {
        SquirrelVoiceLog.write("SpeakerFilter 整段embedding失败：\(error.localizedDescription)")
      }

      // diarization 分段（多人时定位本人区间；短句场景段不可靠，仅作辅助）。
      let result = try d.performCompleteDiarization(samples, sampleRate: 16000)
      var mySegs: [(Float, Float)] = []
      var segMaxSim: Float = -1
      for seg in result.segments {
        let sim = Self.cosineSimilarity(myEmb, seg.embedding)
        segMaxSim = Swift.max(segMaxSim, sim)
        if sim >= similarityThreshold {
          mySegs.append((seg.startTimeSeconds, seg.endTimeSeconds))
        }
      }

      // 综合最高相似度：整段法（可靠）与段法的较大者，供协调器判断"是否完全没你"。
      let maxSim = Swift.max(wholeSim, segMaxSim)

      var merged: [(Float, Float)]
      if wholeSim >= similarityThreshold {
        // 整段法确认"我在这段里"（可靠）。
        if !mySegs.isEmpty {
          // 有可靠的长段 → 用段区间精确定位（多人场景剔除旁人段）。
          merged = Self.mergeRanges(mySegs, gap: 0.5)
        } else {
          // 短句场景：diarization 段都不可靠（sim 低）→ 整段都算我，不冒险删你说的话。
          merged = [(0, Float(totalSecs))]
        }
      } else {
        // 整段法没确认是我 → 退回段法（可能整段是旁人）。
        merged = Self.mergeRanges(mySegs, gap: 0.5)
      }

      SquirrelVoiceLog.write("SpeakerFilter 过滤：整段sim=\(String(format: "%.3f", wholeSim)) 段最高sim=\(String(format: "%.3f", segMaxSim)) 录音\(String(format: "%.2f", totalSecs))s → \(merged.count) 区间（阈值 \(similarityThreshold)）")
      return FilterResult(myRanges: merged, maxSimilarity: maxSim)
    } catch {
      SquirrelVoiceLog.write("SpeakerFilter 过滤失败：\(error.localizedDescription)")
      return nil
    }
  }

  /// 「明显不是本人」的相似度下限：0 段本人且全段最高 sim 低于此值 → 判定整段都是旁人。
  /// 实测本人长段 sim 0.64~0.72、旁人 ≤0.12，中间空档巨大，取 0.3 作安全分界。
  static let notMeFloor: Float = 0.3

  // MARK: - 工具

  /// 余弦相似度（两向量须同维；不同维返回 0）。
  static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in a.indices {
      dot += a[i] * b[i]
      na += a[i] * a[i]
      nb += b[i] * b[i]
    }
    let denom = (na * nb).squareRoot()
    guard denom > 0 else { return 0 }
    return dot / denom
  }

  /// L2 范数（向量长度）。诊断用：对比声纹与各段 embedding 的量级是否一致。
  static func l2Norm(_ v: [Float]) -> Float {
    var s: Float = 0
    for x in v { s += x * x }
    return s.squareRoot()
  }

  /// 合并重叠或间隔 < gap 的区间。
  static func mergeRanges(_ ranges: [(Float, Float)], gap: Float) -> [(start: Float, end: Float)] {
    guard !ranges.isEmpty else { return [] }
    let sorted = ranges.sorted { $0.0 < $1.0 }
    var merged: [(Float, Float)] = [sorted[0]]
    for r in sorted.dropFirst() {
      let last = merged[merged.count - 1]
      if r.0 <= last.1 + gap {
        merged[merged.count - 1] = (last.0, Swift.max(last.1, r.1))
      } else {
        merged.append(r)
      }
    }
    return merged.map { (start: $0.0, end: $0.1) }
  }
}

extension VoiceNativeCredentials {
  /// 确保 ~/.squirrelvoice 目录存在（供声纹文件写入）。
  static func saveDirIfNeeded() throws {
    try FileManager.default.createDirectory(at: dir(), withIntermediateDirectories: true)
  }
}
