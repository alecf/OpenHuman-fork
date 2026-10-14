import Foundation

public struct StoreDoctorReport: Hashable, Sendable {
    public var sqliteVersion: String
    public var fts5Available: Bool
    public var trigramAvailable: Bool
    public var journalMode: String
    public var autoVacuum: Int
    public var foreignKeysEnabled: Bool
    public var pageCount: Int
    public var freelistCount: Int
    public var compatLevel: Int
    public var createdByVersion: String
    public var appliedMigrations: [String]
    public var isReadOnly: Bool
    public var isCorrupt: Bool

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        sqliteVersion: String,
        fts5Available: Bool,
        trigramAvailable: Bool,
        journalMode: String,
        autoVacuum: Int,
        foreignKeysEnabled: Bool,
        pageCount: Int,
        freelistCount: Int,
        compatLevel: Int,
        createdByVersion: String,
        appliedMigrations: [String],
        isReadOnly: Bool,
        isCorrupt: Bool
    ) {
        self.sqliteVersion = sqliteVersion
        self.fts5Available = fts5Available
        self.trigramAvailable = trigramAvailable
        self.journalMode = journalMode
        self.autoVacuum = autoVacuum
        self.foreignKeysEnabled = foreignKeysEnabled
        self.pageCount = pageCount
        self.freelistCount = freelistCount
        self.compatLevel = compatLevel
        self.createdByVersion = createdByVersion
        self.appliedMigrations = appliedMigrations
        self.isReadOnly = isReadOnly
        self.isCorrupt = isCorrupt
    }
    // end generated-init
}

public struct MaintenanceReport: Hashable, Sendable {
    public var checkpointed: Bool = false
    public var vacuumed: Bool = false
    public var quickCheck: String?
    public var maintenanceTasks: [String] = []

    // generated-init: Tools/ci/gen-public-inits.py
    public init(
        checkpointed: Bool = false,
        vacuumed: Bool = false,
        quickCheck: String? = nil,
        maintenanceTasks: [String] = []
    ) {
        self.checkpointed = checkpointed
        self.vacuumed = vacuumed
        self.quickCheck = quickCheck
        self.maintenanceTasks = maintenanceTasks
    }
    // end generated-init
}
