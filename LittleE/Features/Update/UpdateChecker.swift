import Foundation
import Observation

/// Checks `release/latest-build.json` in the household sync repo
/// (`weewey/littlee-sync`) at launch and reports whether a newer
/// TestFlight build than the installed one is available. Reuses the
/// existing GitHub PAT from `GitHubSyncTokenStore` so no additional
/// credential entry is required.
///
/// The manifest is a single JSON object: `{"build": <Int>}`. The
/// Fastlane `beta` lane writes it after `upload_to_testflight`.
@MainActor
@Observable
final class UpdateChecker {

    var latestBuild: Int?
    var isUpdateAvailable: Bool = false

    private let session: URLSession
    private let currentBuild: @Sendable () -> Int?
    private let configProvider: @Sendable () -> GitHubSyncConfig?

    init(
        session: URLSession = .shared,
        currentBuild: @escaping @Sendable () -> Int? = UpdateChecker.bundleBuildNumber,
        configProvider: @escaping @Sendable () -> GitHubSyncConfig? = GitHubSyncTokenStore.load
    ) {
        self.session = session
        self.currentBuild = currentBuild
        self.configProvider = configProvider
    }

    /// Default `currentBuild` provider — reads `CFBundleVersion` from the
    /// main bundle. Tests inject a closure literal instead.
    static func bundleBuildNumber() -> Int? {
        guard let str = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else { return nil }
        return Int(str)
    }

    func check() async {
        guard let config = configProvider() else { return }
        guard let currentBuild = currentBuild() else { return }
        guard let url = URL(string: "https://api.github.com/repos/\(config.repoSlug)/contents/release/latest-build.json") else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            struct Manifest: Decodable { let build: Int }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            latestBuild = manifest.build
            isUpdateAvailable = manifest.build > currentBuild
        } catch {
            return
        }
    }

}
