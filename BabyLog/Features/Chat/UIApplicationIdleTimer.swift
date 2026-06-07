import UIKit

/// Production `IdleTimerControlling` backed by the shared `UIApplication`.
///
/// `ChatViewModel` flips `isIdleTimerDisabled` to keep the screen awake only
/// while an on-device reply streams, so the phone can't auto-lock mid-reply and
/// crash the MLX Metal backend. Setting `false` (the default) leaves normal
/// auto-lock behaviour untouched.
@MainActor
final class UIApplicationIdleTimer: IdleTimerControlling {
    var isIdleTimerDisabled: Bool {
        get { UIApplication.shared.isIdleTimerDisabled }
        set { UIApplication.shared.isIdleTimerDisabled = newValue }
    }
}
