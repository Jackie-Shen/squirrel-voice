// Vendored from TranscriberKit (github.com/glebis/TranscriberKit), MIT per README.
// Adapted for the Squirrel voice-native module. See VoiceNativeCoordinator.swift.

import Foundation

public struct TranscriptionOptions: Sendable {
    public var locale: Locale
    public var enableDiarization: Bool
    public var maxSpeakers: Int
    public var enableVolatileResults: Bool

    public init(
        locale: Locale = Locale(identifier: "en-US"),
        enableDiarization: Bool = true,
        maxSpeakers: Int = 10,
        enableVolatileResults: Bool = true
    ) {
        self.locale = locale
        self.enableDiarization = enableDiarization
        self.maxSpeakers = maxSpeakers
        self.enableVolatileResults = enableVolatileResults
    }

    /// Options suitable for MCP: no volatile results (request/response model)
    public static func forMCP(
        locale: Locale = Locale(identifier: "en-US"),
        enableDiarization: Bool = true,
        maxSpeakers: Int = 10
    ) -> TranscriptionOptions {
        TranscriptionOptions(
            locale: locale,
            enableDiarization: enableDiarization,
            maxSpeakers: maxSpeakers,
            enableVolatileResults: false
        )
    }
}
