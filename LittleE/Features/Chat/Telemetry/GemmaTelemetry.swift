import Foundation

/// In-memory rolling log of Gemma 4 generation latency. Local only,
/// surfaced via the debug pane in Settings so the owner can measure the
/// impact of prompt/ KV-cache/ warmup changes without a metrics pipeline.
///
/// Shared process-wide because `ChatViewModel` creates a fresh
/// `Gemma4MLXChatSession` per turn — the per-instance cache would be
/// useless for anything but a single turn.
@Observable
final class GemmaTelemetry: @unchecked Sendable {

    static let shared = GemmaTelemetry()

    struct Sample: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        /// Seconds spent in `loadContainer` on first use of the process.
        /// `nil` for turns where the container was already cached.
        let loadSeconds: Double?
        /// Seconds from `streamDetails(to:)` call to the first streamed
        /// chunk that carried prose or a tool call. The classic
        /// "time to first token" metric.
        let firstTokenSeconds: Double
        /// Seconds from first token to `.done`. Divide `tokensOut` by
        /// this for a rough decode throughput.
        let decodeSeconds: Double
        /// Seconds from `stream()` entry to `.done`.
        let totalSeconds: Double
        /// Rough count of streamed chunks (proxy for output tokens).
        let tokensOut: Int
        /// Number of `ChatMessage`s in the history fed to `splitHistory`.
        let historyCount: Int
        /// `true` when the turn emitted at least one tool call.
        let toolCallFired: Bool
    }

    private(set) var samples: [Sample] = []
    private let maxSamples = 100

    nonisolated func record(_ sample: Sample) {
        Task { @MainActor in
            self.samples.append(sample)
            if self.samples.count > self.maxSamples {
                self.samples.removeFirst(self.samples.count - self.maxSamples)
            }
        }
    }

    func clear() { samples.removeAll() }

    // MARK: - Aggregates

    var medianFirstTokenSeconds: Double? {
        median(samples.map(\.firstTokenSeconds))
    }

    var medianTotalSeconds: Double? {
        median(samples.map(\.totalSeconds))
    }

    var medianTokensPerSecond: Double? {
        let rates = samples.compactMap { s -> Double? in
            guard s.decodeSeconds > 0.01, s.tokensOut > 0 else { return nil }
            return Double(s.tokensOut) / s.decodeSeconds
        }
        return median(rates)
    }

    var lastLoadSeconds: Double? {
        samples.compactMap(\.loadSeconds).last
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

/// Builder that a single `Gemma4MLXChatSession` turn uses to timestamp
/// phases. Construct at `stream()` entry, call `mark*` methods as the
/// phases fire, then `finish(into:)` to commit the sample.
struct GemmaTelemetryRecorder: Sendable {
    private let start: Date
    private var loadStart: Date?
    private var loadEnd: Date?
    private var generationStart: Date?
    private var firstTokenAt: Date?
    private var tokensOut: Int = 0
    private var toolCallFired: Bool = false
    let historyCount: Int

    nonisolated init(historyCount: Int) {
        self.start = Date()
        self.historyCount = historyCount
    }

    nonisolated mutating func markLoadStart() { loadStart = Date() }
    nonisolated mutating func markLoadEnd() { loadEnd = Date() }
    nonisolated mutating func markGenerationStart() { generationStart = Date() }
    nonisolated mutating func markChunk() {
        if firstTokenAt == nil { firstTokenAt = Date() }
        tokensOut += 1
    }
    nonisolated mutating func markToolCall() {
        if firstTokenAt == nil { firstTokenAt = Date() }
        toolCallFired = true
    }

    nonisolated func finish(into telemetry: GemmaTelemetry = .shared) {
        let end = Date()
        let firstToken = firstTokenAt ?? end
        let genStart = generationStart ?? start
        let loadSeconds: Double? = {
            guard let loadStart, let loadEnd else { return nil }
            return loadEnd.timeIntervalSince(loadStart)
        }()
        telemetry.record(
            GemmaTelemetry.Sample(
                timestamp: start,
                loadSeconds: loadSeconds,
                firstTokenSeconds: firstToken.timeIntervalSince(genStart),
                decodeSeconds: end.timeIntervalSince(firstToken),
                totalSeconds: end.timeIntervalSince(start),
                tokensOut: tokensOut,
                historyCount: historyCount,
                toolCallFired: toolCallFired
            )
        )
    }
}
