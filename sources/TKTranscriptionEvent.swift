// Vendored from TranscriberKit (github.com/glebis/TranscriberKit), MIT per README.
// Adapted for the Squirrel voice-native module. See VoiceNativeCoordinator.swift.

import Foundation

/// Minimal speaker segment (diarization result). We do not emit .diarization events
/// (speaker filtering is done separately via FluidAudio), but the type must exist
/// for TranscriptionEvent's Codable conformance.
public struct SpeakerSegment: Sendable, Codable, Equatable {
    public var speakerId: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public init(speakerId: Int, startTime: TimeInterval = 0, endTime: TimeInterval = 0) {
        self.speakerId = speakerId
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Events emitted by a transcription session via AsyncStream.
/// Consumed by CLI (prints live) and MCP (buffers until stop).
public enum TranscriptionEvent: Sendable, Codable, Equatable {
    /// Intermediate result that may change (CLI shows these, MCP ignores)
    case volatile(VolatileResult)
    /// Finalized segment that won't change
    case final_(FinalResult)
    /// Speaker diarization result (post-processing)
    case diarization([SpeakerSegment])
    /// Session has ended
    case ended(EndReason)

    public struct VolatileResult: Sendable, Codable, Equatable {
        public var text: String
        public var timestamp: TimeInterval
        public init(text: String, timestamp: TimeInterval = 0) {
            self.text = text
            self.timestamp = timestamp
        }
    }

    public struct FinalResult: Sendable, Codable, Equatable {
        public var text: String
        public var startTime: TimeInterval
        public var endTime: TimeInterval
        public init(text: String, startTime: TimeInterval = 0, endTime: TimeInterval = 0) {
            self.text = text
            self.startTime = startTime
            self.endTime = endTime
        }
    }

    public enum EndReason: Sendable, Codable, Equatable {
        case completed
        case cancelled
        case error(String)
    }

    /// Returns the transcript text for progress reporting, or nil for non-text events.
    public var progressMessage: String? {
        switch self {
        case .volatile(let r): return r.text
        case .final_(let r): return r.text
        case .diarization, .ended: return nil
        }
    }

    // Custom CodingKeys for the enum
    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private enum EventType: String, Codable {
        case volatile, final_, diarization, ended
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .volatile(let result):
            try container.encode(EventType.volatile, forKey: .type)
            try container.encode(result, forKey: .payload)
        case .final_(let result):
            try container.encode(EventType.final_, forKey: .type)
            try container.encode(result, forKey: .payload)
        case .diarization(let segments):
            try container.encode(EventType.diarization, forKey: .type)
            try container.encode(segments, forKey: .payload)
        case .ended(let reason):
            try container.encode(EventType.ended, forKey: .type)
            try container.encode(reason, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)
        switch type {
        case .volatile:
            self = .volatile(try container.decode(VolatileResult.self, forKey: .payload))
        case .final_:
            self = .final_(try container.decode(FinalResult.self, forKey: .payload))
        case .diarization:
            self = .diarization(try container.decode([SpeakerSegment].self, forKey: .payload))
        case .ended:
            self = .ended(try container.decode(EndReason.self, forKey: .payload))
        }
    }
}
