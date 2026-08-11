import AVFAudio
import CryptoKit
import Foundation
import MaccheroniCore
import MaccheroniMerge
import MaccheroniPostprocess
import Testing
@testable import MaccheroniApp

struct AppShellTests {
    @Test
    func profileRegistryContainsTheFourV1ProfilesWithPinnedModelsAndMetrics() throws {
        let profiles = try AppProfileRegistry.load()

        #expect(profiles.count == 4)
        #expect(Set(profiles.map(\.id)) == Set(AppProfileID.allCases))

        for profile in profiles {
            #expect(!profile.languageCoverage.isEmpty)
            #expect(!profile.models.isEmpty)
            for model in profile.models {
                #expect(!model.hfModelID.isEmpty)
                #expect(model.revision.count == 40)
                #expect(model.revision.allSatisfy { $0.isHexDigit })
                #expect(!model.quantization.isEmpty)
            }
        }

        let korean = try #require(profiles.first(where: { $0.id == .koreanITMeeting }))
        #expect(korean.languageCoverage == ["ko", "en", "it", "multilingual"])
        #expect(korean.metrics == [
            BenchmarkMetric(key: "cer", value: 0.08123249299719888, display: "CER 0.081"),
            BenchmarkMetric(key: "wer", value: 0.14102564102564102, display: "WER 0.141"),
            BenchmarkMetric(key: "term_recall", value: 0.95, display: "Term recall 0.950"),
        ])

        let italian = try #require(profiles.first(where: { $0.id == .italianDialogue }))
        #expect(italian.languageCoverage == ["it"])
        #expect(italian.metrics == [
            BenchmarkMetric(key: "cer", value: 0.033112582781456956, display: "CER 0.033"),
            BenchmarkMetric(key: "wer", value: 0.0847457627118644, display: "WER 0.085"),
            BenchmarkMetric(key: "term_recall", value: 0.7777777777777778, display: "Term recall 0.778"),
            BenchmarkMetric(key: "backchannels", value: 1, display: "Backchannels 7/7"),
        ])

        let english = try #require(profiles.first(where: { $0.id == .englishMeeting }))
        #expect(english.languageCoverage == ["en"])
        #expect(english.metrics.isEmpty)

        let automatic = try #require(profiles.first(where: { $0.id == .automatic }))
        #expect(automatic.languageCoverage == ["multilingual"])
        #expect(automatic.metrics.isEmpty)
    }

    @Test
    func repositoryAtomicallySavesAndLoadsItsIndexWithoutChangingOriginalInput() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(root: root)
        let inputURL = root.appendingPathComponent("original.wav")
        try Data("original input bytes".utf8).write(to: inputURL)
        let inputHash = try appShellSHA256(of: inputURL)
        let record = appShellRecord(sourceURL: inputURL)

        try repository.saveRecords([record])
        var replacement = record
        replacement.displayName = "Renamed meeting"
        replacement.state = .done
        try repository.saveRecords([replacement])

        #expect(try repository.loadRecords() == [replacement])
        #expect(try appShellSHA256(of: inputURL) == inputHash)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains(where: { $0.hasPrefix(".library-") }))
    }

    @Test
    func repositoryLoadsOnlyHashVerifiedArtifactsAndLeavesRawAndInputUntouched() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try appShellRunFixture(in: root)
        let rawData = try Data(contentsOf: fixture.rawURL)
        let segmentsData = try Data(contentsOf: fixture.segmentsURL)
        let rawHash = try appShellSHA256(of: fixture.rawURL)
        let inputHash = try appShellSHA256(of: fixture.inputURL)

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        #expect(loaded.manifest.runID == "fixture-run")
        #expect(loaded.transcript.segments == fixture.transcript.segments)
        #expect(loaded.conflicts == fixture.conflicts)
        #expect(try appShellSHA256(of: fixture.rawURL) == rawHash)
        #expect(try appShellSHA256(of: fixture.inputURL) == inputHash)

        try segmentsData.write(to: fixture.segmentsURL)
        try Data("tampered raw transcript".utf8).write(to: fixture.rawURL)
        #expect(throws: LibraryRepositoryError.self) {
            try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        }
        try rawData.write(to: fixture.rawURL)
        #expect(try appShellSHA256(of: fixture.rawURL) == rawHash)

        try Data("tampered transcript".utf8).write(to: fixture.segmentsURL)
        #expect(throws: LibraryRepositoryError.self) {
            try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        }
        #expect(try appShellSHA256(of: fixture.rawURL) == rawHash)
        #expect(try appShellSHA256(of: fixture.inputURL) == inputHash)
    }

    @Test
    func repositoryPrefersVerifiedPostprocessAndKeepsMergedAndRawImmutable() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var fixture = try appShellRunFixture(in: root)
        let mergedHash = try appShellSHA256(of: fixture.segmentsURL)
        let rawHash = try appShellSHA256(of: fixture.rawURL)
        let postprocessDirectory = fixture.runURL.appendingPathComponent(
            "postprocess",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: postprocessDirectory,
            withIntermediateDirectories: false
        )
        var reviewed = fixture.transcript
        reviewed.segments[0].flags = ["uncertain", "conflict"]
        let postprocessSegments = postprocessDirectory.appendingPathComponent(
            "segments.json"
        )
        let postprocessConflicts = postprocessDirectory.appendingPathComponent(
            "conflicts.json"
        )
        try JSONEncoder().encode(reviewed).write(to: postprocessSegments)
        try JSONEncoder().encode([
            PostprocessConflict(
                segmentIndex: 0,
                originalText: fixture.transcript.segments[0].text,
                candidateText: "Glossary candidate",
                reason: "Review the glossary spelling."
            ),
        ]).write(to: postprocessConflicts)
        fixture.manifest.postprocess = ManifestPostprocess(
            backend: BackendDescriptor(name: "codex-app-server", version: "codex-cli test"),
            modelID: CodexPostprocessBackend.modelName
        )
        fixture.manifest.artifacts += [
            Artifact(
                kind: "postprocess_segments",
                path: "postprocess/segments.json",
                sha256: try appShellSHA256(of: postprocessSegments)
            ),
            Artifact(
                kind: "postprocess_conflicts",
                path: "postprocess/conflicts.json",
                sha256: try appShellSHA256(of: postprocessConflicts)
            ),
        ]
        try appShellWriteManifest(fixture.manifest, to: fixture.runURL)

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        #expect(loaded.transcript.segments[0].flags == ["uncertain", "conflict"])
        #expect(loaded.conflicts[0].candidates.contains("Glossary candidate"))
        #expect(loaded.conflicts[0].reason.contains("Review the glossary spelling."))
        #expect(try appShellSHA256(of: fixture.segmentsURL) == mergedHash)
        #expect(try appShellSHA256(of: fixture.rawURL) == rawHash)

        var invalidReview = reviewed
        invalidReview.segments[0].text = "Changed despite review"
        try JSONEncoder().encode(invalidReview).write(to: postprocessSegments)
        let postprocessIndex = try #require(fixture.manifest.artifacts.firstIndex {
            $0.kind == "postprocess_segments"
        })
        fixture.manifest.artifacts[postprocessIndex].sha256 = try appShellSHA256(
            of: postprocessSegments
        )
        try appShellWriteManifest(fixture.manifest, to: fixture.runURL)
        #expect(throws: LibraryRepositoryError.self) {
            try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        }
        #expect(try appShellSHA256(of: fixture.segmentsURL) == mergedHash)
        #expect(try appShellSHA256(of: fixture.rawURL) == rawHash)

        try JSONEncoder().encode(reviewed).write(to: postprocessSegments)
        fixture.manifest.artifacts[postprocessIndex].sha256 = try appShellSHA256(
            of: postprocessSegments
        )
        try appShellWriteManifest(fixture.manifest, to: fixture.runURL)
        try Data("tampered postprocess".utf8).write(to: postprocessSegments)
        #expect(throws: LibraryRepositoryError.self) {
            try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        }
        #expect(try appShellSHA256(of: fixture.segmentsURL) == mergedHash)
        #expect(try appShellSHA256(of: fixture.rawURL) == rawHash)
    }

    @Test
    func repositoryRejectsUnsafeArtifactPathsBeforeReadingOutsideTheRun() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var fixture = try appShellRunFixture(in: root)
        fixture.manifest.artifacts[0] = Artifact(
            kind: "merged_segments",
            path: "../outside.json",
            sha256: String(repeating: "0", count: 64)
        )
        try appShellWriteManifest(fixture.manifest, to: fixture.runURL)

        #expect(throws: LibraryRepositoryError.self) {
            try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        }
    }

    @Test
    func repositoryDisplaysVerifiedTranslationWithoutChangingCanonicalStructure() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var fixture = try appShellRunFixture(
            in: root,
            text: "Ciao da Maccheroni"
        )
        let inputHash = try appShellSHA256(of: fixture.inputURL)
        let mergedHash = try appShellSHA256(of: fixture.segmentsURL)
        let rawHash = try appShellSHA256(of: fixture.rawURL)
        let translatedText = "Hello from Maccheroni"
        let policy = CodexPostprocessBackend.defaultBatchPolicy
        let inputTextUTF8Bytes = fixture.transcript.segments[0].text.utf8.count
        let outputTextUTF8Bytes = translatedText.utf8.count
        let responseUTF8Bytes = try JSONEncoder().encode([
            "translations": [SegmentTranslation(
                segmentIndex: 0,
                translatedText: translatedText
            )],
        ]).count
        let estimatedOutputTokens = policy.estimatedOutputTokens(
            inputTextUTF8Bytes: inputTextUTF8Bytes,
            segmentCount: 1
        )
        let acceptedOutputTokenUpperBound = policy.acceptedOutputTokenUpperBound(
            responseUTF8Bytes: responseUTF8Bytes,
            segmentCount: 1
        )
        let promptUTF8Bytes = 640
        let translation = TranslationDocument(
            targetLanguage: "en",
            sourceSegmentsSHA256: mergedHash,
            batches: [TranslationBatchRecord(
                batchIndex: 0,
                segmentIndices: [0],
                promptUTF8Bytes: promptUTF8Bytes,
                inputTextUTF8Bytes: inputTextUTF8Bytes,
                estimatedOutputTokens: estimatedOutputTokens,
                outputTextUTF8Bytes: outputTextUTF8Bytes,
                responseUTF8Bytes: responseUTF8Bytes,
                acceptedOutputTokenUpperBound: acceptedOutputTokenUpperBound
            )],
            translations: [SegmentTranslation(
                segmentIndex: 0,
                translatedText: translatedText
            )]
        )
        let postprocessDirectory = fixture.runURL.appendingPathComponent(
            "postprocess",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: postprocessDirectory,
            withIntermediateDirectories: false
        )
        let translationURL = postprocessDirectory.appendingPathComponent(
            "translation.json"
        )
        try JSONEncoder().encode(translation).write(to: translationURL)
        fixture.manifest.postprocess = ManifestPostprocess(
            backend: BackendDescriptor(
                name: "codex-app-server",
                version: "codex-cli fixture"
            ),
            modelID: CodexPostprocessBackend.modelName,
            mode: .translation,
            targetLanguage: "en",
            sourceSegmentsSHA256: mergedHash,
            batching: policy.manifest(
                batchesPlanned: 1,
                maximumObservedPromptUTF8Bytes: promptUTF8Bytes,
                maximumObservedInputTextUTF8Bytes: inputTextUTF8Bytes,
                maximumObservedEstimatedOutputTokens: estimatedOutputTokens,
                maximumObservedOutputTextUTF8Bytes: outputTextUTF8Bytes,
                maximumObservedResponseUTF8Bytes: responseUTF8Bytes,
                maximumObservedAcceptedOutputTokenUpperBound:
                    acceptedOutputTokenUpperBound
            )
        )
        fixture.manifest.artifacts.append(Artifact(
            kind: "postprocess_translation",
            path: "postprocess/translation.json",
            sha256: try appShellSHA256(of: translationURL)
        ))
        try appShellWriteManifest(fixture.manifest, to: fixture.runURL)

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        let sourceSegment = fixture.transcript.segments[0]
        let displayed = try #require(loaded.transcript.segments.first)
        #expect(displayed.text == translatedText)
        #expect(displayed.speaker == sourceSegment.speaker)
        #expect(displayed.startS == sourceSegment.startS)
        #expect(displayed.endS == sourceSegment.endS)
        #expect(displayed.language == sourceSegment.language)
        #expect(displayed.confidence == sourceSegment.confidence)
        #expect(displayed.flags?.contains("uncertain") == true)
        #expect(loaded.requiresReview)
        #expect(loaded.conflicts.isEmpty)
        #expect(loaded.segments[0].conflict == nil)
        var exportRecord = appShellRecord(sourceURL: fixture.inputURL)
        exportRecord.conflictResolutions[0] = "Alternative"
        let exported = try TranscriptExporter.correctedSegmentsDocument(
            run: loaded,
            record: exportRecord
        )
        #expect(exported.segments[0].text == translatedText)
        #expect(try appShellSHA256(of: fixture.inputURL) == inputHash)
        #expect(try appShellSHA256(of: fixture.segmentsURL) == mergedHash)
        #expect(try appShellSHA256(of: fixture.rawURL) == rawHash)

        var tampered = translation
        tampered.batches[0].inputTextUTF8Bytes += 1
        try JSONEncoder().encode(tampered).write(to: translationURL)
        let artifactIndex = try #require(fixture.manifest.artifacts.firstIndex {
            $0.kind == "postprocess_translation"
        })
        fixture.manifest.artifacts[artifactIndex].sha256 = try appShellSHA256(
            of: translationURL
        )
        try appShellWriteManifest(fixture.manifest, to: fixture.runURL)
        #expect(throws: LibraryRepositoryError.self) {
            try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        }
        #expect(try appShellSHA256(of: fixture.inputURL) == inputHash)
        #expect(try appShellSHA256(of: fixture.segmentsURL) == mergedHash)
        #expect(try appShellSHA256(of: fixture.rawURL) == rawHash)
    }

    @Test @MainActor
    func appLanguageAndPostprocessDefaultsFollowD16AndCodexReadiness() throws {
        #expect(AppLanguage.english.rawValue == "en")
        #expect(AppLanguage.english.locale.identifier == "en")
        #expect(appString("Start Recording", locale: Locale(identifier: "en")) == "Start Recording")
        #expect(appString("Start Recording", locale: Locale(identifier: "ko")) == "녹음 시작")
        #expect(appString("Start Recording", locale: Locale(identifier: "it")) == "Inizia a registrare")
        #expect(String(localized: appLocalized("Start Recording", locale: Locale(identifier: "ko"))) == "녹음 시작")
        #expect(Set(appResourcesBundle.localizations.map { $0.lowercased() }).isSuperset(of: [
            "en", "ko", "it", "ja", "zh-hans", "es", "fr", "de", "pt", "ru",
        ]))

        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "MaccheroniAppShellTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let languageStore = AppLanguageStore(defaults: defaults)
        #expect(languageStore.language == .english)
        languageStore.rawValue = AppLanguage.korean.rawValue
        #expect(languageStore.language == .korean)
        #expect(defaults.string(forKey: AppLanguageStore.defaultsKey) == "ko")

        let model = try MaccheroniAppModel(
            repository: LibraryRepository(root: root),
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        #expect(model.selectedProfileID == .koreanITMeeting)
        #expect(model.selectedPostprocess == .local)
        #expect(model.selectedPostprocessMode == .correction)
        #expect(model.selectedTranslationTarget == .english)
        defaults.set(PostprocessChoice.codex.rawValue, forKey: "selectedPostprocess")
        defaults.set(
            PostprocessOperationChoice.translation.rawValue,
            forKey: "selectedPostprocessMode"
        )
        defaults.set(AppLanguage.italian.rawValue, forKey: "selectedTranslationTarget")
        model.syncPostprocessSelectionsFromDefaults()
        #expect(model.selectedPostprocess == .codex)
        #expect(model.selectedPostprocessMode == .translation)
        #expect(model.selectedTranslationTarget == .italian)

        let authenticatedSuite = "MaccheroniAuthenticatedDefaults-\(UUID().uuidString)"
        let authenticatedDefaults = try #require(
            UserDefaults(suiteName: authenticatedSuite)
        )
        authenticatedDefaults.removePersistentDomain(forName: authenticatedSuite)
        defer {
            authenticatedDefaults.removePersistentDomain(forName: authenticatedSuite)
        }
        let authenticated = try MaccheroniAppModel(
            repository: LibraryRepository(
                root: root.appendingPathComponent("authenticated", isDirectory: true)
            ),
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: authenticatedDefaults,
            codexAvailability: .authenticated(version: "codex-cli fixture")
        )
        #expect(authenticated.selectedPostprocess == .codex)
        #expect(authenticated.selectedPostprocessMode == .correction)
        #expect(authenticated.selectedTranslationTarget == .english)

        let explicitSuite = "MaccheroniExplicitDefaults-\(UUID().uuidString)"
        let explicitDefaults = try #require(UserDefaults(suiteName: explicitSuite))
        explicitDefaults.removePersistentDomain(forName: explicitSuite)
        explicitDefaults.set(PostprocessChoice.none.rawValue, forKey: "selectedPostprocess")
        defer { explicitDefaults.removePersistentDomain(forName: explicitSuite) }
        let explicit = try MaccheroniAppModel(
            repository: LibraryRepository(
                root: root.appendingPathComponent("explicit", isDirectory: true)
            ),
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: explicitDefaults,
            codexAvailability: .authenticated(version: "codex-cli fixture")
        )
        #expect(explicit.selectedPostprocess == .none)
    }

    @Test
    func stringCatalogKeepsD16LocaleStateAndPlaceholderParity() throws {
        let locales = [
            "de", "en", "es", "fr", "it", "ja", "ko", "pt", "ru", "zh-Hans",
        ]
        let reviewLocales: Set<String> = ["en", "ko", "it"]
        let requiredFinalKeys: Set<String> = [
            "%lld bytes",
            "A new setup selects Codex only when its CLI is signed in; otherwise it selects Local. Codex receives bounded transcript text, the active profile's full glossary and its hash, post-processing instructions, and the target language when translating. Audio never leaves this Mac.",
            "Audio stays on this Mac. Transcription runs locally; during post-processing Codex receives bounded transcript text, the active profile's full glossary and its hash, post-processing instructions, and the target language when translating.",
            "Batches Planned",
            "Check Again",
            "Checking availability…",
            "Choose Folder…",
            "Chooses the language the transcript is translated into.",
            "Codex CLI",
            "Codex receives bounded transcript text, the active profile's full glossary and its hash, post-processing instructions, and the target language when translating. Audio and source artifacts stay on this Mac unchanged.",
            "Codex CLI was not found. Install it and run codex login in Terminal, or select Local meanwhile.",
            "Codex is installed, but its sign-in status could not be checked. Try again or select Local meanwhile.",
            "Codex is installed but not signed in. Run codex login in Terminal, or select Local meanwhile.",
            "Your Codex sign-in is expired or too close to expiry. Refresh or sign in through Codex, then retry, or select Local.",
            "Codex is signed in and ready.",
            "Correct",
            "Directory choices apply the next time Maccheroni launches. Existing recordings and run artifacts stay where they are.",
            "Input Mode",
            "Interrupted",
            "Installed and signed in",
            "Installed, but sign-in status could not be checked.",
            "Installed, not signed in. Run codex login in Terminal.",
            "Largest Accepted Output Bound",
            "Largest Batch Estimate",
            "Largest Batch Input",
            "Largest Raw Response",
            "MACCHERONI_LIBRARY_ROOT controls the recording and run paths for this launch.",
            "Model ID",
            "Operation",
            "Output Estimate Formula",
            "Output Planning Budget",
            "Output Token Limit",
            "Planned Model",
            "Play this segment from the source audio.",
            "Prompt Limit",
            "Rename this speaker everywhere in this transcript.",
            "Segments per Batch",
            "Service-managed (limit unavailable)",
            "Source Segments SHA-256",
            "Target Language",
            "Text only",
            "This name applies to every %@ segment in exports.",
            "Translate",
            "Translate Into",
            "Use Default",
        ]
        let catalogURL = try #require(appResourcesBundle.url(
            forResource: "Localizable",
            withExtension: "xcstrings"
        ))
        let catalog = try JSONDecoder().decode(
            AppShellStringCatalog.self,
            from: Data(contentsOf: catalogURL)
        )

        #expect(catalog.sourceLanguage == "en")
        #expect(catalog.strings.count == 269)
        #expect(requiredFinalKeys.isSubset(of: Set(catalog.strings.keys)))
        for (key, entry) in catalog.strings {
            #expect(Set(entry.localizations.keys) == Set(locales), "locale parity: \(key)")
            let english = try #require(entry.localizations["en"]?.stringUnit.value)
            #expect(english == key, "English source parity: \(key)")
            let expectedPlaceholders = appShellPlaceholderSignature(english)
            for locale in locales {
                let unit = try #require(entry.localizations[locale]?.stringUnit)
                let expectedState = reviewLocales.contains(locale)
                    ? "needs_review"
                    : "translated"
                #expect(unit.state == expectedState, "review state: \(locale) / \(key)")
                #expect(
                    appShellPlaceholderSignature(unit.value) == expectedPlaceholders,
                    "placeholder parity: \(locale) / \(key)"
                )
            }
        }

        for locale in locales {
            let resourceLocale = try #require(appResourcesBundle.localizations.first {
                $0.caseInsensitiveCompare(locale) == .orderedSame
            })
            let localizedBundlePath = try #require(appResourcesBundle.path(
                forResource: resourceLocale,
                ofType: "lproj"
            ))
            let stringsURL = URL(fileURLWithPath: localizedBundlePath)
                .appendingPathComponent("Localizable.strings")
            let plist = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: stringsURL),
                format: nil
            )
            let derived = try #require(plist as? [String: String])
            #expect(Set(derived.keys) == Set(catalog.strings.keys))
            for (key, entry) in catalog.strings {
                #expect(derived[key] == entry.localizations[locale]?.stringUnit.value)
            }
        }
    }

    @Test @MainActor
    func modelDownloadErrorsLocalizeEnglishKoreanAndItalianInterpolations() {
        let locales = [
            Locale(identifier: "en"),
            Locale(identifier: "ko"),
            Locale(identifier: "it"),
        ]
        let expectedUnavailable = [
            "The Hugging Face command-line tool (hf) is not installed. Install it, then try again.",
            "Hugging Face 명령줄 도구(hf)가 설치되어 있지 않습니다. 설치한 뒤 다시 시도하세요.",
            "Lo strumento da riga di comando Hugging Face (hf) non è installato. Installalo, quindi riprova.",
        ]
        let expectedFailure = [
            "The Hugging Face download command failed (exit 7): unavailable",
            "Hugging Face download 명령이 실패했습니다(종료 코드 7): unavailable",
            "Il comando Hugging Face download non è riuscito (uscita 7): unavailable",
        ]
        let expectedLaunch = [
            "The Hugging Face command-line tool could not start: unavailable",
            "Hugging Face 명령줄 도구를 시작할 수 없습니다: unavailable",
            "Impossibile avviare lo strumento da riga di comando Hugging Face: unavailable",
        ]
        let expectedMissing = [
            "The Hugging Face command finished, but the pinned model location is missing: /tmp/model",
            "Hugging Face 명령이 완료되었지만 고정된 모델 위치가 없습니다: /tmp/model",
            "Il comando Hugging Face è terminato, ma manca la posizione del modello fissato: /tmp/model",
        ]

        for (index, locale) in locales.enumerated() {
            #expect(appString("The Hugging Face command-line tool (hf) is not installed. Install it, then try again.", locale: locale) == expectedUnavailable[index])
            #expect(appString("The Hugging Face \("download") command failed (exit \(Int64(7))): \("unavailable")", locale: locale) == expectedFailure[index])
            #expect(appString("The Hugging Face command-line tool could not start: \("unavailable")", locale: locale) == expectedLaunch[index])
            #expect(appString("The Hugging Face command finished, but the pinned model location is missing: \("/tmp/model")", locale: locale) == expectedMissing[index])
        }
    }

    @Test @MainActor
    func finishingRunDoesNotReplaceAnotherSelectedTranscript() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(root: root)
        let runA = try appShellRunFixture(in: root, runID: "run-a", text: "Transcript A")
        let runB = try appShellRunFixture(in: root, runID: "run-b", text: "Transcript B")
        var recordA = appShellRecord(sourceURL: runA.inputURL)
        recordA.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        recordA.displayName = "Meeting A"
        var recordB = appShellRecord(sourceURL: runB.inputURL)
        recordB.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        recordB.displayName = "Meeting B"
        recordB.runURL = runB.runURL
        recordB.state = .done
        try repository.saveRecords([recordA, recordB])
        let runner = AppShellControllableRunner()
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: runner,
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        model.select(.record(recordA.id))
        model.retrySelectedTranscription()
        await appShellWait { runner.isWaiting }
        model.select(.record(recordB.id))
        #expect(model.selectedRun?.manifest.runID == "run-b")

        runner.succeed(with: runA.runURL)
        await appShellWait { !model.isTranscribing }

        #expect(model.selectedRecord?.id == recordB.id)
        #expect(model.selectedRun?.manifest.runID == "run-b")
        #expect(model.records.first(where: { $0.id == recordA.id })?.state == .hasConflicts)
        #expect(model.records.first(where: { $0.id == recordB.id })?.state == .done)
    }

    @Test @MainActor
    func failedRunMarksItsOwnRecordAfterSelectionChanges() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(root: root)
        let runB = try appShellRunFixture(in: root, runID: "run-b", text: "Transcript B")
        var recordA = appShellRecord(sourceURL: runB.inputURL)
        recordA.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        recordA.displayName = "Meeting A"
        var recordB = appShellRecord(sourceURL: runB.inputURL)
        recordB.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        recordB.displayName = "Meeting B"
        recordB.runURL = runB.runURL
        recordB.state = .done
        try repository.saveRecords([recordA, recordB])
        let runner = AppShellControllableRunner()
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: runner,
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        model.select(.record(recordA.id))
        model.retrySelectedTranscription()
        await appShellWait { runner.isWaiting }
        model.select(.record(recordB.id))
        runner.fail(with: AppShellFakeError.notImplemented)
        await appShellWait { !model.isTranscribing }

        #expect(model.records.first(where: { $0.id == recordA.id })?.state == .failed)
        #expect(model.records.first(where: { $0.id == recordB.id })?.state == .done)
        #expect(model.selectedRecord?.id == recordB.id)
        #expect(model.selectedRun?.manifest.runID == "run-b")
    }

    @Test @MainActor
    func recordingFinalizationFailureIndexesPreservedChannelsForRemixRetry() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("preserved-recording", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let microphoneURL = try appShellSyntheticCAF(
            in: directory,
            name: "microphone.caf",
            frequency: 440
        )
        let systemURL = try appShellSyntheticCAF(
            in: directory,
            name: "system-audio.caf",
            frequency: 660
        )
        let microphoneHash = try appShellSHA256(of: microphoneURL)
        let systemHash = try appShellSHA256(of: systemURL)
        let artifacts = PreservedRecordingArtifacts(
            directory: directory,
            microphoneURL: microphoneURL,
            systemAudioURL: systemURL,
            startedAt: Date(timeIntervalSince1970: 1_722_686_400),
            stoppedAt: Date(timeIntervalSince1970: 1_722_686_405)
        )
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppProfileID.koreanITMeeting.rawValue, forKey: "selectedProfile")
        defaults.set(PostprocessChoice.codex.rawValue, forKey: "selectedPostprocess")
        defaults.set(PostprocessOperationChoice.translation.rawValue, forKey: "selectedPostprocessMode")
        defaults.set(AppLanguage.italian.rawValue, forKey: "selectedTranslationTarget")
        let model = try MaccheroniAppModel(
            repository: LibraryRepository(root: root),
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFinalizationFailingRecorder(artifacts: artifacts),
            defaults: defaults
        )

        model.startRecording()
        await appShellWait { model.isRecording }
        model.selectedProfileID = .englishMeeting
        model.selectedPostprocess = .local
        model.selectedPostprocessMode = .correction
        model.selectedTranslationTarget = .english
        model.stopRecordingAndTranscribe()
        await appShellWait { model.canImportAudio && model.records.count == 1 }

        let record = try #require(model.records.first)
        #expect(record.state == .failed)
        #expect(record.sourceURL == microphoneURL)
        #expect(record.microphoneURL == microphoneURL)
        #expect(record.systemAudioURL == systemURL)
        #expect(record.failureMessage != nil)
        #expect(record.profileID == .koreanITMeeting)
        #expect(record.postprocess == .codex)
        #expect(record.postprocessMode == .translation)
        #expect(record.translationTargetLanguage == AppLanguage.italian.rawValue)
        #expect(model.canRetryTranscription(record))
        #expect(try appShellSHA256(of: microphoneURL) == microphoneHash)
        #expect(try appShellSHA256(of: systemURL) == systemHash)
    }

    @Test @MainActor
    func recordingUsesTheSelectionCapturedAtStartAfterSettingsChange() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingDirectory = root.appendingPathComponent("recording", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: false)
        let microphoneURL = recordingDirectory.appendingPathComponent("microphone.caf")
        let systemURL = recordingDirectory.appendingPathComponent("system-audio.caf")
        let combinedURL = recordingDirectory.appendingPathComponent("combined.wav")
        try Data("microphone source".utf8).write(to: microphoneURL)
        try Data("system source".utf8).write(to: systemURL)
        try Data("combined source".utf8).write(to: combinedURL)
        let combinedHash = try appShellSHA256(of: combinedURL)
        let artifacts = RecordingArtifacts(
            directory: recordingDirectory,
            microphoneURL: microphoneURL,
            systemAudioURL: systemURL,
            combinedURL: combinedURL,
            startedAt: Date(timeIntervalSince1970: 1_722_686_400),
            stoppedAt: Date(timeIntervalSince1970: 1_722_686_405)
        )
        let fixture = try appShellRunFixture(in: root, runID: "locked-selection-run")
        let runner = AppShellControllableRunner()
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppProfileID.koreanITMeeting.rawValue, forKey: "selectedProfile")
        defaults.set(PostprocessChoice.codex.rawValue, forKey: "selectedPostprocess")
        defaults.set(PostprocessOperationChoice.translation.rawValue, forKey: "selectedPostprocessMode")
        defaults.set(AppLanguage.italian.rawValue, forKey: "selectedTranslationTarget")
        let model = try MaccheroniAppModel(
            repository: LibraryRepository(root: root),
            profiles: try AppProfileRegistry.load(),
            runner: runner,
            recorder: AppShellSuccessfulRecorder(artifacts: artifacts),
            defaults: defaults,
            codexAvailability: .authenticated(version: "codex-cli fixture")
        )

        model.startRecording()
        await appShellWait { model.isRecording }

        model.selectedProfileID = .englishMeeting
        model.selectedPostprocess = .local
        model.selectedPostprocessMode = .correction
        model.selectedTranslationTarget = .english
        defaults.set(PostprocessChoice.local.rawValue, forKey: "selectedPostprocess")
        defaults.set(PostprocessOperationChoice.correction.rawValue, forKey: "selectedPostprocessMode")
        defaults.set(AppLanguage.english.rawValue, forKey: "selectedTranslationTarget")
        model.syncPostprocessSelectionsFromDefaults()

        model.stopRecordingAndTranscribe()
        await appShellWait { runner.isWaiting }

        let record = try #require(model.records.first)
        let request = try #require(runner.latestRequest)
        #expect(record.profileID == .koreanITMeeting)
        #expect(record.postprocess == .codex)
        #expect(record.postprocessMode == .translation)
        #expect(record.translationTargetLanguage == AppLanguage.italian.rawValue)
        #expect(request.profile.id == .koreanITMeeting)
        #expect(request.postprocess == .codex)
        #expect(request.postprocessMode == .translation)
        #expect(request.translationTargetLanguage == AppLanguage.italian.rawValue)
        #expect(try appShellSHA256(of: combinedURL) == combinedHash)

        runner.succeed(with: fixture.runURL)
        await appShellWait { !model.isTranscribing }
    }

    @Test @MainActor
    func retryOfFailedAppRecordingRemixesPreservedChannelsIntoANewWAV() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingDirectory = root.appendingPathComponent("recording", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: false)
        let microphoneURL = try appShellSyntheticCAF(
            in: recordingDirectory,
            name: "microphone.caf",
            frequency: 440
        )
        let systemURL = try appShellSyntheticCAF(
            in: recordingDirectory,
            name: "system-audio.caf",
            frequency: 660
        )
        let microphoneHash = try appShellSHA256(of: microphoneURL)
        let systemHash = try appShellSHA256(of: systemURL)
        var record = appShellRecord(sourceURL: microphoneURL)
        record.sourceKind = .appRecording
        record.microphoneURL = microphoneURL
        record.systemAudioURL = systemURL
        record.state = .failed
        record.failureMessage = "The initial mix failed."
        let repository = LibraryRepository(root: root)
        try repository.saveRecords([record])
        let runner = AppShellControllableRunner()
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: runner,
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        model.select(.record(record.id))
        #expect(model.canRetryTranscription(record))
        model.retrySelectedTranscription()
        await appShellWait { runner.isWaiting }

        let request = try #require(runner.latestRequest)
        let retryURL = request.sourceURL
        #expect(retryURL.deletingLastPathComponent() == recordingDirectory)
        #expect(retryURL.pathExtension == "wav")
        #expect(retryURL.lastPathComponent.hasPrefix("combined-retry-"))
        #expect(FileManager.default.fileExists(atPath: retryURL.path))
        #expect(retryURL != microphoneURL)
        #expect(model.records.first(where: { $0.id == record.id })?.sourceURL == retryURL)
        #expect(try repository.loadRecords().first?.sourceURL == retryURL)
        #expect(try appShellSHA256(of: microphoneURL) == microphoneHash)
        #expect(try appShellSHA256(of: systemURL) == systemHash)

        runner.fail(with: AppShellFakeError.notImplemented)
        await appShellWait { !model.isTranscribing }
        #expect(model.records.first(where: { $0.id == record.id })?.state == .failed)
    }

    @Test @MainActor
    func retryAdoptsSelectedLocalFallbackAndPreservesTranslationIntent() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try appShellRunFixture(in: root, runID: "codex-retry")
        let inputHash = try appShellSHA256(of: fixture.inputURL)
        var record = appShellRecord(sourceURL: fixture.inputURL)
        record.state = .failed
        record.failureMessage = "Codex authentication expired."
        record.postprocess = .codex
        record.postprocessMode = .translation
        record.translationTargetLanguage = "it"
        let repository = LibraryRepository(root: root)
        try repository.saveRecords([record])
        let runner = AppShellControllableRunner()
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(PostprocessChoice.local.rawValue, forKey: "selectedPostprocess")
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: runner,
            recorder: AppShellFakeRecorder(),
            defaults: defaults,
            codexAvailability: .unauthenticated(version: "codex-cli fixture")
        )

        model.select(.record(record.id))
        model.retrySelectedTranscription()
        await appShellWait { runner.isWaiting }

        let request = try #require(runner.latestRequest)
        #expect(request.postprocess == .local)
        #expect(request.postprocessMode == .translation)
        #expect(request.translationTargetLanguage == "it")
        let saved = try #require(repository.loadRecords().first)
        #expect(saved.postprocess == .local)
        #expect(saved.postprocessMode == .translation)
        #expect(saved.translationTargetLanguage == "it")
        #expect(try appShellSHA256(of: fixture.inputURL) == inputHash)

        runner.fail(with: AppShellFakeError.notImplemented)
        await appShellWait { !model.isTranscribing }
    }

    @Test @MainActor
    func mossLimitFailureBlocksOnlyTheIdenticalDeterministicRetry() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = try appShellFailedRunFixture(
            in: root,
            runID: "moss-limit",
            code: "MOSS_LIMIT_EXHAUSTED",
            message: "MOSS maximumTokens persisted at depth 3 for samples [0, 480000)"
        )
        let backendFailure = try appShellFailedRunFixture(
            in: root,
            runID: "backend-failure",
            code: "ASR_ERROR",
            message: "The backend stopped unexpectedly."
        )
        var limitRecord = appShellRecord(sourceURL: limit.inputURL)
        limitRecord.profileID = .italianDialogue
        limitRecord.runURL = limit.runURL
        limitRecord.state = .failed
        limitRecord.failureMessage = limit.manifest.failure?.message
        var retryableRecord = appShellRecord(sourceURL: backendFailure.inputURL)
        retryableRecord.id = UUID(
            uuidString: "00000000-0000-0000-0000-000000000016"
        )!
        retryableRecord.runURL = backendFailure.runURL
        retryableRecord.state = .failed
        retryableRecord.failureMessage = backendFailure.manifest.failure?.message
        let repository = LibraryRepository(root: root)
        try repository.saveRecords([limitRecord, retryableRecord])
        let runner = AppShellControllableRunner()
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppProfileID.italianDialogue.rawValue, forKey: "selectedProfile")
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: runner,
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        model.select(.record(limitRecord.id))
        #expect(model.failure(for: limitRecord)?.code
            == "MOSS_LIMIT_EXHAUSTED")
        #expect(model.failure(for: limitRecord)?.message.contains(
            "depth 3 for samples [0, 480000)"
        ) == true)
        #expect(model.isMOSSLimitExhausted(limitRecord))
        #expect(!model.canRetryTranscription(limitRecord))
        model.retrySelectedTranscription()
        await Task.yield()
        #expect(runner.latestRequest == nil)
        #expect(!model.isTranscribing)
        #expect(model.errorMessage == appString(
            "This run reached the MOSS output limit after bounded splitting. Choose a different profile or use a shorter copy before retrying."
        ))

        model.selectedProfileID = .englishMeeting
        #expect(model.canRetryTranscription(limitRecord))
        model.retrySelectedTranscription()
        await appShellWait { runner.isWaiting }
        #expect(runner.latestRequest?.profile.id == .englishMeeting)
        runner.fail(with: AppShellFakeError.notImplemented)
        await appShellWait { !model.isTranscribing }
        let failedAlternateRetry = try #require(
            model.records.first(where: { $0.id == limitRecord.id })
        )
        #expect(!model.isMOSSLimitExhausted(failedAlternateRetry))
        #expect(model.canRetryTranscription(failedAlternateRetry))

        model.select(.record(retryableRecord.id))
        #expect(!model.isMOSSLimitExhausted(retryableRecord))
        #expect(model.canRetryTranscription(retryableRecord))
        model.retrySelectedTranscription()
        await appShellWait { runner.isWaiting }
        #expect(runner.latestRequest?.sourceURL == backendFailure.inputURL)
        runner.fail(with: AppShellFakeError.notImplemented)
        await appShellWait { !model.isTranscribing }
    }

    @Test @MainActor
    func freshMossLimitFailureBlocksIdenticalRetryWithoutRelaunch() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let limit = try appShellFailedRunFixture(
            in: root,
            runID: "fresh-moss-limit",
            code: "MOSS_LIMIT_EXHAUSTED",
            message: "MOSS maximumTokens persisted after bounded splitting"
        )
        var record = appShellRecord(sourceURL: limit.inputURL)
        record.profileID = .italianDialogue
        record.state = .recorded
        let repository = LibraryRepository(root: root)
        try repository.saveRecords([record])
        let runner = AppShellManifestFailureRunner(runURL: limit.runURL)
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppProfileID.italianDialogue.rawValue, forKey: "selectedProfile")
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: runner,
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        model.select(.record(record.id))
        model.retrySelectedTranscription()
        await appShellWait { runner.didRun && !model.isTranscribing }

        let failed = try #require(model.records.first(where: { $0.id == record.id }))
        #expect(failed.runURL == limit.runURL)
        #expect(model.failure(for: failed)?.code == "MOSS_LIMIT_EXHAUSTED")
        #expect(model.isMOSSLimitExhausted(failed))
        #expect(!model.canRetryTranscription(failed))
    }

    @Test @MainActor
    func multiFileImportIndexesLaterReadableFilesAndAggregatesFailures() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidURL = root.appendingPathComponent("broken.wav")
        try Data("not audio".utf8).write(to: invalidURL)
        let readableURL = try appShellSyntheticCAF(
            in: root,
            name: "later.caf",
            frequency: 440
        )
        let finalReadableURL = try appShellSyntheticCAF(
            in: root,
            name: "final.aiff",
            frequency: 660
        )
        let repository = LibraryRepository(root: root)
        let runner = AppShellImmediateFailRunner {
            #expect((try? repository.loadRecords().count) == 2)
        }
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: runner,
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        model.importAudio([invalidURL, readableURL, finalReadableURL])
        await appShellWait { model.canImportAudio }

        #expect(model.records.count == 2)
        #expect(Set(model.records.map(\.sourceURL)) == Set([readableURL, finalReadableURL]))
        // The import path standardizes the URL, so compare resolved paths.
        #expect(
            runner.requests.map { $0.sourceURL.resolvingSymlinksInPath() }
                == [readableURL, finalReadableURL].map { $0.resolvingSymlinksInPath() }
        )
        #expect(model.errorMessage?.contains("broken.wav") == true)
        #expect(model.errorMessage?.contains("later.caf") == true)
        #expect(model.errorMessage?.contains("final.aiff") == true)
    }

    @Test @MainActor
    func cafAndAIFFImportsUseTheSameRetryReadabilityCheck() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cafURL = try appShellSyntheticCAF(in: root, name: "source.caf", frequency: 440)
        let aiffURL = try appShellSyntheticCAF(in: root, name: "source.aiff", frequency: 660)
        var cafRecord = appShellRecord(sourceURL: cafURL)
        cafRecord.state = .failed
        var aiffRecord = appShellRecord(sourceURL: aiffURL)
        aiffRecord.id = UUID(uuidString: "00000000-0000-0000-0000-000000000018")!
        aiffRecord.state = .cancelled
        let repository = LibraryRepository(root: root)
        try repository.saveRecords([cafRecord, aiffRecord])
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        #expect(model.canRetryTranscription(cafRecord))
        #expect(model.canRetryTranscription(aiffRecord))
    }

    @Test @MainActor
    func staleBookmarkRefreshAlsoUpdatesTheInMemoryLibraryRecord() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movedURL = try appShellSyntheticCAF(in: root, name: "moved.aiff", frequency: 440)
        let staleBookmark = Data("stale bookmark".utf8)
        let refreshedBookmark = Data("refreshed bookmark".utf8)
        let bookmarkAccess = LibraryBookmarkAccess(
            resolve: { _ in LibraryBookmarkResolution(url: movedURL, isStale: true) },
            create: { _ in refreshedBookmark }
        )
        let repository = LibraryRepository(root: root, bookmarkAccess: bookmarkAccess)
        var record = appShellRecord(sourceURL: root.appendingPathComponent("old.aiff"))
        record.securityScopedBookmark = staleBookmark
        record.state = .failed
        try repository.saveRecords([record])
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        #expect(model.canRetryTranscription(record))
        let refreshed = try #require(model.records.first)
        #expect(refreshed.sourceURL == movedURL)
        #expect(refreshed.securityScopedBookmark == refreshedBookmark)
    }

    @Test @MainActor
    func missingCombinedWAVRetriesFromIntactChannelOriginals() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("recording", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let microphoneURL = try appShellSyntheticCAF(
            in: directory,
            name: "microphone.caf",
            frequency: 440
        )
        let systemURL = try appShellSyntheticCAF(
            in: directory,
            name: "system-audio.caf",
            frequency: 660
        )
        let missingCombinedURL = directory.appendingPathComponent("combined.wav")
        var record = appShellRecord(sourceURL: missingCombinedURL)
        record.sourceKind = .appRecording
        record.microphoneURL = microphoneURL
        record.systemAudioURL = systemURL
        record.state = .failed
        let repository = LibraryRepository(root: root)
        try repository.saveRecords([record])
        let runner = AppShellControllableRunner()
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: runner,
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        model.select(.record(record.id))
        #expect(model.canRetryTranscription(record))
        model.retrySelectedTranscription()
        await appShellWait { runner.isWaiting }

        let retryURL = try #require(runner.latestRequest?.sourceURL)
        #expect(retryURL != missingCombinedURL)
        #expect(retryURL.pathExtension == "wav")
        #expect(FileManager.default.fileExists(atPath: retryURL.path))
        runner.fail(with: AppShellFakeError.notImplemented)
        await appShellWait { !model.isTranscribing }
    }

    @Test @MainActor
    func invalidUTF8GlossaryLoadFailsWithoutChangingOriginalBytes() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: LibraryRepository(root: root),
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )
        let glossaryURL = model.glossaryURL(for: .koreanITMeeting)
        let invalidBytes = Data([0x23, 0x20, 0xFF, 0x0A])
        try invalidBytes.write(to: glossaryURL)

        #expect(throws: (any Error).self) {
            _ = try model.loadGlossary(for: .koreanITMeeting)
        }
        #expect(try Data(contentsOf: glossaryURL) == invalidBytes)
    }

    @Test @MainActor
    func captureStartPersistsAProvisionalRecordBeforeStop() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("recording", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let microphoneURL = directory.appendingPathComponent("microphone.caf")
        let systemURL = directory.appendingPathComponent("system-audio.caf")
        let combinedURL = directory.appendingPathComponent("combined.wav")
        try Data("microphone".utf8).write(to: microphoneURL)
        try Data("system".utf8).write(to: systemURL)
        let startedAt = Date(timeIntervalSince1970: 1_722_686_400)
        let artifacts = RecordingArtifacts(
            directory: directory,
            microphoneURL: microphoneURL,
            systemAudioURL: systemURL,
            combinedURL: combinedURL,
            startedAt: startedAt,
            stoppedAt: startedAt.addingTimeInterval(5)
        )
        let repository = LibraryRepository(root: root)
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellSuccessfulRecorder(artifacts: artifacts),
            defaults: defaults
        )

        model.startRecording()
        await appShellWait { model.isRecording }

        let record = try #require(model.records.first)
        #expect(model.records.count == 1)
        #expect(record.state == .interrupted)
        #expect(record.failureMessage == appString("Interrupted"))
        #expect(record.microphoneURL == microphoneURL)
        #expect(record.systemAudioURL == systemURL)
        #expect(try repository.loadRecords() == model.records)
        model.shutdown()
    }

    @Test @MainActor
    func launchReconcilesAnUnindexedCaptureDirectory() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(root: root)
        try repository.prepareDirectories()
        let directory = repository.recordingsRoot.appendingPathComponent(
            "interrupted-startup",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let emptyDirectory = repository.recordingsRoot.appendingPathComponent(
            "failed-startup",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: emptyDirectory,
            withIntermediateDirectories: false
        )
        let emptyMicrophoneURL = try appShellEmptyCAF(
            in: emptyDirectory,
            name: "microphone.caf"
        )
        let emptySystemURL = try appShellEmptyCAF(
            in: emptyDirectory,
            name: "system-audio.caf"
        )
        let microphoneURL = try appShellSyntheticCAF(
            in: directory,
            name: "microphone.caf",
            frequency: 440
        )
        let systemURL = try appShellSyntheticCAF(
            in: directory,
            name: "system-audio.caf",
            frequency: 660
        )
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        #expect(model.records.count == 1)
        let recovered = try #require(model.records.first)
        #expect(recovered.state == .interrupted)
        #expect(recovered.failureMessage == appString("Interrupted"))
        #expect(recovered.microphoneURL == microphoneURL)
        #expect(recovered.systemAudioURL == systemURL)
        #expect(model.canRetryTranscription(recovered))
        let saved = try #require(repository.loadRecords().first)
        #expect(saved.id == recovered.id)
        #expect(saved.state == .interrupted)
        #expect(saved.microphoneURL == microphoneURL)
        #expect(saved.systemAudioURL == systemURL)
        #expect(FileManager.default.fileExists(atPath: emptyDirectory.path))
        #expect(FileManager.default.fileExists(atPath: emptyMicrophoneURL.path))
        #expect(FileManager.default.fileExists(atPath: emptySystemURL.path))
    }

    @Test @MainActor
    func launchReconcilesOrphanedTranscriptionIntoRetryableInterruptedState() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try appShellSyntheticCAF(in: root, name: "source.caf", frequency: 440)
        var record = appShellRecord(sourceURL: sourceURL)
        record.state = .transcribing
        let repository = LibraryRepository(root: root)
        try repository.saveRecords([record])
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        let recovered = try #require(model.records.first)
        #expect(recovered.state == .interrupted)
        #expect(recovered.failureMessage == appString("Interrupted"))
        #expect(model.canRetryTranscription(recovered))
        #expect(try repository.loadRecords().first?.state == .interrupted)
    }

    @Test @MainActor
    func runnerAndFailurePersistenceErrorsAreBothSurfaced() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try appShellSyntheticCAF(in: root, name: "source.caf", frequency: 440)
        var record = appShellRecord(sourceURL: sourceURL)
        record.state = .failed
        let repository = LibraryRepository(root: root)
        try repository.saveRecords([record])
        var sawTranscribingSave = false
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AppShellImmediateFailRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults,
            recordSaver: { records in
                if records.contains(where: { $0.state == .transcribing }) {
                    sawTranscribingSave = true
                    try repository.saveRecords(records)
                } else if sawTranscribingSave,
                          records.contains(where: { $0.state == .failed }) {
                    throw AppShellPersistenceError.couldNotSaveFailure
                } else {
                    try repository.saveRecords(records)
                }
            }
        )

        model.select(.record(record.id))
        model.retrySelectedTranscription()
        await appShellWait { !model.isTranscribing && model.errorMessage != nil }

        #expect(model.errorMessage?.contains(AppShellFakeError.notImplemented.localizedDescription) == true)
        #expect(model.errorMessage?.contains(AppShellPersistenceError.couldNotSaveFailure.localizedDescription) == true)
    }

    @Test @MainActor
    func pickerProviderFailureIsVisibleWhileUserCancellationStaysSilent() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: LibraryRepository(root: root),
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        model.handleImportResult(.failure(AppShellPickerError.providerFailed))
        #expect(model.errorMessage == AppShellPickerError.providerFailed.localizedDescription)
        model.clearError()
        model.handleImportResult(.failure(NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError
        )))
        #expect(model.errorMessage == nil)
    }

    @Test @MainActor
    func missingDecodingAndIntegrityRunFailuresStayDistinct() throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try appShellSyntheticCAF(in: root, name: "source.caf", frequency: 440)
        var record = appShellRecord(sourceURL: sourceURL)
        record.state = .done
        record.runURL = root.appendingPathComponent("missing-run", isDirectory: true)
        let repository = LibraryRepository(root: root)
        try repository.saveRecords([record])
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )

        record.runURL = nil
        try repository.saveRecords([record])
        let noRunModel = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )
        noRunModel.select(.record(record.id))
        #expect(noRunModel.selectedRunIssue == .missing)

        record.runURL = root.appendingPathComponent("missing-run", isDirectory: true)
        try repository.saveRecords([record])
        model.select(.record(record.id))
        #expect(model.selectedRunIssue == .missing)
        #expect(!model.canRevealRun(record))

        let incompleteRun = root.appendingPathComponent("incomplete-run", isDirectory: true)
        try FileManager.default.createDirectory(at: incompleteRun, withIntermediateDirectories: false)
        record.runURL = incompleteRun
        try repository.saveRecords([record])
        let incompleteModel = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )
        incompleteModel.select(.record(record.id))
        guard case .missingArtifact = incompleteModel.selectedRunIssue else {
            Issue.record("Expected a missing-artifact issue")
            return
        }
        #expect(incompleteModel.selectedRunIssue?.canReveal == true)
        #expect(incompleteModel.canRevealRun(record))

        let decodingRun = root.appendingPathComponent("decoding-run", isDirectory: true)
        try FileManager.default.createDirectory(at: decodingRun, withIntermediateDirectories: false)
        try Data("not json".utf8).write(to: decodingRun.appendingPathComponent("manifest.json"))
        record.runURL = decodingRun
        try repository.saveRecords([record])
        let decodingModel = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )
        decodingModel.select(.record(record.id))
        guard case .decoding = decodingModel.selectedRunIssue else {
            Issue.record("Expected a decoding issue")
            return
        }

        let fixture = try appShellRunFixture(in: root, runID: "integrity-run")
        try Data("tampered".utf8).write(to: fixture.segmentsURL)
        record.runURL = fixture.runURL
        try repository.saveRecords([record])
        let integrityModel = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AppShellFakeRunner(),
            recorder: AppShellFakeRecorder(),
            defaults: defaults
        )
        integrityModel.select(.record(record.id))
        guard case .integrity = integrityModel.selectedRunIssue else {
            Issue.record("Expected an integrity issue")
            return
        }
    }

    @Test @MainActor
    func recordingControlAvailabilityTurnsOffDuringTranscription() async throws {
        let root = try appShellTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = try appShellSyntheticCAF(in: root, name: "source.caf", frequency: 440)
        let record = appShellRecord(sourceURL: sourceURL)
        let repository = LibraryRepository(root: root)
        try repository.saveRecords([record])
        let runner = AppShellControllableRunner()
        let recorder = AppShellFakeRecorder()
        let (defaults, suiteName) = try appShellIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: runner,
            recorder: recorder,
            defaults: defaults
        )

        model.select(.record(record.id))
        model.retrySelectedTranscription()
        await appShellWait { runner.isWaiting }
        #expect(!model.canStartRecording)
        model.startRecording()
        await Task.yield()
        #expect(recorder.startCount == 0)
        runner.fail(with: AppShellFakeError.notImplemented)
        await appShellWait { !model.isTranscribing }
    }
}

private struct AppShellRunFixture {
    var runURL: URL
    var inputURL: URL
    var rawURL: URL
    var segmentsURL: URL
    var transcript: SegmentsDocument
    var conflicts: [MergeConflict]
    var manifest: Manifest
}

private struct AppShellFailedRunFixture {
    var runURL: URL
    var inputURL: URL
    var manifest: Manifest
}

private func appShellTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MaccheroniAppShellTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func appShellRecord(sourceURL: URL) -> LibraryRecord {
    LibraryRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!,
        createdAt: Date(timeIntervalSince1970: 1_722_686_400),
        displayName: "Fixture meeting",
        sourceKind: .importedFile,
        sourceURL: sourceURL,
        securityScopedBookmark: nil,
        microphoneURL: nil,
        systemAudioURL: nil,
        runURL: nil,
        profileID: .koreanITMeeting,
        postprocess: .none,
        durationS: 1,
        state: .recorded,
        speakerNames: [:],
        conflictResolutions: [:],
        failureMessage: nil
    )
}

private func appShellRunFixture(
    in root: URL,
    runID: String = "fixture-run",
    text: String = "Fixture text"
) throws -> AppShellRunFixture {
    let runURL = root.appendingPathComponent(runID, isDirectory: true)
    let primaryURL = runURL.appendingPathComponent("primary", isDirectory: true)
    let mergedURL = runURL.appendingPathComponent("merged", isDirectory: true)
    try FileManager.default.createDirectory(at: primaryURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: mergedURL, withIntermediateDirectories: true)

    let inputURL = root.appendingPathComponent("original-\(runID).wav")
    let rawURL = primaryURL.appendingPathComponent("raw.txt")
    let segmentsURL = mergedURL.appendingPathComponent("segments.json")
    let conflictsURL = mergedURL.appendingPathComponent("conflicts.json")
    _ = try appShellSyntheticCAF(
        in: root,
        name: inputURL.lastPathComponent,
        frequency: 440
    )
    try Data("immutable raw transcript".utf8).write(to: rawURL)

    let source = SourceAudio(
        fileName: inputURL.lastPathComponent,
        sha256: try appShellSHA256(of: inputURL),
        durationS: 2
    )
    let transcript = SegmentsDocument(
        segments: [Segment(speaker: "SPEAKER_00", startS: 0, endS: 2, text: text)],
        numSpeakers: 1,
        source: source
    )
    let conflicts = [MergeConflict(
        segmentIndex: 0,
        kind: .asrDisagreement,
        candidates: [text, "Alternative"],
        reason: "Fixture disagreement."
    )]
    try JSONEncoder().encode(transcript).write(to: segmentsURL)
    try JSONEncoder().encode(conflicts).write(to: conflictsURL)

    let manifest = Manifest(
        runID: runID,
        status: .succeeded,
        input: InputAudio(
            fileName: inputURL.lastPathComponent,
            sha256: source.sha256,
            sizeBytes: try Data(contentsOf: inputURL).count
        ),
        backend: BackendDescriptor(name: "fixture", version: "1"),
        models: [],
        glossary: .absent,
        preprocessing: PreprocessingConfiguration(
            sampleRateHz: 16_000,
            channels: 1,
            peakNormalization: true,
            vad: ProcessingSwitch(enabled: true, backend: "fixture"),
            enhancement: ProcessingSwitch(enabled: false, backend: nil)
        ),
        coverage: Coverage(
            inputDurationS: 2,
            processedDurationS: 2,
            truncated: false,
            strategy: .full,
            chunksPlanned: 1,
            chunksCompleted: 1
        ),
        chunkBoundaries: [],
        timing: RunTiming(
            startedAt: "2026-08-03T00:00:00Z",
            finishedAt: "2026-08-03T00:00:01Z",
            wallTimeS: 1
        ),
        artifacts: [
            Artifact(kind: "merged_segments", path: "merged/segments.json", sha256: try appShellSHA256(of: segmentsURL)),
            Artifact(kind: "merged_conflicts", path: "merged/conflicts.json", sha256: try appShellSHA256(of: conflictsURL)),
            Artifact(kind: "primary_raw", path: "primary/raw.txt", sha256: try appShellSHA256(of: rawURL)),
        ],
        failure: nil
    )
    try appShellWriteManifest(manifest, to: runURL)
    return AppShellRunFixture(
        runURL: runURL,
        inputURL: inputURL,
        rawURL: rawURL,
        segmentsURL: segmentsURL,
        transcript: transcript,
        conflicts: conflicts,
        manifest: manifest
    )
}

private func appShellFailedRunFixture(
    in root: URL,
    runID: String,
    code: String,
    message: String
) throws -> AppShellFailedRunFixture {
    let runURL = root.appendingPathComponent(runID, isDirectory: true)
    try FileManager.default.createDirectory(
        at: runURL,
        withIntermediateDirectories: false
    )
    let inputURL = root.appendingPathComponent("original-\(runID).wav")
    _ = try appShellSyntheticCAF(
        in: root,
        name: inputURL.lastPathComponent,
        frequency: 440
    )
    let inputHash = try appShellSHA256(of: inputURL)
    let manifest = Manifest(
        runID: runID,
        status: .failed,
        input: InputAudio(
            fileName: inputURL.lastPathComponent,
            sha256: inputHash,
            sizeBytes: try Data(contentsOf: inputURL).count
        ),
        backend: BackendDescriptor(name: "fixture", version: "1"),
        models: [
            ModelDescriptor(
                role: .asr,
                hfModelID: "aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8",
                revision: "90aa65287111a327db98eb83e325bd5332945edd",
                quantization: "int8-decoder+fp16-audio-vq-kv"
            ),
        ],
        glossary: .absent,
        preprocessing: PreprocessingConfiguration(
            sampleRateHz: 16_000,
            channels: 1,
            peakNormalization: true,
            vad: ProcessingSwitch(enabled: true, backend: "fixture"),
            enhancement: ProcessingSwitch(enabled: false, backend: nil)
        ),
        coverage: Coverage(
            inputDurationS: 30,
            processedDurationS: 0,
            truncated: true,
            strategy: .chunked,
            chunksPlanned: 1,
            chunksCompleted: 0,
            message: message
        ),
        chunkBoundaries: [],
        timing: RunTiming(
            startedAt: "2026-08-04T00:00:00Z",
            finishedAt: "2026-08-04T00:00:01Z",
            wallTimeS: 1
        ),
        artifacts: [],
        failure: Failure(code: code, message: message)
    )
    try appShellWriteManifest(manifest, to: runURL)
    return AppShellFailedRunFixture(
        runURL: runURL,
        inputURL: inputURL,
        manifest: manifest
    )
}

private func appShellIsolatedDefaults() throws -> (UserDefaults, String) {
    let suiteName = "MaccheroniAppShellTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

@MainActor
private func appShellWait(
    attempts: Int = 200,
    for condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0 ..< attempts {
        if condition() { return }
        await Task.yield()
    }
    #expect(condition())
}

private func appShellWriteManifest(_ manifest: Manifest, to runURL: URL) throws {
    try JSONEncoder().encode(manifest).write(to: runURL.appendingPathComponent("manifest.json"))
}

private func appShellSHA256(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func appShellSyntheticCAF(
    in directory: URL,
    name: String,
    frequency: Double
) throws -> URL {
    let url = directory.appendingPathComponent(name)
    let format = RecordingStorage.canonicalFormat
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let frames: AVAudioFrameCount = 4_800
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          let samples = buffer.floatChannelData?[0]
    else {
        throw AppShellFakeError.notImplemented
    }
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) {
        samples[index] = Float(
            sin(2 * .pi * frequency * Double(index) / RecordingStorage.sampleRate) * 0.1
        )
    }
    try file.write(from: buffer)
    return url
}

private func appShellEmptyCAF(in directory: URL, name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    let file = try AVAudioFile(
        forWriting: url,
        settings: RecordingStorage.canonicalFormat.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    file.close()
    return url
}

@MainActor
private final class AppShellFakeRunner: TranscriptionRunning {
    func run(
        _: TranscriptionRequest,
        progress _: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL {
        throw AppShellFakeError.notImplemented
    }

    func cancel() {}
}

@MainActor
private final class AppShellControllableRunner: TranscriptionRunning {
    private var continuation: CheckedContinuation<URL, any Error>?
    private(set) var latestRequest: TranscriptionRequest?

    var isWaiting: Bool { continuation != nil }

    func run(
        _ request: TranscriptionRequest,
        progress: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL {
        latestRequest = request
        progress(RunProgressSnapshot(
            stage: .preprocessing,
            completedChunks: 0,
            plannedChunks: 1,
            elapsedS: 0,
            modelID: "fixture/model",
            message: nil,
            runURL: nil
        ))
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func succeed(with url: URL) {
        continuation?.resume(returning: url)
        continuation = nil
    }

    func fail(with error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func cancel() {
        fail(with: CancellationError())
    }
}

@MainActor
private final class AppShellImmediateFailRunner: TranscriptionRunning {
    private(set) var requests: [TranscriptionRequest] = []
    private let beforeRun: (() -> Void)?

    init(beforeRun: (() -> Void)? = nil) {
        self.beforeRun = beforeRun
    }

    func run(
        _ request: TranscriptionRequest,
        progress _: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL {
        beforeRun?()
        requests.append(request)
        throw AppShellFakeError.notImplemented
    }

    func cancel() {}
}

@MainActor
private final class AppShellManifestFailureRunner: TranscriptionRunning {
    private let runURL: URL
    private(set) var didRun = false

    init(runURL: URL) {
        self.runURL = runURL
    }

    func run(
        _: TranscriptionRequest,
        progress: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL {
        didRun = true
        progress(RunProgressSnapshot(
            stage: .failed,
            completedChunks: 0,
            plannedChunks: 1,
            elapsedS: 1,
            modelID: nil,
            message: "MOSS maximumTokens persisted after bounded splitting",
            runURL: runURL
        ))
        throw TranscriptionRunnerError.pipelineFailed(
            "MOSS maximumTokens persisted after bounded splitting"
        )
    }

    func cancel() {}
}

@MainActor
private final class AppShellFakeRecorder: RecordingControlling {
    var meters = CaptureMeters.silent
    private var handler: (@MainActor (CaptureMeters) -> Void)?
    private(set) var startCount = 0

    func setMeterHandler(_ handler: (@MainActor (CaptureMeters) -> Void)?) {
        self.handler = handler
    }

    func start(in outputRoot: URL) async throws -> RecordingSessionMetadata {
        startCount += 1
        let directory = outputRoot.appendingPathComponent("fake-recording", isDirectory: true)
        return RecordingSessionMetadata(
            directory: directory,
            microphoneURL: directory.appendingPathComponent("microphone.caf"),
            systemAudioURL: directory.appendingPathComponent("system-audio.caf"),
            startedAt: Date(timeIntervalSince1970: 1_722_686_400)
        )
    }

    func stop() async throws -> RecordingArtifacts {
        throw AppShellFakeError.notImplemented
    }

    func cancel() async {}
}

@MainActor
private final class AppShellSuccessfulRecorder: RecordingControlling {
    var meters = CaptureMeters.silent
    let artifacts: RecordingArtifacts

    init(artifacts: RecordingArtifacts) {
        self.artifacts = artifacts
    }

    func setMeterHandler(_: (@MainActor (CaptureMeters) -> Void)?) {}
    func start(in _: URL) async throws -> RecordingSessionMetadata {
        RecordingSessionMetadata(
            directory: artifacts.directory,
            microphoneURL: artifacts.microphoneURL,
            systemAudioURL: artifacts.systemAudioURL,
            startedAt: artifacts.startedAt
        )
    }

    func stop() async throws -> RecordingArtifacts {
        artifacts
    }

    func cancel() async {}
}

@MainActor
private final class AppShellFinalizationFailingRecorder: RecordingControlling {
    var meters = CaptureMeters.silent
    let artifacts: PreservedRecordingArtifacts

    init(artifacts: PreservedRecordingArtifacts) {
        self.artifacts = artifacts
    }

    func setMeterHandler(_: (@MainActor (CaptureMeters) -> Void)?) {}
    func start(in _: URL) async throws -> RecordingSessionMetadata {
        RecordingSessionMetadata(
            directory: artifacts.directory,
            microphoneURL: artifacts.microphoneURL,
            systemAudioURL: artifacts.systemAudioURL,
            startedAt: artifacts.startedAt
        )
    }

    func stop() async throws -> RecordingArtifacts {
        throw RecordingFinalizationError(artifacts: artifacts, message: "mix failed")
    }

    func cancel() async {}
}

private enum AppShellFakeError: Error {
    case notImplemented
}

private enum AppShellPersistenceError: Error, LocalizedError {
    case couldNotSaveFailure

    var errorDescription: String? { "failure state could not be persisted" }
}

private enum AppShellPickerError: Error, LocalizedError {
    case providerFailed

    var errorDescription: String? { "the document provider failed" }
}

private struct AppShellStringCatalog: Decodable {
    let sourceLanguage: String
    let strings: [String: Entry]

    struct Entry: Decodable {
        let localizations: [String: Localization]
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit
    }

    struct StringUnit: Decodable {
        let state: String
        let value: String
    }
}

private func appShellPlaceholderSignature(_ value: String) -> [String] {
    let expression = try! NSRegularExpression(
        pattern: "%(?:[0-9]+\\$)?[-+ #0']*(?:[0-9]+|\\*)?(?:\\.[0-9]+|\\.\\*)?(?:hh|h|ll|l|q|L|z|t|j)?[@A-Za-z]"
    )
    let range = NSRange(value.startIndex ..< value.endIndex, in: value)
    return expression.matches(in: value, range: range).compactMap { match in
        guard let matchRange = Range(match.range, in: value) else { return nil }
        return value[matchRange]
            .replacingOccurrences(
                of: "^%[0-9]+\\$",
                with: "%",
                options: .regularExpression
            )
    }.sorted()
}
