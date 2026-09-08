// Vendored from TranscriberKit (github.com/glebis/TranscriberKit), MIT per README.
// Adapted for the Squirrel voice-native module. See VoiceNativeCoordinator.swift.

@preconcurrency import AVFoundation
import Foundation

/// Protocol for audio sources that produce PCM buffers.
/// Implementations: MicrophoneCaptureSource (live), FileCaptureSource (file), MockAudioSource (test)
public protocol AudioCaptureSource: Sendable {
    /// The native audio format of this source.
    var format: AVAudioFormat { get async throws }

    /// Start producing audio buffers.
    func start() -> AsyncThrowingStream<AVAudioPCMBuffer, Error>

    /// Stop producing audio.
    func stop() async
}
