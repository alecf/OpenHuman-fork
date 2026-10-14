import Foundation
import MailFeatures

actor LearnedBehaviourFile: LearnedBehaviourStoring {
    static let fileName = "learned-behaviour.json"

    private let url: URL

    init(directory: URL) {
        self.url = directory.appendingPathComponent(Self.fileName)
    }

    func load() async -> LearnedBehaviour? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LearnedBehaviour.self, from: data)
    }

    func save(_ behaviour: LearnedBehaviour) async {
        guard let data = try? JSONEncoder().encode(behaviour) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func clear() async {
        try? FileManager.default.removeItem(at: url)
    }
}
