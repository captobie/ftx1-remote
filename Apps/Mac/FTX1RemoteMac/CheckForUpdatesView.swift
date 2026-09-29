import Combine
import Sparkle
import SwiftUI

/// Sparkle's own recommended SwiftUI pattern: `SPUUpdater.canCheckForUpdates`
/// is KVO-observable, not `@Published`, so this bridges it into a view model
/// the "Check for Updates…" menu item can bind its disabled state to.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

/// Backs Settings' Updates tab. Same KVO bridge as `CheckForUpdatesViewModel`:
/// all three properties are KVO-compliant on `SPUUpdater`, so the toggles
/// also follow changes made elsewhere — Sparkle's own first-run "check
/// automatically?" prompt, or its update alert's "Automatically download
/// and install updates in the future" checkbox. Sparkle persists these in
/// its own `UserDefaults` keys (`SUEnableAutomaticChecks`,
/// `SUAutomaticallyUpdate`), so there's no app-side storage here, and
/// setting `automaticallyChecksForUpdates` reschedules the background
/// check cycle on its own.
final class UpdaterSettingsViewModel: ObservableObject {
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    /// False while automatic checks are off (and whenever the Info.plist's
    /// `SUAllowsAutomaticUpdates` says no) — the download toggle is
    /// disabled then rather than hidden.
    @Published private(set) var allowsAutomaticUpdates = false

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .assign(to: &$automaticallyDownloadsUpdates)
        updater.publisher(for: \.allowsAutomaticUpdates)
            .assign(to: &$allowsAutomaticUpdates)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updater.automaticallyDownloadsUpdates = enabled
    }
}
