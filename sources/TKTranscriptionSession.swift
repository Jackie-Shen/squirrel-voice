// Vendored from TranscriberKit (github.com/glebis/TranscriberKit), MIT per README.
// Adapted for the Squirrel voice-native module. See VoiceNativeCoordinator.swift.

@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Wires an AudioCaptureSource through SpeechAnalyzer to produce TranscriptionEvents.
/// This is the core transcription pipeline, consumed by TranscriptionEngine.
public actor TranscriptionSession {
    private let source: AudioCaptureSource
    private let options: TranscriptionOptions
    private let converter = BufferConverter()

    private var analyzerTask: Task<Void, any Error>?
    private var feedTask: Task<Void, any Error>?

    public enum State: Sendable {
        case idle
        case running
        case stopping
        case finished
    }

    private(set) public var state: State = .idle

    public init(source: AudioCaptureSource, options: TranscriptionOptions) {
        self.source = source
        self.options = options
    }

    /// Start the session. Returns a stream of TranscriptionEvents.
    @available(macOS 26, *)
    public func start() -> AsyncStream<TranscriptionEvent> {
        guard state == .idle else {
            return AsyncStream { $0.finish() }
        }
        state = .running

        let (stream, continuation) = AsyncStream<TranscriptionEvent>.makeStream()
        let opts = options
        let src = source
        let conv = converter

        // Launch the pipeline
        analyzerTask = Task {
            do {
                let locale = opts.locale
                // 用「渐进式 + 时间戳」预设：只设 .volatileResults 时引擎走慢路径，
                // 把结果全堆到 finalize（松手）才出，按住期间无实时预览。progressive 预设
                // 带 .fastResults 低延迟出结果 → 边说边出 partial；timeIndexed 提供
                // audioTimeRange，说话人过滤的时间戳对齐依赖它。
                let transcriber = SpeechTranscriber(
                    locale: locale,
                    preset: .timeIndexedProgressiveTranscription
                )

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber]
                )

                guard let analyzerFormat else {
                    continuation.yield(.ended(.error("No compatible audio format")))
                    continuation.finish()
                    return
                }

                // Feed audio from source to analyzer via AsyncStream
                let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

                // Start feeding audio buffers
                let feedingTask = Task {
                    do {
                        for try await buffer in src.start() {
                            let converted = try conv.convertBuffer(buffer, to: analyzerFormat)
                            inputContinuation.yield(AnalyzerInput(buffer: converted))
                        }
                        inputContinuation.finish()
                    } catch {
                        inputContinuation.finish()
                        throw error
                    }
                }

                // Start receiving transcription results
                let resultsTask = Task {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            let (start, end) = Self.extractTimeRange(from: result.text)
                            continuation.yield(.final_(.init(
                                text: text,
                                startTime: start,
                                endTime: end
                            )))
                        } else {
                            let (start, _) = Self.extractTimeRange(from: result.text)
                            continuation.yield(.volatile(.init(
                                text: text,
                                timestamp: start
                            )))
                        }
                    }
                }

                // Start the analyzer
                try await analyzer.start(inputSequence: inputStream)

                // Wait for feed to complete
                try await feedingTask.value

                // Finalize
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                // 等 resultsTask 消费完最后一条 final 结果再发 .ended：
                // finalize 只把结果推进 transcriber.results 流，resultsTask 是独立任务，
                // 立即 cancel 会丢掉尚未 yield 的最后一段（上层 final 文本为空）。
                // results 流在 finalize 后应自然结束；2s 超时兜底防挂起。
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { _ = try? await resultsTask.value }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        resultsTask.cancel()
                    }
                    _ = await group.next()
                    group.cancelAll()
                }

                continuation.yield(.ended(.completed))
                continuation.finish()

            } catch is CancellationError {
                continuation.yield(.ended(.cancelled))
                continuation.finish()
            } catch {
                continuation.yield(.ended(.error(error.localizedDescription)))
                continuation.finish()
            }
        }

        return stream
    }

    /// Extract overall start/end time from an AttributedString's audioTimeRange runs.
    @available(macOS 26, *)
    private static func extractTimeRange(from text: AttributedString) -> (start: TimeInterval, end: TimeInterval) {
        var earliest: TimeInterval = .infinity
        var latest: TimeInterval = 0

        for run in text.runs {
            if let timeRange = run.audioTimeRange {
                let start = CMTimeGetSeconds(timeRange.start)
                let end = CMTimeGetSeconds(timeRange.end)
                if start.isFinite { earliest = min(earliest, start) }
                if end.isFinite { latest = max(latest, end) }
            }
        }

        if earliest == .infinity { earliest = 0 }
        return (earliest, latest)
    }

    /// Stop the session.
    public func stop() async {
        guard state == .running else { return }
        state = .stopping
        await source.stop()
        analyzerTask?.cancel()
        feedTask?.cancel()
        state = .finished
    }
}

/// Lightweight session for testing without Speech framework.
/// Produces events from a MockAudioSource by simulating the pipeline.
public actor MockTranscriptionSession {
    private let source: AudioCaptureSource
    private let options: TranscriptionOptions
    private var state: TranscriptionSession.State = .idle

    public init(source: AudioCaptureSource, options: TranscriptionOptions = .init()) {
        self.source = source
        self.options = options
    }

    public func start() -> AsyncStream<TranscriptionEvent> {
        guard state == .idle else {
            return AsyncStream { $0.finish() }
        }
        state = .running

        let (stream, continuation) = AsyncStream<TranscriptionEvent>.makeStream()
        let src = source
        let opts = options

        Task {
            do {
                var segmentIndex = 0
                for try await _ in src.start() {
                    if opts.enableVolatileResults {
                        continuation.yield(.volatile(.init(
                            text: "partial \(segmentIndex)",
                            timestamp: Double(segmentIndex)
                        )))
                    }
                    continuation.yield(.final_(.init(
                        text: "segment \(segmentIndex)",
                        startTime: Double(segmentIndex),
                        endTime: Double(segmentIndex + 1)
                    )))
                    segmentIndex += 1
                }
                continuation.yield(.ended(.completed))
                continuation.finish()
            } catch {
                continuation.yield(.ended(.error(error.localizedDescription)))
                continuation.finish()
            }
        }

        return stream
    }

    public func stop() async {
        state = .stopping
        await source.stop()
        state = .finished
    }

    public func getState() -> TranscriptionSession.State { state }
}
