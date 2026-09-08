//
//  VoiceNativeAudioSource.swift
//  Squirrel (SquirrelVoice fork)
//
//  AVCaptureSession 音频源，实现 TranscriberKit 的 AudioCaptureSource 协议。
//
//  为什么用 AVCaptureSession 而非 AVAudioEngine.installTap：
//  蓝牙麦克风下 installTap 偶发不回调（设备切换/格式协商问题），AVCaptureSession
//  由系统管理音频路由，更稳。TranscriptionSession 内部会用 BufferConverter 把
//  本源的 buffer 转成 SpeechAnalyzer 需要的格式，所以这里只需产出一致的采集格式。
//
//  额外提供 onFloat16k 旁路：把每帧转成 16kHz mono Float，供说话人过滤累积。
//

import AVFoundation
import CoreMedia
import AudioToolbox

final class VoiceNativeAudioSource: NSObject, AudioCaptureSource, @unchecked Sendable {
  private let session = AVCaptureSession()
  /// 指定采集设备 UID；空 = 跟随系统默认输入设备。
  private let deviceUID: String
  private let audioQueue = DispatchQueue(label: "voicenative.capture")
  private var continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation?
  private var configured = false
  /// 采集格式（start 后有效）。
  private var captureFormat: AVAudioFormat?
  /// 首帧诊断日志只记一次（audioQueue 上读写）。
  fileprivate var firstFrameLogged = false

  /// 16kHz mono Float 旁路回调（说话人过滤累积用）。
  nonisolated(unsafe) var onFloat16k: (([Float]) -> Void)?

  enum CaptureError: Error { case noDevice, noInput, noOutput }

  init(deviceUID: String = "") {
    self.deviceUID = deviceUID
    super.init()
    // 静默失败定位：运行时错误/中断都会以通知形式来，记日志。
    ncTokens = [
      NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { note in
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
        SquirrelVoiceLog.write("AudioSource runtimeError: \(err?.localizedDescription ?? "?") code=\(err?.errorCode ?? -1)")
      },
      NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { note in
        let reason = note.userInfo?["AVCaptureSessionInterruptionReasonKey"] ?? "?"
        SquirrelVoiceLog.write("AudioSource 被中断 reason=\(reason)")
      },
      NotificationCenter.default.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { _ in
        SquirrelVoiceLog.write("AudioSource 中断结束")
      },
    ]
  }

  private var ncTokens: [NSObjectProtocol] = []

  deinit {
    stopInternal()
    ncTokens.forEach { NotificationCenter.default.removeObserver($0) }
  }

  nonisolated var format: AVAudioFormat {
    get async throws {
      if let f = captureFormat { return f }
      // 未 start 时给一个合理的默认（48kHz mono float32），TranscriptionSession 会转换。
      guard let f = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else {
        throw CaptureError.noDevice
      }
      return f
    }
  }

  nonisolated func start() -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
    AsyncThrowingStream { continuation in
      self.continuation = continuation
      self.audioQueue.async {
        do {
          try self.configureAndStart()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { [weak self] _ in
        self?.audioQueue.async { self?.stopInternal() }
      }
    }
  }

  nonisolated func stop() async {
    audioQueue.async {
      self.stopInternal()
      // 必须结束流：否则 TranscriptionSession 的 feedingTask 永远挂在 for-await 上，
      // analyzer 等不到输入结束，.ended 永不发出，上层 isRecording 卡死。
      self.continuation?.finish()
      self.continuation = nil
    }
  }

  // MARK: - 内部（audioQueue 上执行）

  private func configureAndStart() throws {
    guard !configured else { return }
    session.beginConfiguration()
    session.sessionPreset = .high
    guard let device = VoiceNativeAudioDevices.resolveDevice(uid: deviceUID) else {
      throw CaptureError.noDevice
    }
    let srcLabel = deviceUID.isEmpty ? "系统默认" : "指定"
    SquirrelVoiceLog.write("AudioSource 采集设备：\(device.localizedName)（\(srcLabel)）")
    guard let input = try? AVCaptureDeviceInput(device: device) else {
      SquirrelVoiceLog.write("AudioSource AVCaptureDeviceInput 创建失败（设备不可用于采集？）")
      session.commitConfiguration()
      throw CaptureError.noInput
    }
    let canIn = session.canAddInput(input)
    if canIn { session.addInput(input) }
    let output = AVCaptureAudioDataOutput()
    output.setSampleBufferDelegate(self, queue: audioQueue)
    let canOut = session.canAddOutput(output)
    if canOut { session.addOutput(output) } else {
      SquirrelVoiceLog.write("AudioSource canAddOutput=false，无法添加采集输出")
      session.commitConfiguration()
      throw CaptureError.noOutput
    }
    session.commitConfiguration()
    SquirrelVoiceLog.write("AudioSource 配置：canAddInput=\(canIn) canAddOutput=\(canOut) 输入=\(String(describing: session.inputs.first))")
    configured = true
    // 采集格式：优先 48kHz mono float32（系统可协商），否则设备原生。
    if let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) {
      captureFormat = fmt
    }
    session.startRunning()
    SquirrelVoiceLog.write("AudioSource 采集启动 isRunning=\(session.isRunning)")
    if !session.isRunning {
      SquirrelVoiceLog.write("AudioSource startRunning 后 isRunning=false（设备被占用/无权限/硬件拒绝）")
    }
  }

  private func stopInternal() {
    if session.isRunning { session.stopRunning() }
    SquirrelVoiceLog.write("AudioSource 采集停止")
  }
}

/// 音频输入设备枚举/解析（AVCaptureDevice.uniqueID 与 CoreAudio DeviceUID 一致）。
enum VoiceNativeAudioDevices {
  /// 所有音频输入设备（uid, 显示名）。
  static func inputDevices() -> [(uid: String, name: String)] {
    AVCaptureDevice.devices(for: .audio).map { ($0.uniqueID, $0.localizedName) }
  }

  /// 系统默认输入设备 UID（= 系统设置 → 声音 → 输入 里选中的那个）。
  static func systemDefaultUID() -> String? {
    var aid = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &aid) == noErr, aid != 0
    else { return nil }
    var uidRef: CFString?
    var uidSize = UInt32(MemoryLayout<CFString?>.size)
    var uidAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(aid, &uidAddr, 0, nil, &uidSize, &uidRef) == noErr else { return nil }
    return uidRef as String?
  }

  /// 按配置 UID 解析采集设备：指定设备在线 → 用它；否则跟随系统默认输入；再兜底 AVCapture 默认。
  static func resolveDevice(uid: String) -> AVCaptureDevice? {
    let devices = AVCaptureDevice.devices(for: .audio)
    if !uid.isEmpty, let hit = devices.first(where: { $0.uniqueID == uid }) { return hit }
    if let defUID = systemDefaultUID(), let hit = devices.first(where: { $0.uniqueID == defUID }) { return hit }
    return AVCaptureDevice.default(for: .audio)
  }
}

extension VoiceNativeAudioSource: AVCaptureAudioDataOutputSampleBufferDelegate {
  // 在 audioQueue 上回调。
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    if !firstFrameLogged {
      firstFrameLogged = true
      if let desc = CMSampleBufferGetFormatDescription(sampleBuffer) {
        let fmt = AVAudioFormat(cmAudioFormatDescription: desc)
        SquirrelVoiceLog.write("AudioSource 首帧到达：\(Int(fmt.sampleRate))Hz \(Int(fmt.channelCount))ch \(CMSampleBufferGetNumSamples(sampleBuffer))帧")
      }
    }
    guard let buf = Self.pcmBuffer(from: sampleBuffer) else { return }
    continuation?.yield(buf)
    if let cb = onFloat16k {
      if let f16k = Self.float16k(from: buf) { cb(f16k) }
    }
  }

  // MARK: - CMSampleBuffer → AVAudioPCMBuffer

  static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    convert(sampleBuffer)
  }

  /// 将 CMSampleBuffer（LinearPCM）直接拷贝为 AVAudioPCMBuffer。
  /// AVCaptureAudioDataOutput 交付的是未压缩 PCM，无需 AVAudioConverter；
  /// 采样率/声道转换由 TranscriptionSession 内部的 BufferConverter 完成。
  private static func convert(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
    let inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDesc)
    // 只支持 float32 / int16（macOS 麦克风采集实际交付 float32）。
    guard inputFormat.commonFormat == .pcmFormatFloat32 || inputFormat.commonFormat == .pcmFormatInt16 else {
      return nil
    }
    let isFloat = inputFormat.commonFormat == .pcmFormatFloat32
    let bytesPerSample = isFloat ? 4 : 2
    let channels = Int(inputFormat.channelCount)
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frameCount > 0 else { return nil }

    // 输出统一为非交错布局。
    guard let outFormat = AVAudioFormat(
      commonFormat: isFloat ? .pcmFormatFloat32 : .pcmFormatInt16,
      sampleRate: inputFormat.sampleRate,
      channels: inputFormat.channelCount,
      interleaved: false
    ), let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
      return nil
    }

    // AudioBufferList 大小随声道数变化（非交错每通道一个 buffer）：
    // 固定栈上 1 个槽的写法对 2 声道 USB 麦克风（如 DJI 无线麦）会直接报错、
    // 整帧被丢 → 采集 0 样本。先问需要多大，再动态分配。
    var neededSize = 0
    var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: &neededSize,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: nil)
    guard status == noErr, neededSize > 0 else { return nil }
    let storage = UnsafeMutableRawPointer.allocate(
      byteCount: neededSize, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    let ablPtr = storage.assumingMemoryBound(to: AudioBufferList.self)
    var blockBuffer: CMBlockBuffer?
    status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: ablPtr,
      bufferListSize: neededSize,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: &blockBuffer)
    guard status == noErr else { return nil }
    _ = blockBuffer  // 数据有效性由 blockBuffer 保活（作用域内拷贝进 pcmBuffer）

    let ablPointer = UnsafeMutableAudioBufferListPointer(ablPtr)
    // 交错布局只有一个 buffer（含全部通道）；非交错每通道一个。
    let interleaved = (ablPointer.count == 1 && channels > 1)
    let bytesPerFrame = bytesPerSample * channels
    let totalBytes = Int(frameCount) * bytesPerFrame

    let floatPtrs = pcmBuffer.floatChannelData
    let int16Ptrs = pcmBuffer.int16ChannelData

    for ch in 0..<channels {
      // 目标通道数据指针（floatChannelData/int16ChannelData 是通道指针数组）。
      let destChannel: UnsafeMutableRawPointer
      if isFloat {
        guard let fp = floatPtrs else { return nil }
        destChannel = UnsafeMutableRawPointer(fp[ch])
      } else {
        guard let ip = int16Ptrs else { return nil }
        destChannel = UnsafeMutableRawPointer(ip[ch])
      }
      let bufIndex = interleaved ? 0 : ch
      guard bufIndex < ablPointer.count else { return nil }
      let srcBuf = ablPointer[bufIndex]
      let copyBytes = min(Int(srcBuf.mDataByteSize), totalBytes)
      guard copyBytes > 0, let srcPtr = srcBuf.mData else { continue }
      if interleaved {
        for frame in 0..<Int(frameCount) {
          destChannel
            .advanced(by: frame * bytesPerSample)
            .copyMemory(from: srcPtr.advanced(by: frame * bytesPerFrame), byteCount: bytesPerSample)
        }
      } else {
        destChannel.copyMemory(from: srcPtr, byteCount: copyBytes)
      }
    }
    pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
    return pcmBuffer
  }

  // MARK: - AVAudioPCMBuffer → 16kHz mono Float

  static func float16k(from buffer: AVAudioPCMBuffer) -> [Float]? {
    guard let channelData = buffer.floatChannelData else { return nil }
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return nil }
    var mono = [Float](repeating: 0, count: frameCount)
    for i in 0..<frameCount { mono[i] = channelData[0][i] }
    return downsampleTo16k(mono, sourceRate: buffer.format.sampleRate)
  }

  /// 把任意采样率的 mono Float 降采样到 16kHz（简单抽取，无抗混叠滤波）。
  ///
  /// 关键：FluidAudio 的 `extractSpeakerEmbedding` / `performCompleteDiarization` 都假设
  /// 输入是 16kHz（embedding 模型固定吃 160_000 采样 = 16kHz×10s，不重采样）。所以
  /// 【声纹注册】和【说话人过滤】两条路径必须用同一套降采样，否则声纹与过滤 embedding
  /// 来自不同采样率的音频 → 余弦相似度永远偏低 → 判不出本人（曾经的 bug：注册按原生
  /// 48kHz 采集没降采样，声纹是错的）。此函数供两条路径复用，保证一致。
  static func downsampleTo16k(_ samples: [Float], sourceRate: Double) -> [Float] {
    guard !samples.isEmpty, sourceRate > 0 else { return [] }
    let ratio = sourceRate / 16000.0
    let targetCount = Int(Double(samples.count) / ratio)
    var out = [Float](repeating: 0, count: max(targetCount, 1))
    for i in 0..<targetCount {
      let srcFrame = Int(Double(i) * ratio)
      if srcFrame < samples.count { out[i] = samples[srcFrame] }
    }
    return out
  }
}
