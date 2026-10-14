import Foundation
import MailActions
import MailModel

@MainActor
public protocol ActionHost: AnyObject {
    func actionContext() -> ActionContext
}

@MainActor
public struct ActionRequest {
    public let id: ActionID
    public let context: ActionContext
    public let source: ActionSource
    public weak var host: (any ActionHost)?

    public init(id: ActionID, context: ActionContext, source: ActionSource, host: (any ActionHost)?) {
        self.id = id
        self.context = context
        self.source = source
        self.host = host
    }

    public var router: AppRouter? { host as? AppRouter }
}

public enum ActionPerformance {
    case notHandled
    case done
    case started(Task<Void, Never>)
}

@MainActor
public protocol ActionHandler: AnyObject {
    func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability
    func perform(_ request: ActionRequest) -> ActionPerformance
}

extension ActionHandler {
    public func availability(of id: ActionID, in context: ActionContext, host: (any ActionHost)?) -> ActionAvailability {
        .enabled
    }
}
