// Vendored from TranscriberKit (github.com/glebis/TranscriberKit), MIT per README.
// Adapted for the Squirrel voice-native module. See VoiceNativeCoordinator.swift.

import Foundation

public enum TranscriberError: Error, Sendable, Equatable {
    case localeNotSupported(String)
    case modelDownloadFailed(String)
    case audioFormatInvalid
    case sessionAlreadyActive
    case noActiveSession
    case audioFileNotFound(String)
    case engineNotReady
    case diarizationFailed(String)
    case bufferConversionFailed(String)

    public var description: String {
        switch self {
        case .localeNotSupported(let locale):
            return "Locale not supported: \(locale)"
        case .modelDownloadFailed(let reason):
            return "Model download failed: \(reason)"
        case .audioFormatInvalid:
            return "Invalid audio format"
        case .sessionAlreadyActive:
            return "A transcription session is already active"
        case .noActiveSession:
            return "No active transcription session"
        case .audioFileNotFound(let path):
            return "Audio file not found: \(path)"
        case .engineNotReady:
            return "Transcription engine not ready"
        case .diarizationFailed(let reason):
            return "Diarization failed: \(reason)"
        case .bufferConversionFailed(let reason):
            return "Buffer conversion failed: \(reason)"
        }
    }
}
