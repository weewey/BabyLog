import Foundation
import Observation
import OSLog
import LittleECore

/// Append-only event-log sync over a private GitHub repo.
///
/// Each device owns one file at `events/<deviceID>.jsonl`, and only ever
/// writes its own file — so there are no merge conflicts by construction.
/// A 30-second poll loop fetches the repo tree, downloads any peer files
/// whose blob SHA changed, decodes the JSONL, filters fresh events against
/// the local seen vector, and applies them through `SyncEngine`.
///
/// Why this transport replaces Multipeer:
/// - Works backgrounded and across cellular (MC was foreground-only and
///   bounced reconnects every time a sim reinstalled).
/// - No discovery / pairing / DTLS handshake — just HTTPS to api.github.com.
/// - No "is the peer connected right now" race; the file is always there.
///
/// Auth is a fine-grained PAT scoped to a single repo with `Contents:
/// read & write`. Stored in the Keychain via `GitHubSyncTokenStore`.
@Observable
@MainActor
final class GitHubSyncService: LocalWriteNotifying {

    // MARK: - Public state

    /// Drives the Settings pill. Mirrors the actor-isolated state machine.
    private(set) var status: SyncStatus = .idle

    // MARK: - Dependencies

    private let engine: SyncEngine
    private let stateMachine: SyncStateMachine
    private let session: URLSession

    /// Poll cadence. Mutable at runtime: Settings exposes a picker that
    /// writes through `setPollInterval(_:)` so the user can trade freshness
    /// against API quota without relaunching.
    private(set) var pollInterval: TimeInterval

    // MARK: - State

    private var configCache: GitHubSyncConfig?
    private var deviceIDCache: DeviceID?

    /// Per-peer-file blob SHA we last accepted, keyed by tree path. Used
    /// to skip GETs on files we've already processed.
    private var lastSeenPeerSHAs: [String: String] = [:]

    /// SHA of the blob we last wrote for our own device file. Required by
    /// the Contents API to update an existing file.
    private var lastPushedSelfSHA: String?

    private var pollTask: Task<Void, Never>?
    private var pushDebounceTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "littlee.sync", category: "github")

    /// Tree path under which this build's event files live. Release builds
    /// write to `events/`; DEBUG builds (i.e. simulators / dev installs)
    /// write to `events-test/`. Pulls only consider the same folder, so a
    /// dev sim and your wife's prod phone share one repo without ever
    /// cross-contaminating each other's logs. Override at launch via the
    /// `LITTLEE_SYNC_PATH_PREFIX` env var (e.g. for ad-hoc test scenarios).
    private static let pathPrefix: String = {
        if let override = ProcessInfo.processInfo.environment["LITTLEE_SYNC_PATH_PREFIX"],
           !override.isEmpty {
            return override.hasSuffix("/") ? override : override + "/"
        }
        #if DEBUG
        return "events-test/"
        #else
        return "events/"
        #endif
    }()

    // MARK: - Init

    init(
        engine: SyncEngine,
        session: URLSession = .shared,
        pollInterval: TimeInterval = 30,
        config: GitHubSyncConfig? = nil
    ) {
        self.engine = engine
        self.stateMachine = SyncStateMachine()
        self.session = session
        self.pollInterval = pollInterval
        self.configCache = config
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        guard let config = GitHubSyncTokenStore.load() else {
            Self.logger.notice("start: no config — sitting in idle until token + repo are set")
            status = .idle
            return
        }
        configCache = config
        Self.logger.notice("start: poll loop @ \(self.pollInterval, privacy: .public)s, repo=\(config.repoSlug, privacy: .public)")
        status = .searching
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stop() {
        Self.logger.notice("stop")
        pollTask?.cancel()
        pollTask = nil
        pushDebounceTask?.cancel()
        pushDebounceTask = nil
        status = .idle
    }

    /// Re-read config from the keychain. Call after the user enters or
    /// updates the token in Settings so we pick up the change without
    /// requiring a full app relaunch.
    func reloadConfig() {
        let wasRunning = pollTask != nil
        stop()
        if wasRunning { start() }
    }

    /// Replace the poll cadence. If the loop is running, cancel the
    /// in-flight sleep and restart so the new interval takes effect on
    /// the next tick instead of waiting out the old one.
    func setPollInterval(_ seconds: TimeInterval) {
        let clamped = max(5, seconds)
        guard clamped != pollInterval else { return }
        pollInterval = clamped
        Self.logger.notice("setPollInterval: \(clamped, privacy: .public)s")
        guard pollTask != nil else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// Manual "Sync now" — push any unpushed local events, then pull the
    /// peer tree. Invoked from the Settings button; safe to call while
    /// the poll loop is running.
    func syncNow() async {
        Self.logger.notice("syncNow: manual trigger")
        await pushLocal()
        await pullPeers()
    }

    // MARK: - LocalWriteNotifying

    nonisolated func didAppendLocalEvent() async {
        await MainActor.run { self.scheduleDebouncedPush() }
    }

    private func scheduleDebouncedPush() {
        pushDebounceTask?.cancel()
        pushDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
            guard !Task.isCancelled, let self else { return }
            await self.pushLocal()
        }
    }

    // MARK: - Push

    private func pushLocal() async {
        guard let config = configCache ?? GitHubSyncTokenStore.load() else {
            Self.logger.error("pushLocal: no config")
            return
        }
        configCache = config
        let deviceID = await currentDeviceID()
        let path = "\(Self.pathPrefix)\(deviceID.rawValue).jsonl"

        // Snapshot every event authored by this device.
        let allEvents = await engine.allEvents()
        let mine = allEvents.filter { $0.deviceID == deviceID }
        guard let body = encodeJSONL(mine) else {
            Self.logger.error("pushLocal: encode failed")
            return
        }

        await stateMachine.markTransferring(true)
        await publishStatus()
        defer {
            Task {
                await self.stateMachine.markTransferring(false)
                await self.publishStatus()
            }
        }

        // Resolve current SHA on first push (or after a cache loss).
        if lastPushedSelfSHA == nil {
            lastPushedSelfSHA = try? await fetchFileSHA(path: path, config: config)
        }

        do {
            let newSHA = try await putFile(
                path: path,
                content: body,
                sha: lastPushedSelfSHA,
                config: config,
                message: "sync from \(deviceID.rawValue) @ \(ISO8601DateFormatter().string(from: Date()))"
            )
            lastPushedSelfSHA = newSHA
            await stateMachine.apply(
                sequence: nextSequence(),
                transition: .connected(peerName: shortRepoName(config.repoSlug), isTransferring: false)
            )
            await stateMachine.recordSync(at: Date())
            await publishStatus()
            Self.logger.notice("pushLocal: ok, \(mine.count, privacy: .public) events, sha=\(newSHA, privacy: .public)")
        } catch GitHubAPIError.shaConflict {
            // The cached SHA was stale — refresh and retry once.
            Self.logger.notice("pushLocal: sha conflict, refreshing")
            lastPushedSelfSHA = try? await fetchFileSHA(path: path, config: config)
            if let refreshed = lastPushedSelfSHA {
                do {
                    let retrySHA = try await putFile(
                        path: path,
                        content: body,
                        sha: refreshed,
                        config: config,
                        message: "sync from \(deviceID.rawValue) @ retry"
                    )
                    lastPushedSelfSHA = retrySHA
                    Self.logger.notice("pushLocal: retry ok, sha=\(retrySHA, privacy: .public)")
                } catch {
                    Self.logger.error("pushLocal: retry failed — \(String(describing: error), privacy: .public)")
                }
            }
        } catch {
            Self.logger.error("pushLocal: failed — \(String(describing: error), privacy: .public)")
            await stateMachine.apply(
                sequence: nextSequence(),
                transition: .unavailable(reason: humanise(error))
            )
            await publishStatus()
        }
    }

    // MARK: - Pull

    private func pollLoop() async {
        // Push first so any events stranded by a cancelled debounce or a
        // failed earlier push reach the remote before we pull peer updates.
        // Then pull. Repeat on the interval.
        await pushLocal()
        await pullPeers()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if Task.isCancelled { break }
            await pushLocal()
            await pullPeers()
        }
    }

    private func pullPeers() async {
        guard let config = configCache ?? GitHubSyncTokenStore.load() else { return }
        configCache = config
        let deviceID = await currentDeviceID()
        let myPath = "\(Self.pathPrefix)\(deviceID.rawValue).jsonl"

        await stateMachine.markTransferring(true)
        await publishStatus()
        defer {
            Task {
                await self.stateMachine.markTransferring(false)
                await self.publishStatus()
            }
        }

        let entries: [TreeEntry]
        do {
            entries = try await fetchTree(config: config)
        } catch {
            Self.logger.error("pullPeers: tree fetch failed — \(String(describing: error), privacy: .public)")
            await stateMachine.apply(
                sequence: nextSequence(),
                transition: .unavailable(reason: humanise(error))
            )
            await publishStatus()
            return
        }

        // First successful pull marks us connected.
        await stateMachine.apply(
            sequence: nextSequence(),
            transition: .connected(peerName: shortRepoName(config.repoSlug), isTransferring: true)
        )

        let peerFiles = entries.filter {
            $0.type == "blob"
                && $0.path.hasPrefix(Self.pathPrefix)
                && $0.path.hasSuffix(".jsonl")
                && $0.path != myPath
        }

        var fetched = 0
        var anyApplied = false
        for entry in peerFiles {
            if lastSeenPeerSHAs[entry.path] == entry.sha { continue }
            do {
                let body = try await fetchFileContent(path: entry.path, config: config)
                let events = decodeJSONL(body)
                let seen = await engine.currentSeenVector()
                let fresh = events.filter { !seen.contains($0) }
                if !fresh.isEmpty {
                    try await engine.apply(SyncDelta(from: deviceID, events: fresh))
                    anyApplied = true
                    Self.logger.notice("pullPeers: applied \(fresh.count, privacy: .public) fresh events from \(entry.path, privacy: .public)")
                }
                lastSeenPeerSHAs[entry.path] = entry.sha
                fetched += 1
            } catch {
                Self.logger.error("pullPeers: file \(entry.path, privacy: .public) failed — \(String(describing: error), privacy: .public)")
            }
        }

        await stateMachine.recordSync(at: Date())
        await publishStatus()
        Self.logger.notice("pullPeers: tree=\(entries.count, privacy: .public) peers=\(peerFiles.count, privacy: .public) fetched=\(fetched, privacy: .public) applied=\(anyApplied, privacy: .public)")

        if anyApplied {
            NotificationCenter.default.post(name: .syncStoreDidChange, object: nil)
        }
    }

    // MARK: - HTTP

    private func fetchTree(config: GitHubSyncConfig) async throws -> [TreeEntry] {
        let url = githubURL(config: config, path: "git/trees/main?recursive=1")
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        applyAuth(&req, config: config)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        try assertOK(response, data: data)
        let decoded = try JSONDecoder().decode(TreeResponse.self, from: data)
        return decoded.tree
    }

    private func fetchFileContent(path: String, config: GitHubSyncConfig) async throws -> Data {
        let url = githubURL(config: config, path: "contents/\(path)")
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        applyAuth(&req, config: config)
        req.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        try assertOK(response, data: data)
        return data
    }

    private func fetchFileSHA(path: String, config: GitHubSyncConfig) async throws -> String? {
        let url = githubURL(config: config, path: "contents/\(path)")
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        applyAuth(&req, config: config)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return nil
        }
        try assertOK(response, data: data)
        let decoded = try JSONDecoder().decode(ContentMetadata.self, from: data)
        return decoded.sha
    }

    @discardableResult
    private func putFile(
        path: String,
        content: Data,
        sha: String?,
        config: GitHubSyncConfig,
        message: String
    ) async throws -> String {
        let url = githubURL(config: config, path: "contents/\(path)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        applyAuth(&req, config: config)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = PutBody(
            message: message,
            content: content.base64EncodedString(),
            sha: sha,
            branch: "main"
        )
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 409 {
            throw GitHubAPIError.shaConflict
        }
        try assertOK(response, data: data)
        let decoded = try JSONDecoder().decode(PutResponse.self, from: data)
        return decoded.content.sha
    }

    private func githubURL(config: GitHubSyncConfig, path: String) -> URL {
        let raw = "https://api.github.com/repos/\(config.repoSlug)/\(path)"
        guard let url = URL(string: raw) else {
            fatalError("invalid github url: \(raw)")
        }
        return url
    }

    private func applyAuth(_ req: inout URLRequest, config: GitHubSyncConfig) {
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("LittleE-iOS", forHTTPHeaderField: "User-Agent")
    }

    private func assertOK(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw GitHubAPIError.httpStatus(http.statusCode, snippet)
        }
    }

    // MARK: - JSONL codec

    private func encodeJSONL(_ events: [DomainEvent]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        var buffer = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { return nil }
            buffer.append(line)
            buffer.append(0x0A) // \n
        }
        return buffer
    }

    /// Largest peer file we'll attempt to decode. Defends against a peer
    /// that wrote a runaway log or a malicious actor seeding a multi-GB
    /// blob to OOM us. ~10 MB is roughly 100k events at typical sizes,
    /// far more than realistic household activity.
    private static let maxPeerFileBytes = 10 * 1024 * 1024

    /// Skip events whose timestamp is more than this far in the future.
    /// Allows for clock skew between phones but rejects obviously bogus
    /// records (e.g. someone seeding a date in 2099).
    private static let maxFutureSkew: TimeInterval = 60 * 60 * 24 // 1 day

    /// Earliest timestamp we'll accept. Anything before this is treated
    /// as garbage / uninitialised clock.
    private static let earliestPlausibleDate = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01

    private func decodeJSONL(_ data: Data) -> [DomainEvent] {
        guard data.count <= Self.maxPeerFileBytes else {
            Self.logger.error("decodeJSONL: file too large (\(data.count, privacy: .public)B), refusing")
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [DomainEvent] = []
        var malformed = 0
        var rejected = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let event = try? decoder.decode(DomainEvent.self, from: Data(line)) else {
                malformed += 1
                continue
            }
            guard Self.isStructurallyValid(event) else {
                rejected += 1
                continue
            }
            out.append(event)
        }
        if malformed > 0 || rejected > 0 {
            Self.logger.notice("decodeJSONL: dropped \(malformed, privacy: .public) malformed + \(rejected, privacy: .public) invalid lines, kept \(out.count, privacy: .public)")
        }
        return out
    }

    /// Defensive checks applied to *every* event read from a peer file
    /// before we hand it to the projection. The repo is private and
    /// PAT-gated, but a corrupted file or a buggy peer build could still
    /// produce records that would poison local state if applied as-is.
    static func isStructurallyValid(_ event: DomainEvent) -> Bool {
        if event.deviceID.rawValue.isEmpty { return false }
        if event.recordID.isEmpty { return false }
        if event.timestamp < earliestPlausibleDate { return false }
        if event.timestamp > Date().addingTimeInterval(maxFutureSkew) { return false }
        if event.payload.count > 64 * 1024 { return false } // single payload > 64KB is bogus
        if event.schemaVersion < 1 { return false }
        return true
    }

    // MARK: - State helpers

    private func currentDeviceID() async -> DeviceID {
        if let cached = deviceIDCache { return cached }
        let id = await engine.localDeviceID
        deviceIDCache = id
        return id
    }

    private var sequenceCounter: UInt64 = 0
    private func nextSequence() -> UInt64 {
        sequenceCounter &+= 1
        return sequenceCounter
    }

    private func publishStatus() async {
        self.status = await stateMachine.status
    }

    private func shortRepoName(_ slug: String) -> String {
        slug.split(separator: "/").last.map(String.init) ?? slug
    }

    private func humanise(_ error: any Error) -> String {
        switch error {
        case GitHubAPIError.httpStatus(let code, _): return "HTTP \(code)"
        case GitHubAPIError.invalidResponse: return "Invalid response"
        case GitHubAPIError.shaConflict: return "Conflict"
        case let urlError as URLError: return urlError.localizedDescription
        default: return String(describing: error)
        }
    }
}

// MARK: - Wire types

private struct TreeResponse: Decodable { let tree: [TreeEntry] }
private struct TreeEntry: Decodable {
    let path: String
    let type: String
    let sha: String
}
private struct ContentMetadata: Decodable { let sha: String }
private struct PutBody: Encodable {
    let message: String
    let content: String
    let sha: String?
    let branch: String
}
private struct PutResponse: Decodable {
    struct Content: Decodable { let sha: String }
    let content: Content
}

extension Notification.Name {
    static let syncStoreDidChange = Notification.Name("littlee.sync.storeDidChange")
}

enum GitHubAPIError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int, String)
    case shaConflict
}
