// Vendored from TranscriberKit (github.com/glebis/TranscriberKit), MIT per README.
// Adapted for the Squirrel voice-native module. See VoiceNativeCoordinator.swift.

@preconcurrency import AVFoundation
import Foundation
import os

/// Converts AVAudioPCMBuffer between different audio formats.
/// Ported from swift-scribe with UI dependencies removed.
public final class BufferConverter: Sendable {
    public enum Error: Swift.Error, Sendable {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(String?)
    }

    private let lock = OSAllocatedUnfairLock(initialState: ConverterState())

    struct ConverterState: Sendable {
        var converter: AVAudioConverter?
    }

    public init() {}

    /// Convert a buffer to the target format. Returns the same buffer if formats match.
    public func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        to format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else {
            return buffer
        }

        let converter = try lock.withLock { state -> AVAudioConverter in
            if let existing = state.converter, existing.outputFormat == format {
                return existing
            }
            guard let newConverter = AVAudioConverter(from: inputFormat, to: format) else {
                throw Error.failedToCreateConverter
            }
            newConverter.primeMethod = .none
            state.converter = newConverter
            return newConverter
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledInputFrameLength = Double(buffer.frameLength) * sampleRateRatio
        let frameCapacity = AVAudioFrameCount(scaledInputFrameLength.rounded(.up))

        guard
            let conversionBuffer = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat, frameCapacity: frameCapacity)
        else {
            throw Error.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        let bufferProcessedLock = OSAllocatedUnfairLock(initialState: false)

        let status = converter.convert(to: conversionBuffer, error: &nsError) {
            _, inputStatusPointer in
            let wasProcessed = bufferProcessedLock.withLock { bufferProcessed in
                let wasProcessed = bufferProcessed
                bufferProcessed = true
                return wasProcessed
            }
            inputStatusPointer.pointee = wasProcessed ? .noDataNow : .haveData
            return wasProcessed ? nil : buffer
        }

        guard status != .error else {
            throw Error.conversionFailed(nsError?.localizedDescription)
        }

        return conversionBuffer
    }
}
