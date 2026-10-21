public enum LoginItemStatus: CaseIterable, Sendable {
    case enabled, requiresApproval, notRegistered, notFound, unknown
}

public enum LoginItemState: Equatable, Sendable {
    case enabled, needsApproval, disabled, notInstalled
    case failed(String)

    public static func resolve(
        status: LoginItemStatus, isInstalled: Bool, errorMessage: String? = nil
    ) -> LoginItemState {
        guard isInstalled else { return .notInstalled }
        if let errorMessage { return .failed(errorMessage) }
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        case .notRegistered: return .disabled
        case .notFound:
            return .failed("macOS could not find the login item. Move praatvol to Applications and reopen it.")
        case .unknown: return .failed("macOS returned an unknown login item status.")
        }
    }
}
