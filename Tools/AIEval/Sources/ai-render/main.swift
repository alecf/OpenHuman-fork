import Foundation
import OpenHumanAI

struct Fixture: Decodable {
    struct Message: Decodable {
        var from: String
        var body: String
    }
    var subject: String
    var messages: [Message]
}

let arguments = CommandLine.arguments
guard arguments.count == 3, let name = PromptName(rawValue: arguments[1]) else {
    let known = PromptName.allCases.map(\.rawValue).joined(separator: ", ")
    FileHandle.standardError.write(Data("usage: ai-render <prompt-id> <fixture.json>\nprompts: \(known)\n".utf8))
    exit(2)
}
let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
let nonce = Untrusted.makeNonce()
let system = try PromptLibrary.standard.system(
    name, values: ["nonce": nonce, "languageRule": PromptLibrary.languageRule(.matchEmail)])
var parts = [UntrustedPart(kind: .subject, id: "subject", text: fixture.subject)]
for (index, message) in fixture.messages.enumerated() {
    parts.append(UntrustedPart(kind: .sender, id: "m\(index + 1)", text: message.from))
    parts.append(UntrustedPart(kind: .emailBody, id: "m\(index + 1)", text: message.body))
}
print("### system (\(system.id))\n\(system.text)\n\n### user\n\(Untrusted.render(parts, nonce: nonce))")
