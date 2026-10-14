import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAITesting

@Suite struct EmbeddingSpaceTests {
    private func base() -> EmbeddingSpace {
        EmbeddingSpace(providerID: "apple.nl.sentence", modelVersion: "27A1+abc", dimension: 512, maxInputTokens: 256,
                       queryPrefix: "", documentPrefix: "", recipe: EmbeddingRecipe.mailV1)
    }

    @Test func theIDIsSixteenHexCharactersAndStable() {
        let space = base()
        #expect(space.id.count == 16)
        #expect(space.id.allSatisfy { $0.isHexDigit })
        #expect(base().id == space.id)
        #expect(space.isConsistent)
    }

    @Test func everyFieldChangesTheID() {
        let original = base()
        var variants: [EmbeddingSpace] = []
        var space = original
        space.providerID = "apple.nl.contextual"; variants.append(space)
        space = original; space.modelVersion = "27A2+abc"; variants.append(space)
        space = original; space.dimension = 384; variants.append(space)
        space = original; space.maxInputTokens = nil; variants.append(space)
        space = original; space.queryPrefix = "query: "; variants.append(space)
        space = original; space.documentPrefix = "passage: "; variants.append(space)
        space = original; space.recipe = "mail.v2"; variants.append(space)
        for variant in variants {
            #expect(!variant.isConsistent)
            let rebuilt = EmbeddingSpace(
                providerID: variant.providerID, modelVersion: variant.modelVersion, dimension: variant.dimension,
                maxInputTokens: variant.maxInputTokens, queryPrefix: variant.queryPrefix,
                documentPrefix: variant.documentPrefix, recipe: variant.recipe)
            #expect(rebuilt.id != original.id)
        }
        #expect(Set(variants.map {
            EmbeddingSpace(providerID: $0.providerID, modelVersion: $0.modelVersion, dimension: $0.dimension,
                           maxInputTokens: $0.maxInputTokens, queryPrefix: $0.queryPrefix,
                           documentPrefix: $0.documentPrefix, recipe: $0.recipe).id
        }).count == variants.count)
    }

    @Test func theDescriptorRoundTripsAsJSON() throws {
        let space = base()
        let decoded = try JSONDecoder().decode(EmbeddingSpace.self, from: JSONEncoder().encode(space))
        #expect(decoded == space)
        #expect(decoded.isConsistent)
    }
}

@Suite struct FakeEmbeddingProviderTests {
    @Test func vectorsAreUnitLengthAndInInputOrder() async throws {
        let provider = FakeEmbeddingProvider(dimension: 64)
        let texts = ["team offsite in May", "invoice 4471 attached", "", "a b c"]
        let batch = try await provider.embed(texts, role: .document)
        #expect(batch.count == texts.count)
        for vector in batch {
            #expect(vector.count == 64)
            #expect(EmbeddingMath.isUnitLength(vector))
        }
        for (index, text) in texts.enumerated() {
            #expect(try await provider.embed([text], role: .document) == [batch[index]])
        }
    }

    @Test func synonymsAreCloserThanUnrelatedWords() async throws {
        let provider = FakeEmbeddingProvider()
        let retreat = try await provider.embed("moving our team retreat", role: .query)
        let offsite = try await provider.embed("Offsite dates: can we reschedule the offsite?", role: .document)
        let invoice = try await provider.embed("Invoice 4471 from the office supply shop", role: .document)
        #expect(EmbeddingMath.dot(retreat, offsite) > EmbeddingMath.dot(retreat, invoice) + 0.1)
        let receipt = try await provider.embed("receipt for the standing desk", role: .query)
        let order = try await provider.embed("Order confirmation: ergonomic workstation", role: .document)
        #expect(EmbeddingMath.dot(receipt, order) > EmbeddingMath.dot(receipt, offsite))
    }

    @Test func theSameTextAlwaysGivesTheSameVector() async throws {
        let a = FakeEmbeddingProvider(dimension: 128)
        let b = FakeEmbeddingProvider(dimension: 128)
        #expect(try await a.embed("Harbor Air itinerary", role: .document)
                == b.embed("Harbor Air itinerary", role: .document))
    }

    @Test func failuresAvailabilityAndCalls() async throws {
        let provider = FakeEmbeddingProvider()
        provider.failNext(.timeout)
        let first = await aiError { _ = try await provider.embed(["x"], role: .document) }
        #expect(first == .timeout)
        _ = try await provider.embed(["x", "y"], role: .document)
        #expect(provider.embedCalls == 2)
        #expect(provider.embeddedTexts == 2)
        #expect(provider.isLoaded)
        await provider.unload()
        #expect(!provider.isLoaded)

        provider.setAvailability(.unavailable(reason: .modelNotReady))
        #expect(await aiError { _ = try await provider.space() } == .unavailable(.modelNotReady))
        #expect(await aiError { _ = try await provider.embed(["x"], role: .query) } == .unavailable(.modelNotReady))
    }

    @Test func theSpaceDescribesTheProvider() async throws {
        let provider = FakeEmbeddingProvider(dimension: 96, maxInputTokens: 40, queryPrefix: "query: ",
                                             documentPrefix: "passage: ")
        let space = try await provider.space()
        #expect(space.providerID == provider.id)
        #expect(space.dimension == 96)
        #expect(space.maxInputTokens == 40)
        #expect(space.prefix(for: .query) == "query: ")
        #expect(space.prefix(for: .document) == "passage: ")
        #expect(space.recipe == EmbeddingRecipe.mailV1)
    }

    @Test func onlyOnDeviceProvidersPassTheGuard() {
        #expect(EmbeddingProviders.onDeviceOnly(FakeEmbeddingProvider()) != nil)
        let remote = FakeEmbeddingProvider(dataLocation: .thirdParty(vendor: "Example"))
        #expect(EmbeddingProviders.onDeviceOnly(remote) == nil)
        let cloud = FakeEmbeddingProvider(dataLocation: .appleCloud)
        #expect(EmbeddingProviders.onDeviceOnly(cloud) == nil)
        #expect(EmbeddingProviders.evalChosenDefault == nil)
    }
}

@Suite struct EmbeddingRecipeTests {
    @Test func theRecipeHasSubjectSenderBodyAndAttachmentsOnly() {
        let text = EmbeddingRecipe.document(.init(
            subject: "Offsite dates", senderName: "Dana Ruiz", body: "Can we move it?\n",
            attachmentNames: ["venue.pdf", "map.png"]))
        #expect(text == "Subject: Offsite dates\nFrom: Dana Ruiz\nCan we move it?\nAttachments: venue.pdf, map.png")
        let bare = EmbeddingRecipe.document(.init(subject: "Hi", senderName: nil, body: ""))
        #expect(bare == "Subject: Hi")
    }

    @Test func fieldsAreCappedAndHeadersStayOnOneLine() {
        let long = String(repeating: "x", count: 1_000)
        let text = EmbeddingRecipe.document(.init(
            subject: "a\nb" + long, senderName: long, body: String(repeating: "é", count: 40_000),
            attachmentNames: (0..<20).map { "file\($0).pdf" }))
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("Subject: a b"))
        #expect(lines[0].count == "Subject: ".count + EmbeddingRecipe.subjectCharacters)
        #expect(lines[1].count == "From: ".count + EmbeddingRecipe.senderCharacters)
        #expect(lines[2].utf8.count <= EmbeddingRecipe.bodyBytes)
        #expect(lines[2].utf8.count > EmbeddingRecipe.bodyBytes - 4)
        #expect(lines[3] == "Attachments: " + (0..<10).map { "file\($0).pdf" }.joined(separator: ", "))
    }

    @Test func fitCutsAtAWordBoundaryWithTheProviderCounterAndThePrefix() async {
        let provider = FakeEmbeddingProvider()
        let text = "one two three four five six seven"
        let cut = await EmbeddingRecipe.fit(text, prefix: "passage: ", maxTokens: 5) { await provider.countTokens($0) }
        #expect(cut == "one two three four")
        #expect(await EmbeddingRecipe.fit(text, prefix: "", maxTokens: 100) { await provider.countTokens($0) } == text)
        #expect(await EmbeddingRecipe.fit(text, prefix: "", maxTokens: nil) { _ in Int.max } == text)
        #expect(await EmbeddingRecipe.fit(text, prefix: "a b c", maxTokens: 2) { await provider.countTokens($0) } == "")
    }

    @Test func theQueryTextJoinsFreeTextTerms() {
        #expect(EmbeddingRecipe.query(["moving", "team\nretreat", " "]) == "moving team retreat")
    }
}

@Suite struct EmbeddingProbeTests {
    @Test func identicalProbesMatchAndChangedOnesDoNot() async throws {
        let provider = FakeEmbeddingProvider(dimension: 64)
        let stored = try await provider.embed(EmbeddingProbe.sentences, role: .document)
        #expect(EmbeddingProbe.sentences.count == 16)
        #expect(EmbeddingProbe.matches(stored, stored))
        var changed = stored
        changed[3] = EmbeddingMath.normalized(changed[3].enumerated().map { $0.offset == 0 ? $0.element + 0.2 : $0.element })
        #expect(!EmbeddingProbe.matches(stored, changed))
        #expect(!EmbeddingProbe.matches(stored, Array(stored.dropLast())))
        #expect(!EmbeddingProbe.matches([], []))
        #expect(EmbeddingProbe.digest(stored) == EmbeddingProbe.digest(stored))
        #expect(EmbeddingProbe.digest(stored) != EmbeddingProbe.digest(changed))
    }

    @Test func mathHelpers() {
        #expect(EmbeddingMath.normalized([Float]([0, 0, 0])) == [1, 0, 0])
        #expect(EmbeddingMath.isUnitLength(EmbeddingMath.normalized([Float]([3, 4]))))
        #expect(EmbeddingMath.mean([[1, 2], [3, 4]]) == [2, 3])
        #expect(EmbeddingMath.mean([]) == nil)
        #expect(EmbeddingMath.dot([1, 2, 3], [1, 1]) == 3)
    }
}
