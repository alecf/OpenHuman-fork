#if canImport(CloudKit)
import CloudKit
import Foundation
import OpenHumanCloudSync
import OpenHumanCloudSyncApple
import Testing

@Suite("CloudKit schema file")
struct CloudKitSchemaTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Schema/schema.ckdb")

    let schema: CloudKitSchemaFile

    init() throws {
        schema = try CloudKitSchemaFile(String(contentsOf: Self.file, encoding: .utf8))
    }

    @Test func itDefinesExactlyTheTestHarnessRecordTypes() {
        #expect(schema.recordTypes.map(\.name).sorted() == registeredTypes.map(\.name).sorted())
    }

    @Test func everyRecordTypeHoldsExactlyTheFieldsTheMappingWrites() throws {
        for type in schema.recordTypes {
            let written = try Self.writtenFields(recordType: type.name)
            let custom = type.fields.filter { !$0.key.hasPrefix("___") }.mapValues(\.type)
            #expect(custom == written, "\(type.name)")
        }
    }

    @Test func noFieldIsIndexed() {
        for type in schema.recordTypes {
            for (name, field) in type.fields {
                #expect(field.options.isEmpty, "\(type.name).\(name)")
            }
        }
    }

    @Test func onlyTheCreatorMayReadOrWriteARecord() {
        for type in schema.recordTypes {
            #expect(!type.grants.contains { $0.role == "_world" }, "\(type.name)")
            #expect(Set(type.grants) == [Grant(permission: "READ", role: "_creator"),
                                         Grant(permission: "WRITE", role: "_creator")], "\(type.name)")
        }
    }

    typealias Field = CloudKitSchemaFile.Field
    typealias Grant = CloudKitSchemaFile.Grant

    @Test func theParserReadsGrantsListsAndIndexes() throws {
        let sample = try CloudKitSchemaFile("""
            DEFINE SCHEMA
                CREATE ROLE Reviewer;
                RECORD TYPE Users (
                    "___recordID" REFERENCE QUERYABLE,
                    roles         LIST<INT64>,
                    note          STRING SEARCHABLE SORTABLE,
                    secret        ENCRYPTED BYTES,
                    GRANT WRITE TO "_creator",
                    GRANT READ, CREATE TO "_world"
                );
            """)
        let users = try #require(sample.recordTypes.first)
        #expect(sample.recordTypes.count == 1)
        #expect(users.name == "Users")
        #expect(users.fields == [
            "___recordID": Field(type: "REFERENCE", options: ["QUERYABLE"]),
            "roles": Field(type: "LIST<INT64>", options: []),
            "note": Field(type: "STRING", options: ["SEARCHABLE", "SORTABLE"]),
            "secret": Field(type: "ENCRYPTED BYTES", options: []),
        ])
        #expect(users.grants == [Grant(permission: "WRITE", role: "_creator"),
                                 Grant(permission: "READ", role: "_world"),
                                 Grant(permission: "CREATE", role: "_world")])
        #expect(throws: CloudKitSchemaFile.ParseError.self) {
            try CloudKitSchemaFile("DEFINE SCHEMA RECORD TYPE A ( x STRING, x INT64 );")
        }
        #expect(throws: CloudKitSchemaFile.ParseError.self) {
            try CloudKitSchemaFile("DEFINE SCHEMA RECORD TYPE A ( x STRING ); RECORD TYPE A ( y STRING );")
        }
    }

    private static func writtenFields(recordType: String) throws -> [String: String] {
        let inline = CloudRecord(id: CloudRecordID(zone: .app, name: "schema-test"), type: recordType, format: 1,
                                 keyID: "k1", hlc: HLC(millis: 42, counter: 1, device: "d1"), device: "d1",
                                 deleted: false, payload: .inline(Data([1, 2, 3])))
        var asset = inline
        asset.payload = .asset(Data([4, 5, 6]))
        let records = [inline, asset].flatMap { record in
            var tombstone = record
            tombstone.deleted = true
            return [record, tombstone]
        }
        var fields: [String: String] = [:]
        for record in records {
            let ck = try CloudKitMapping.ckRecord(record, assetFile: { _ in URL(fileURLWithPath: "/dev/null") })
            let encrypted = Set(ck.encryptedValues.allKeys())
            var written: [String: String] = [:]
            for key in ck.allKeys() where !encrypted.contains(key) {
                written[key] = schemaType(ck.object(forKey: key))
            }
            for key in encrypted {
                written[key] = "ENCRYPTED " + schemaType(ck.encryptedValues.object(forKey: key))
            }
            fields.merge(written) { first, second in first == second ? first : first + " | " + second }
        }
        return fields
    }

    private static func schemaType(_ value: Any?) -> String {
        switch value {
        case is CKAsset: return "ASSET"
        case let number as NSNumber:
            return ["f", "d"].contains(String(cString: number.objCType)) ? "DOUBLE" : "INT64"
        case is String: return "STRING"
        case is Data: return "BYTES"
        case is Date: return "TIMESTAMP"
        case is CKRecord.Reference: return "REFERENCE"
        default: return "unsupported \(value.map { String(describing: type(of: $0)) } ?? "nil")"
        }
    }
}

struct CloudKitSchemaFile {
    struct Field: Hashable {
        var type: String
        var options: [String]
    }

    struct Grant: Hashable {
        var permission: String
        var role: String
    }

    struct RecordType {
        var name: String
        var fields: [String: Field] = [:]
        var grants: [Grant] = []
    }

    struct ParseError: Error {
        var token: String
    }

    static let fieldOptions: Set<String> = ["QUERYABLE", "SORTABLE", "SEARCHABLE"]

    let recordTypes: [RecordType]

    init(_ text: String) throws {
        var input = Self.tokens(text)[...]
        func take() throws -> String {
            guard let token = input.popFirst() else { throw ParseError(token: "end of file") }
            return token
        }
        func expect(_ words: String...) throws {
            for word in words {
                let token = try take()
                guard token.uppercased() == word else { throw ParseError(token: token) }
            }
        }
        try expect("DEFINE", "SCHEMA")
        var types: [RecordType] = []
        while let next = input.first {
            if next.uppercased() == "CREATE" {
                try expect("CREATE", "ROLE")
                _ = try take()
                try expect(";")
                continue
            }
            try expect("RECORD", "TYPE")
            var type = RecordType(name: Self.unquoted(try take()))
            try expect("(")
            entries: while true {
                let first = try take()
                if first.uppercased() == "GRANT" {
                    var permissions = [try take().uppercased()]
                    while input.first == "," {
                        input.removeFirst()
                        permissions.append(try take().uppercased())
                    }
                    try expect("TO")
                    let role = Self.unquoted(try take())
                    type.grants += permissions.map { Grant(permission: $0, role: role) }
                } else {
                    let name = Self.unquoted(first)
                    var words: [String] = []
                    while let word = input.first, word != ",", word != ")" { words.append(try take().uppercased()) }
                    let options = words.filter(Self.fieldOptions.contains)
                    let kind = words.filter { !Self.fieldOptions.contains($0) }.joined(separator: " ")
                        .replacingOccurrences(of: " < ", with: "<").replacingOccurrences(of: " >", with: ">")
                    guard !kind.isEmpty, type.fields[name] == nil else { throw ParseError(token: name) }
                    type.fields[name] = Field(type: kind, options: options)
                }
                switch try take() {
                case ",": continue
                case ")": break entries
                case let other: throw ParseError(token: other)
                }
            }
            try expect(";")
            guard !types.contains(where: { $0.name == type.name }) else { throw ParseError(token: type.name) }
            types.append(type)
        }
        recordTypes = types
    }

    private static func unquoted(_ token: String) -> String {
        guard token.count >= 2, token.hasPrefix("\""), token.hasSuffix("\"") else { return token }
        return String(token.dropFirst().dropLast())
    }

    private static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        func flush() {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        }
        for character in text {
            if quoted {
                current.append(character)
                if character == "\"" {
                    flush()
                    quoted = false
                }
            } else if character == "\"" {
                flush()
                current = "\""
                quoted = true
            } else if character.isWhitespace {
                flush()
            } else if "(),;<>".contains(character) {
                flush()
                tokens.append(String(character))
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
    }
}
#endif
