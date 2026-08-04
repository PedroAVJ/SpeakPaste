import AppKit
import Combine

enum MacApplicationPresencePolicy: Equatable {
    case accessory
    case regular
}

enum MacApplicationSurface: Hashable {
    case dashboard
    case settings
    case statusHUD
    case menuBar

    fileprivate var promotesApplication: Bool {
        switch self {
        case .dashboard, .settings: true
        case .statusHUD, .menuBar: false
        }
    }
}

struct MacApplicationPresenceState: Equatable {
    private(set) var visibleSurfaces = Set<MacApplicationSurface>()

    var policy: MacApplicationPresencePolicy {
        visibleSurfaces.contains(where: \.promotesApplication) ? .regular : .accessory
    }

    mutating func setVisible(_ surface: MacApplicationSurface, _ isVisible: Bool) {
        if isVisible {
            visibleSurfaces.insert(surface)
        } else {
            visibleSurfaces.remove(surface)
        }
    }
}

/// Owns the only runtime transitions between menu-bar utility and foreground
/// application presence. Recording, the global hotkey, the status item, and
/// the nonactivating HUD do not participate in this lifecycle.
@MainActor
final class MacApplicationPresenceCoordinator: ObservableObject {
    typealias PolicyApplier = (MacApplicationPresencePolicy) -> Void

    private var state = MacApplicationPresenceState()
    private let applyPolicy: PolicyApplier
    private let activateApplication: () -> Void
    private var dashboardPresenter: (() -> Void)?

    init(
        applyPolicy: @escaping PolicyApplier = { policy in
            let appKitPolicy: NSApplication.ActivationPolicy = switch policy {
            case .accessory: .accessory
            case .regular: .regular
            }
            _ = NSApp.setActivationPolicy(appKitPolicy)
        },
        activateApplication: @escaping () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.applyPolicy = applyPolicy
        self.activateApplication = activateApplication
    }

    var currentPolicy: MacApplicationPresencePolicy { state.policy }

    /// Called from the application delegate before SwiftUI can present a
    /// surface. LSUIElement supplies the same launch contract at Launch
    /// Services level; this makes the in-process policy explicit as well.
    func establishLaunchPolicy() {
        applyPolicy(.accessory)
    }

    func installDashboardPresenter(_ presenter: @escaping () -> Void) {
        dashboardPresenter = presenter
    }

    func openDashboard() {
        setVisible(.dashboard, true)
        dashboardPresenter?()
        activateApplication()
    }

    func openSettings(_ action: () -> Void) {
        setVisible(.settings, true)
        action()
        activateApplication()
    }

    func settingsDidAppear() {
        setVisible(.settings, true)
    }

    func settingsDidDisappear() {
        setVisible(.settings, false)
    }

    func dashboardDidClose() {
        setVisible(.dashboard, false)
    }

    private func setVisible(_ surface: MacApplicationSurface, _ isVisible: Bool) {
        let previousPolicy = state.policy
        state.setVisible(surface, isVisible)
        guard state.policy != previousPolicy else { return }
        applyPolicy(state.policy)
    }
}
