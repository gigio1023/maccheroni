import Foundation
import Testing
@testable import MaccheroniApp

struct GlossaryRecoveryTests {
    @Test
    func noOpRoundTripPreservesCommentsBlankLinesAndLineEndings() {
        let source = "# owner note\r\n\r\n# category: people\r\n  Ada Lovelace  \r\n# keep this context\r\n# category: terms\r\nCoreAudio process tap\r\n"
        let document = GlossaryDraftDocument(text: source)

        #expect(document.serialized() == source)
        #expect(document.entries.map(\.term) == ["Ada Lovelace", "CoreAudio process tap"])
        #expect(document.entries.map(\.category) == [.people, .terms])
    }

    @Test
    func onlyCanonicalCategoryMarkersChangeFollowingEntryCategories() {
        let document = GlossaryDraftDocument(text: "# category: people\nJina\n# ordinary note\nMina\n# category: places\nPangyo\n")

        #expect(document.entries.map(\.term) == ["Jina", "Mina", "Pangyo"])
        #expect(document.entries.map(\.category) == [.people, .people, .places])
    }

    @Test
    func commentLikeAndMultilineTermsAreRejectedWithoutChangingDocument() throws {
        var document = GlossaryDraftDocument(text: "# category: terms\nMaccheroni\n")
        let original = document.serialized()

        #expect(throws: GlossaryDraftError.commentLikeTerm) {
            try document.add(term: "  # hidden term  ", category: .terms)
        }
        #expect(throws: GlossaryDraftError.multilineTerm) {
            try document.add(term: "first\nsecond", category: .terms)
        }
        #expect(document.serialized() == original)
    }

    @Test
    func canonicalNormalizationAllowsCaseVariantsAndDeduplicatesExactNFCValues() throws {
        var document = GlossaryDraftDocument(text: "")
        let decomposed = String(repeating: "e\u{301}", count: 256)

        try document.add(term: "Maccheroni", category: .terms)
        try document.add(term: "maccheroni", category: .terms)
        try document.add(term: decomposed, category: .terms)

        #expect(document.entries.map(\.term).prefix(2) == ["Maccheroni", "maccheroni"])
        #expect(document.entries.last?.term.unicodeScalars.count == 256)
        #expect(throws: GlossaryDraftError.duplicateTerm) {
            try document.add(
                term: decomposed.precomposedStringWithCanonicalMapping,
                category: .terms
            )
        }
    }

    @Test
    func deletingThenRestoringEntriesPreservesOriginalDecoderOrder() {
        var document = GlossaryDraftDocument(text: "# category: terms\nfirst\nsecond\nthird\nfourth\n")

        let removal = document.removeEntries(at: IndexSet([1, 2]))
        #expect(document.entries.map(\.term) == ["first", "fourth"])

        document.restore(removal)
        #expect(document.entries.map(\.term) == ["first", "second", "third", "fourth"])
        #expect(document.serialized() == "# category: terms\nfirst\nsecond\nthird\nfourth\n")
    }

    @Test
    func addedEntryGetsAnExplicitCategoryWithoutRewritingExistingLines() throws {
        var document = GlossaryDraftDocument(text: "# personal ordering\n# category: people\nJina")

        try document.add(term: "Pangyo", category: .places)

        #expect(document.serialized() == "# personal ordering\n# category: people\nJina\n# category: places\nPangyo\n")
        #expect(document.entries.map(\.term) == ["Jina", "Pangyo"])
    }

    @Test
    func loadFailureRemainsSaveBlockingAfterItsAlertIsDismissed() {
        enum FixtureError: LocalizedError {
            case invalidUTF8
            var errorDescription: String? { "The glossary is not valid UTF-8." }
        }
        var state = GlossaryEditorState {
            throw FixtureError.invalidUTF8
        }

        #expect(state.document.serialized().isEmpty)
        #expect(state.presentedErrorMessage == "The glossary is not valid UTF-8.")
        #expect(!state.savingAllowed)

        state.presentedErrorMessage = nil
        #expect(!state.savingAllowed)
    }

    @Test
    func missingGlossaryLoadsAsEditableEmptyDocument() {
        let state = GlossaryEditorState { "" }

        #expect(state.document.entries.isEmpty)
        #expect(state.presentedErrorMessage == nil)
        #expect(state.savingAllowed)
    }
}
