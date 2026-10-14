import Foundation
import MailActions
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct OverlayFixture {
    let env: AppEnvironment
    let router: AppRouter
    let store: FakeMailStore
    let center: OverlayCenter

    init(corpus: FakeCorpus = .make(threadCount: 10, now: fixedNow), options: FakeMailStore.Options = .init(remoteAck: .immediate),
         flags: FeatureFlags = FeatureFlags(), now: @escaping @Sendable () -> Date = { fixedNow }) {
        env = AppEnvironment.fake(corpus: corpus, options: options, featureFlags: flags)
        store = env.commands as! FakeMailStore
        router = env.router
        center = env.overlays
        center.timeZone = TimeZone(identifier: "UTC")!
        center.locale = Locale(identifier: "en_US_POSIX")
        center.now = now
        env.actions.threadActions?.timeZone = TimeZone(identifier: "UTC")!
        env.actions.threadActions?.locale = Locale(identifier: "en_US_POSIX")
        router.start()
    }

    var registry: ActionRegistry { env.actions }
    var rows: [ThreadRow] { router.list?.rows ?? [] }

    func loaded(_ count: Int? = nil) async {
        await eventually { router.active != nil }
        if router.active?.location != .system(.inbox) { router.go(to: .system(.inbox)) }
        await eventually { router.list?.state == .loaded && (count.map { router.list?.rows.count == $0 } ?? true) }
    }

    @discardableResult
    func run(_ id: ActionID, source: ActionSource = .keyboard, context: ActionContext? = nil) async -> Bool {
        await registry.run(id, source: source, host: router, context: context)
    }

    func toast(_ prefix: String) async {
        await eventually { env.notices.toasts.contains { $0.message.hasPrefix(prefix) } }
    }

    var palette: PaletteController? {
        if case .palette(let palette) = center.overlay { palette } else { nil }
    }

    var timePicker: TimePickerModel? {
        if case .time(let model) = center.overlay { model } else { nil }
    }

    var labelPicker: LabelPickerModel? {
        if case .label(let model) = center.overlay { model } else { nil }
    }
}
