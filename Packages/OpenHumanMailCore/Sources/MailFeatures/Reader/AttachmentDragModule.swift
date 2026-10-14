import MailActions

public struct AttachmentDragModule: FeatureModule {
    public static let id = FeatureModuleID.attachmentDragOut
    public static let defaultEnabled = true
    public init() {}
    public func register(in registry: inout ModuleRegistry, env: AppEnvironment) {
        env.installAttachmentDrag()
    }
}
