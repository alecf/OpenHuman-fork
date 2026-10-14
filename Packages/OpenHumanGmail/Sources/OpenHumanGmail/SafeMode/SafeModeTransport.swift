import Foundation
import OpenHumanCore

public enum SafeModeTransport {
    public static func wrap(_ transport: any HTTPTransport, mode: SafeMode, grantedScopes: [String],
                            allowlist: WriteAllowlistStore?, recipients: SendRecipientGate?) -> any HTTPTransport {
        switch mode.effective(grantedScopes: grantedScopes) {
        case .normal:
            if let guarded = transport as? DenyListTransport, guarded.recipients === recipients { return guarded }
            return DenyListTransport(wrapping: transport, recipients: recipients)
        case .writeAllowlist:
            guard let allowlist else { return readOnly(transport) }
            if let guarded = transport as? WriteGuard, guarded.allowlist === allowlist { return guarded }
            return WriteGuard(wrapping: transport, allowlist: allowlist)
        case .readOnly:
            return readOnly(transport)
        }
    }

    public static func wrap(_ transport: any HTTPTransport, mode: SafeMode, grantedScopes: [String],
                            allowlist: WriteAllowlistStore?) -> any HTTPTransport {
        wrap(transport, mode: mode, grantedScopes: grantedScopes, allowlist: allowlist, recipients: nil)
    }

    public static func wrap(_ transport: any HTTPTransport, mode: SafeMode,
                            grantedScopes: [String]) -> any HTTPTransport {
        wrap(transport, mode: mode, grantedScopes: grantedScopes, allowlist: nil)
    }

    private static func readOnly(_ transport: any HTTPTransport) -> any HTTPTransport {
        transport is ReadOnlyTransport ? transport : ReadOnlyTransport(wrapping: transport)
    }
}

extension SafeMode {
    public func effective(grantedScopes: [String]) -> SafeMode {
        grantedScopes.contains(GmailScope.modify) ? self : .readOnly
    }

    public var bannerText: String? {
        switch self {
        case .normal: return nil
        case .readOnly: return "Safe mode: read-only"
        case .writeAllowlist: return "Safe mode: test writes only"
        }
    }
}

public enum SafeModeLaunch {
    public static let environmentKey = "OPENHUMAN_SAFE_MODE"

    public static func resolve(environment: [String: String]) -> SafeMode {
        let raw = environment[environmentKey] ?? ""
        if !raw.isEmpty, SafeMode(rawValue: raw) == nil {
            Log(.gmail).notice("\(environmentKey) has an unrecognised value; running read-only")
        }
        return SafeMode.fromEnvironment(raw)
    }
}
