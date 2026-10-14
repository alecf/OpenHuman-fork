import Foundation
import OpenHumanAIModelStore

public enum LocalClassifierModels {
    public static let qwen3_1_7b_4bit: ModelManifest = {
        let repository = "mlx-community/Qwen3-1.7B-4bit"
        let revision = "3b1b1768f8f8cf8351c712464f906e86c2b8269e"
        func file(_ path: String, _ size: Int64, _ sha256: String) -> ModelManifest.File {
            ModelManifest.File(
                path: path,
                url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!,
                sizeBytes: size, sha256: sha256)
        }
        return ModelManifest(
            id: "qwen3-1.7b-4bit",
            displayName: "Qwen3 1.7B (4-bit)",
            sourceURL: URL(string: "https://huggingface.co/\(repository)")!,
            revision: revision,
            files: [
                file("config.json", 937, "507a6701220524eb8b283425bf0856a9ae4f21f4052e563896ddd668994b1dc7"),
                file("tokenizer.json", 11_422_654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
                file("model.safetensors", 968_080_210, "0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f"),
            ],
            license: "Apache-2.0",
            format: .mlx,
            declaredContextTokens: 40_960)
    }()

    public static let defaultModel = qwen3_1_7b_4bit

    public static let all: [ModelManifest] = [qwen3_1_7b_4bit]

    public static func classifierID(for manifest: ModelManifest) -> String { "local.\(manifest.id).classifier" }

    public static func sizeText(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 0.95 && gigabytes < 1.05 { return "about 1 GB" }
        if gigabytes >= 1 { return String(format: "about %.1f GB", gigabytes) }
        return String(format: "about %.0f MB", Double(bytes) / 1_000_000)
    }
}
