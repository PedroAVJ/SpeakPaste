import XCTest
@testable import SpeakPaste

final class MacApplicationPresenceTests: XCTestCase {
    func testLaunchHasAccessoryPresenceWithNoUserFacingWindows() {
        let state = MacApplicationPresenceState()

        XCTAssertEqual(state.policy, .accessory)
        XCTAssertTrue(state.visibleSurfaces.isEmpty)
    }

    func testOpeningOneUserFacingWindowPromotesToRegular() {
        var state = MacApplicationPresenceState()

        state.setVisible(.dashboard, true)

        XCTAssertEqual(state.policy, .regular)
    }

    func testMultipleUserFacingWindowsRemainRegularUntilLastCloses() {
        var state = MacApplicationPresenceState()
        state.setVisible(.dashboard, true)
        state.setVisible(.settings, true)

        state.setVisible(.dashboard, false)
        XCTAssertEqual(state.policy, .regular)

        state.setVisible(.settings, false)
        XCTAssertEqual(state.policy, .accessory)
    }

    func testTransientHUDAndMenuBarNeverPromoteApplication() {
        var state = MacApplicationPresenceState()

        state.setVisible(.statusHUD, true)
        state.setVisible(.menuBar, true)

        XCTAssertEqual(state.policy, .accessory)
    }

    @MainActor
    func testCoordinatorAppliesOnlyRealPolicyTransitions() {
        var appliedPolicies = [MacApplicationPresencePolicy]()
        let coordinator = MacApplicationPresenceCoordinator(
            applyPolicy: { appliedPolicies.append($0) },
            activateApplication: {}
        )
        coordinator.installDashboardPresenter {}

        coordinator.establishLaunchPolicy()
        coordinator.openDashboard()
        coordinator.settingsDidAppear()
        coordinator.dashboardDidClose()
        coordinator.settingsDidDisappear()

        XCTAssertEqual(appliedPolicies, [.accessory, .regular, .accessory])
    }
}
