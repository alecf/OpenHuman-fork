import AppKit
import MailActions

public enum CatalogKeyTable {
    public typealias Table = KeyTable

    public static func build(_ descriptors: [ActionDescriptor] = ActionCatalog.all) -> KeyTable {
        KeyTable.build(descriptors)
    }
}
