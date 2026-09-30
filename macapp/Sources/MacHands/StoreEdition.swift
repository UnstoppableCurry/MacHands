import Foundation

/// This branch is a separate product: the free Mac App Store edition.
/// It is not the MIT open-source agent bridge on `master`, not DataDance,
/// and not MacDisk. Never merge this branch back.
enum StoreEdition {

    static let isEnabled = true

    static let githubURL = "https://github.com/UnstoppableCurry/MacHands"
    static let githubURLValue = URL(string: githubURL)!

    static let cloneCommand = "git clone https://github.com/UnstoppableCurry/MacHands.git"

    static let bundleId = "app.machands.MacHands.store"
    static let marketingVersion = "1.0.0"
    static let buildNumber = "1"

    /// Shown in About / the menu bar. Display name stays MacHands.
    static let editionName = "Free App Store edition"

    static let disabledReason = "Disabled in the Mac App Store edition. The App Sandbox forbids it. Use the open-source agent bridge: https://github.com/UnstoppableCurry/MacHands"

    static func refuse(_ action: String) -> String {
        return "\(action) is disabled in the free App Store edition. \(disabledReason)"
    }
}
