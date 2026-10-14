import Foundation
import MailActions
import Synchronization

public struct RecentActionUse: Codable, Hashable, Sendable {
    public let id: ActionID
    public var count: Int
    public var lastUsed: Date

    public init(id: ActionID, count: Int, lastUsed: Date) {
        self.id = id
        self.count = count
        self.lastUsed = lastUsed
    }
}

public protocol RecentActionsStoring: Sendable {
    func load() -> [RecentActionUse]
    func save(_ uses: [RecentActionUse])
}

public final class InMemoryRecentActionsStore: RecentActionsStoring {
    private let uses = Mutex<[RecentActionUse]>([])
    public init() {}
    public func load() -> [RecentActionUse] { uses.withLock { $0 } }
    public func save(_ uses: [RecentActionUse]) { self.uses.withLock { $0 = uses } }
}

public struct UserDefaultsRecentActionsStore: RecentActionsStoring {
    public static let key = "dev.openhuman.mail.palette.recents.v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> [RecentActionUse] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([RecentActionUse].self, from: data)) ?? []
    }

    public func save(_ uses: [RecentActionUse]) {
        guard let data = try? JSONEncoder().encode(uses) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

@MainActor
public final class RecentActions {
    public static let limit = 50
    private let store: any RecentActionsStoring
    private let now: @Sendable () -> Date
    public private(set) var uses: [RecentActionUse]

    public init(store: any RecentActionsStoring = InMemoryRecentActionsStore(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
        uses = store.load().sorted { $0.lastUsed > $1.lastUsed }
    }

    public func recent(_ count: Int = 5) -> [ActionID] { Array(uses.prefix(count).map(\.id)) }

    public func record(_ id: ActionID) {
        var use = uses.first { $0.id == id } ?? RecentActionUse(id: id, count: 0, lastUsed: now())
        uses.removeAll { $0.id == id }
        use.count += 1
        use.lastUsed = now()
        uses.insert(use, at: 0)
        if uses.count > Self.limit { uses.removeLast(uses.count - Self.limit) }
        store.save(uses)
    }

    public func boost(_ id: ActionID) -> Int {
        guard let position = uses.firstIndex(where: { $0.id == id }) else { return 0 }
        return min(uses[position].count, 5) + (position < 5 ? 5 - position : 0)
    }
}

public protocol KeymapStoring: Sendable {
    func load() -> KeymapOverrides?
    func save(_ overrides: KeymapOverrides)
}

public final class InMemoryKeymapStore: KeymapStoring {
    private let value: Mutex<KeymapOverrides?>
    public init(_ overrides: KeymapOverrides? = nil) { value = Mutex(overrides) }
    public func load() -> KeymapOverrides? { value.withLock { $0 } }
    public func save(_ overrides: KeymapOverrides) { value.withLock { $0 = overrides } }
}

public struct UserDefaultsKeymapStore: KeymapStoring {
    public static let key = "dev.openhuman.mail.keymap.v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) { self.suiteName = suiteName }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> KeymapOverrides? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(KeymapOverrides.self, from: data)
    }

    public func save(_ overrides: KeymapOverrides) {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
