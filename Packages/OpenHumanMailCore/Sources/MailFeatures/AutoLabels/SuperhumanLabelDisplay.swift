import Foundation
import MailModel
import Observation

@MainActor
@Observable
public final class SuperhumanLabelDisplay {
    public private(set) var rules: SuperhumanLabelRules
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init(settings: (any SettingsPort)?) {
        rules = SuperhumanLabelRules(hidesLabels: AppSettings.hideSuperhumanLabels.defaultValue,
                                     mapping: AppSettings.superhumanLabelMapping.defaultValue)
        guard let settings else { return }
        let hide = settings.observe(AppSettings.hideSuperhumanLabels)
        let mapping = settings.observe(AppSettings.superhumanLabelMapping)
        tasks = [
            Task { [weak self] in
                for await value in hide {
                    guard !Task.isCancelled else { return }
                    self?.update(hidesLabels: value)
                }
            },
            Task { [weak self] in
                for await value in mapping {
                    guard !Task.isCancelled else { return }
                    self?.update(mapping: value)
                }
            },
        ]
    }

    isolated deinit {
        for task in tasks { task.cancel() }
    }

    public var hidesLabels: Bool { rules.hidesLabels }

    public func hides(_ label: LabelInfo) -> Bool { rules.hides(label.name) }

    public func visible(_ labels: [LabelInfo]) -> [LabelInfo] {
        guard rules.hidesLabels else { return labels }
        return labels.filter { !rules.hides($0.name) }
    }

    func update(hidesLabels value: Bool? = nil, mapping: [String: String]? = nil) {
        var next = rules
        if let value { next.hidesLabels = value }
        if let mapping { next.mapping = mapping }
        if next != rules { rules = next }
    }
}
