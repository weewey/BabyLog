import Foundation
import LittleECore

/// Creates a `ChatSession` for a chosen `ChatBackend`. Injected into
/// `ChatViewModel` so production code can wire real backends (Apple FM,
/// Gemma) while tests and previews use `FakeChatSession`.
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
        case .gemma: label = "Gemma"
        }
        return .tokens(
            ["Hi ", "from ", "\(label). ", "How ", "can ", "I ", "help?"],
            perTokenDelay: .milliseconds(30)
        )
    }
}
