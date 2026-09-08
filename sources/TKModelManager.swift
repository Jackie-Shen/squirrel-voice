// Vendored from TranscriberKit (github.com/glebis/TranscriberKit), MIT per README.
// Adapted for the Squirrel voice-native module. See VoiceNativeCoordinator.swift.

import Foundation
import Speech

/// Protocol abstracting Speech model operations for testability.
public protocol SpeechModelProvider: Sendable {
    func supportedLocales() async -> [Locale]
    func installedLocales() async -> [Locale]
    func reservedLocales() async -> [Locale]
    func downloadIfNeeded(for locale: Locale) async throws -> Progress?
    func reserve(locale: Locale) async throws
    func release(locale: Locale) async
}

/// Default implementation using Apple's SpeechTranscriber + AssetInventory.
@available(macOS 26, *)
public struct SystemSpeechModelProvider: SpeechModelProvider {
    public init() {}

    public func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    public func installedLocales() async -> [Locale] {
        await Array(SpeechTranscriber.installedLocales)
    }

    public func reservedLocales() async -> [Locale] {
        await AssetInventory.reservedLocales
    }

    public func downloadIfNeeded(for locale: Locale) async throws -> Progress? {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        if let downloader = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await downloader.downloadAndInstall()
            return downloader.progress
        }
        return nil
    }

    public func reserve(locale: Locale) async throws {
        try await AssetInventory.reserve(locale: locale)
    }

    public func release(locale: Locale) async {
        await AssetInventory.release(reservedLocale: locale)
    }
}

/// Manages speech recognition model availability, downloading, and locale reservation.
public actor ModelManager {
    private let provider: SpeechModelProvider

    /// Fallback locales to try when the preferred locale isn't available.
    public static let fallbackLocales: [Locale] = [
        Locale(identifier: "en-US"),
        Locale(identifier: "en-GB"),
        Locale(identifier: "en-CA"),
        Locale(identifier: "en-AU"),
        Locale.current,
    ]

    public init(provider: SpeechModelProvider) {
        self.provider = provider
    }

    /// Ensure a model is ready for the given locale.
    /// Downloads if needed, tries fallbacks if the locale isn't supported.
    /// Returns the actual locale that was reserved.
    public func ensureModel(for locale: Locale) async throws -> Locale {
        // Try downloading first
        _ = try await provider.downloadIfNeeded(for: locale)

        // Check if locale is supported
        let supported = await provider.supportedLocales()

        var localeToUse = locale
        if !isLocaleInList(locale, list: supported) {
            // Try fallbacks
            var found = false
            for fallback in Self.fallbackLocales {
                if isLocaleInList(fallback, list: supported) {
                    localeToUse = fallback
                    found = true
                    break
                }
            }
            if !found {
                throw TranscriberError.localeNotSupported(locale.identifier)
            }
        }

        // Reserve the locale
        let reserved = await provider.reservedLocales()
        if !isLocaleInList(localeToUse, list: reserved) {
            try await provider.reserve(locale: localeToUse)
        }

        return localeToUse
    }

    /// List all supported locales.
    public func supportedLocales() async -> [Locale] {
        await provider.supportedLocales()
    }

    /// List installed (downloaded) locales.
    public func installedLocales() async -> [Locale] {
        await provider.installedLocales()
    }

    /// Release all reserved locales.
    public func releaseAll() async {
        let reserved = await provider.reservedLocales()
        for locale in reserved {
            await provider.release(locale: locale)
        }
    }

    private func isLocaleInList(_ locale: Locale, list: [Locale]) -> Bool {
        let targetBCP47 = locale.identifier(.bcp47)
        return list.contains { $0.identifier(.bcp47) == targetBCP47 }
            || list.contains { $0.identifier == locale.identifier }
    }
}
