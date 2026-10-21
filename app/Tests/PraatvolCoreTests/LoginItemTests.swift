import Testing

@testable import PraatvolCore

@Test func installedLoginStatuses() {
    #expect(LoginItemState.resolve(status: .enabled, isInstalled: true) == .enabled)
    #expect(LoginItemState.resolve(status: .requiresApproval, isInstalled: true) == .needsApproval)
    #expect(LoginItemState.resolve(status: .notRegistered, isInstalled: true) == .disabled)
    #expect(
        LoginItemState.resolve(status: .notFound, isInstalled: true)
            == .failed("macOS could not find the login item. Move praatvol to Applications and reopen it."))
    #expect(
        LoginItemState.resolve(status: .unknown, isInstalled: true)
            == .failed("macOS returned an unknown login item status."))
}

@Test func unavailableLoginRegistration() {
    for status in LoginItemStatus.allCases {
        #expect(LoginItemState.resolve(status: status, isInstalled: false) == .notInstalled)
    }
    #expect(LoginItemState.resolve(status: .enabled, isInstalled: false, errorMessage: "Failure") == .notInstalled)
}

@Test func loginRegistrationFailure() {
    for status in LoginItemStatus.allCases {
        #expect(
            LoginItemState.resolve(status: status, isInstalled: true, errorMessage: "Failure") == .failed("Failure"))
    }
}
