import Foundation
import LittleECore

/// Creates a `ChatSession` for a chosen `ChatBackend`. Injected into
/// `ChatViewModel` so production code can wire real backends (Apple FM,
/// Claude, Gemma) while tests and previews use `FakeChatSession`.
///
/// Real backend adapters (`AppleFMChatSession`, `ClaudeChatSession`) are
/// landing on sibling branches; the merge agent will supply a production
/// factory at merge time. Until then the app uses `FakeChatSessionFactory`.
public protocol ChatSessionFactory: Sendable {
    func makeSession(for backend: ChatBackend) throws -> any ChatSession
}

/// Default factory used by previews, UI tests, and the app shell until the
/// real backend adapters are merged in. Returns scripted `FakeChatSession`s
/// so the Chat tab streams realistic-looking replies out of the box.
public struct FakeChatSessionFactory: ChatSessionFactory {

    private let scriptProvider: @Sendable (ChatBackend) -> FakeChatSession.Script

    public init(
        scriptProvider: @escaping @Sendable (ChatBackend) -> FakeChatSession.Script =
            FakeChatSessionFactory.defaultScript
    ) {
        self.scriptProvider = scriptProvider
    }

    public func makeSession(for backend: ChatBackend) throws -> any ChatSession {
        FakeChatSession(script: scriptProvider(backend))
    }

    public static let defaultScript: @Sendable (ChatBackend) -> FakeChatSession.Script = { backend in
        let label: String
        switch backend {
        case .apple: label = "Apple"
        case .claude: label = "Claude"
        case .gemma: label = "Gemma"
        case .qwen: label = "Qwen"
        }
        return .tokens(
            ["Hi ", "from ", "\(label). ", "How ", "can ", "I ", "help?"],
            perTokenDelay: .milliseconds(30)
        )
    }
}
