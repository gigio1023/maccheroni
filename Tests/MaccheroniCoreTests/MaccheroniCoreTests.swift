import Foundation
import Testing
@testable import MaccheroniCore

@Suite struct MaccheroniCoreTests {
    private let sha256 = String(repeating: "a", count: 64)
    private let revision = String(repeating: "b", count: 40)

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func parsedJSONObject(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func glossaryError(for data: Data) -> GlossaryError? {
        do {
            _ = try Glossary.parse(data: data)
            return nil
        } catch let error as GlossaryError {
            return error
        } catch {
            return nil
        }
    }

    @Test func privacyBoundTextRedactsEmbeddedPathsWithoutRedactingWebURLs() {
        let input = "UserInfo={NSFilePath=/Users/private/model.bin} "
            + "home=~/Library/Caches/Maccheroni/model "
            + "url=file:///Users/private/recording.m4a "
            + "relative=fixtures/model.bin "
            + "remote=https://example.com/redirect?next=/account "
            + "double=//Users/private/model.bin "
            + "punctuation=/Users/private/name,secret/model "
            + "quoted=\"/Users/private/My File/model.bin\" "
            + "mixed=remote=https://example.com,cache=/Users/private/cache "
            + "piped=remote=https://example.com|cache=/Users/private/cache "
            + "json={\"remote\":\"https://example.com/reference\","
            + "\"path\":\"/Users/private/model.bin\"}"
        #expect(PrivacyBoundText.redactingFilePaths(in: input)
            == "UserInfo={NSFilePath=<redacted-path>} "
                + "home=<redacted-path> "
                + "url=<redacted-path> "
                + "relative=fixtures/model.bin "
                + "remote=https://example.com/redirect?next=/account "
                + "double=<redacted-path> "
                + "punctuation=<redacted-path> "
                + "quoted=\"<redacted-path>\" "
                + "mixed=remote=https://example.com,cache=<redacted-path> "
                + "piped=remote=https://example.com|cache=<redacted-path> "
                + "json={\"remote\":\"https://example.com/reference\","
                + "\"path\":\"<redacted-path>\"}")

        #expect(PrivacyBoundText.redactingFilePaths(
            in: #"error="could not read /Users/alice/Client Notes/secret.txt""#
        ) == #"error="could not read <redacted-path>""#)
        #expect(PrivacyBoundText.redactingFilePaths(
            in: #"path="/Users/alice/Client \"Acme Team\"/secret.txt""#
        ) == #"path="<redacted-path>""#)

        #expect(PrivacyBoundText.redactingFilePaths(
            in: "upper=FILE:///Users/秘密/My%20File.txt "
                + "host=file://localhost/Users/alice/private.txt"
        ) == "upper=<redacted-path> host=<redacted-path>")
        #expect(PrivacyBoundText.redactingFilePaths(
            in: "remote=https://example.test/?next=file:///Users/alice/private.txt&ok=1"
        ) == "remote=https://example.test/?next=<redacted-path>&ok=1")

        #expect(PrivacyBoundText.redactingFilePaths(
            in: "cdn=//cdn.example.com/assets/app.js loopback=https://[::1]/account"
        ) == "cdn=//cdn.example.com/assets/app.js loopback=https://[::1]/account")
        #expect(PrivacyBoundText.redactingFilePaths(
            in: "double=//Users/private/model.bin"
        ) == "double=<redacted-path>")

        #expect(PrivacyBoundText.redactingFilePaths(
            in: "named=~alice/Documents/private.txt prefix=prefix~/not-home"
        ) == "named=<redacted-path> prefix=prefix~/not-home")
        #expect(PrivacyBoundText.redactingFilePaths(
            in: #"windows=C:/Users/Alice/private.txt backslash=C:\Users\Alice\private.txt label=cache:/Users/alice/private"#
        ) == #"windows=<redacted-path> backslash=<redacted-path> label=cache:<redacted-path>"#)
        #expect(PrivacyBoundText.redactingFilePaths(
            in: "unicode=/Users/민지/회의%20메모.txt repeated=////Users/alice/private relative=../fixtures/model.bin"
        ) == "unicode=<redacted-path> repeated=<redacted-path> relative=../fixtures/model.bin")
    }

    @Test func privacyBoundTextHandlesLongDelimiterRunsWithoutQuadraticScanning() {
        let input = String(repeating: ":", count: 16_000)
        let started = Date()
        #expect(PrivacyBoundText.redactingFilePaths(in: input) == input)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func segmentsDocumentRoundTripsWithSchemaKeys() throws {
        let document = SegmentsDocument(
            segments: [Segment(
                speaker: "SPEAKER_00",
                startS: 0,
                endS: 1.25,
                text: "Qwen3-ASR를 확인합니다.",
                language: "ko",
                confidence: 0.92,
                flags: ["needs-review"]
            )],
            numSpeakers: 1,
            source: SourceAudio(fileName: "synthetic.wav", sha256: sha256, durationS: 1.25)
        )

        let encoded = try JSONEncoder().encode(document)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["schema_version"] as? String == "1.0.0")
        #expect(object["num_speakers"] as? Int == 1)
        let decoded = try JSONDecoder().decode(SegmentsDocument.self, from: encoded)
        #expect(decoded == document)
    }

    @Test func manifestRoundTripsWithModelProvenance() throws {
        let model = ModelDescriptor(
            role: .asr,
            hfModelID: "microsoft/VibeVoice-ASR",
            revision: revision,
            quantization: "8bit"
        )
        let postprocessModel = ModelDescriptor(
            role: .postprocess,
            hfModelID: "mlx-community/gemma-4-12B-it-qat-4bit",
            revision: revision,
            quantization: "qat-int4"
        )
        let manifest = Manifest(
            runID: "20260803T041530Z-7f3a9c",
            status: .succeeded,
            input: InputAudio(fileName: "synthetic.wav", sha256: sha256, sizeBytes: 4_096),
            backend: BackendDescriptor(name: "vibevoice", version: "1.0.0"),
            models: [model, postprocessModel],
            glossary: ManifestGlossary(
                provided: true,
                sha256: sha256,
                itemCount: 2,
                injectionMode: .freeTextContext,
                applied: true
            ),
            preprocessing: PreprocessingConfiguration(
                sampleRateHz: 16_000,
                channels: 1,
                peakNormalization: true,
                vad: ProcessingSwitch(enabled: true, backend: "silero"),
                enhancement: ProcessingSwitch(enabled: false, backend: nil)
            ),
            coverage: Coverage(
                inputDurationS: 1.25,
                processedDurationS: 1.25,
                truncated: false,
                strategy: .full,
                chunksPlanned: 1,
                chunksCompleted: 1
            ),
            chunkBoundaries: [ChunkBoundary(index: 0, startS: 0, endS: 1.25, status: .succeeded)],
            timing: RunTiming(
                startedAt: "2026-08-03T04:15:30Z",
                finishedAt: "2026-08-03T04:15:31Z",
                wallTimeS: 1
            ),
            peakMemoryBytes: 1_024,
            artifacts: [Artifact(kind: "primary_segments", path: "primary/segments.json", sha256: sha256)],
            failure: nil,
            postprocess: ManifestPostprocess(
                backend: BackendDescriptor(name: "mlx-vlm", version: "0.6.6"),
                modelID: postprocessModel.hfModelID,
                modelRevision: postprocessModel.revision,
                quantization: postprocessModel.quantization,
                glossarySHA256: sha256
            )
        )

        let encoded = try JSONEncoder().encode(manifest)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["run_id"] as? String == manifest.runID)
        let models = try #require(object["models"] as? [[String: Any]])
        #expect(models.first?["hf_model_id"] as? String == model.hfModelID)
        #expect(models.first?["revision"] as? String == revision)
        #expect(models.first?["quantization"] as? String == "8bit")
        let postprocess = try #require(object["postprocess"] as? [String: Any])
        let postprocessBackend = try #require(postprocess["backend"] as? [String: Any])
        #expect(postprocessBackend["name"] as? String == "mlx-vlm")
        #expect(postprocess["model_id"] as? String == postprocessModel.hfModelID)
        #expect(postprocess["model_revision"] as? String == revision)
        #expect(postprocess["quantization"] as? String == "qat-int4")
        #expect(postprocess["input_mode"] as? String == "text-only")
        #expect(postprocess["glossary_sha256"] as? String == sha256)
        #expect(postprocess["mode"] as? String == "correction")
        #expect(postprocess["target_language"] is NSNull)
        #expect(postprocess["source_segments_sha256"] is NSNull)
        #expect(postprocess["batching"] is NSNull)
        #expect(object["failure"] is NSNull)
        let preprocessing = try #require(object["preprocessing"] as? [String: Any])
        let enhancement = try #require(preprocessing["enhancement"] as? [String: Any])
        #expect(enhancement["backend"] is NSNull)
        let decoded = try JSONDecoder().decode(Manifest.self, from: encoded)
        #expect(decoded == manifest)

        var codexManifest = manifest
        codexManifest.postprocess = ManifestPostprocess(
            backend: BackendDescriptor(name: "codex-cli", version: "codex-cli test"),
            modelID: "gpt-5.6-terra"
        )
        let codexObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(codexManifest)
            ) as? [String: Any]
        )
        let codexPostprocess = try #require(
            codexObject["postprocess"] as? [String: Any]
        )
        #expect(codexPostprocess["model_revision"] is NSNull)
        #expect(codexPostprocess["quantization"] is NSNull)
        #expect(codexPostprocess["glossary_sha256"] is NSNull)
    }

    @Test func manifestSchemaEnumeratesRunStatusesAndFailureCodes() throws {
        let data = try Data(contentsOf: fixtureURL(
            "docs/contracts/manifest.schema.json"
        ))
        let schema = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let properties = try #require(schema["properties"] as? [String: Any])
        let status = try #require(properties["status"] as? [String: Any])
        #expect(status["enum"] as? [String] == [
            "succeeded",
            "partial",
            "failed",
            "canceled",
        ])

        let definitions = try #require(schema["$defs"] as? [String: Any])
        let failure = try #require(definitions["failure"] as? [String: Any])
        let failureProperties = try #require(
            failure["properties"] as? [String: Any]
        )
        let code = try #require(failureProperties["code"] as? [String: Any])
        #expect(code["enum"] as? [String] == [
            "ASR_ERROR",
            "CANCELED",
            "CHUNK_PLAN_ERROR",
            "DIARIZATION_ERROR",
            "GLOSSARY_ERROR",
            "INPUT_MUTATED",
            "MERGE_ERROR",
            "MOSS_LIMIT_EXHAUSTED",
            "POSTPROCESS_ERROR",
            "PREPROCESS_ERROR",
            "PROFILE_ERROR",
            "RUN_ERROR",
            "RUN_INCOMPLETE",
            "USAGE_ERROR",
            "VAD_ERROR",
            "asr_coverage_shortfall",
            "asr_evidence_unavailable",
            "asr_malformed_output",
            "asr_model_identity_mismatch",
            "asr_timeout",
            "invalid_eos_output",
        ])
    }

    @Test func canceledRunStatusRoundTrips() throws {
        let encoded = try JSONEncoder().encode(RunStatus.canceled)
        #expect(String(decoding: encoded, as: UTF8.self) == #""canceled""#)
        #expect(try JSONDecoder().decode(RunStatus.self, from: encoded) == .canceled)
    }

    @Test func postprocessManifestDecodesLegacyCorrectionAndRoundTripsTranslationEvidence() throws {
        let legacy = Data(#"""
        {
          "backend":{"name":"codex-cli","version":"codex-cli fixture"},
          "model_id":"gpt-5.6-terra",
          "model_revision":null,
          "quantization":null,
          "input_mode":"text-only",
          "glossary_sha256":null
        }
        """#.utf8)
        let decodedLegacy = try JSONDecoder().decode(
            ManifestPostprocess.self,
            from: legacy
        )
        #expect(decodedLegacy.mode == .correction)
        #expect(decodedLegacy.targetLanguage == nil)
        #expect(decodedLegacy.sourceSegmentsSHA256 == nil)
        #expect(decodedLegacy.batching == nil)

        let translation = ManifestPostprocess(
            backend: BackendDescriptor(
                name: "codex-cli",
                version: "codex-cli fixture"
            ),
            modelID: "gpt-5.6-sol",
            mode: .translation,
            targetLanguage: "en",
            sourceSegmentsSHA256: sha256,
            batching: ManifestPostprocessBatching(
                maximumPromptUTF8Bytes: 16_384,
                maximumSegmentsPerBatch: 32,
                maximumOutputTokens: nil,
                outputTokenLimitStatus: .serviceManagedUnavailable,
                outputTokenPlanningBudget: 4_096,
                outputTokensPerInputUTF8BytePermille: 2_000,
                baseOutputTokenReserve: 32,
                perSegmentOutputTokenReserve: 96,
                batchesPlanned: 3,
                maximumObservedPromptUTF8Bytes: 2_048,
                maximumObservedInputTextUTF8Bytes: 1_120,
                maximumObservedEstimatedOutputTokens: 2_368,
                maximumObservedOutputTextUTF8Bytes: 884,
                maximumObservedResponseUTF8Bytes: 884,
                maximumObservedAcceptedOutputTokenUpperBound: 1_012
            )
        )
        let encoded = try JSONEncoder().encode(translation)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["mode"] as? String == "translation")
        #expect(object["target_language"] as? String == "en")
        #expect(object["source_segments_sha256"] as? String == sha256)
        let batching = try #require(object["batching"] as? [String: Any])
        #expect(batching["maximum_prompt_utf8_bytes"] as? Int == 16_384)
        #expect(batching["maximum_segments_per_batch"] as? Int == 32)
        #expect(batching["maximum_observed_response_utf8_bytes"] as? Int == 884)
        #expect(batching["maximum_output_tokens"] is NSNull)
        #expect(batching["output_token_limit_status"] as? String
            == "service-managed-unavailable")
        #expect(batching["output_token_planning_budget"] as? Int == 4_096)
        #expect(batching["output_tokens_per_input_utf8_byte_permille"] as? Int
            == 2_000)
        #expect(batching["base_output_token_reserve"] as? Int == 32)
        #expect(batching["per_segment_output_token_reserve"] as? Int == 96)
        #expect(batching["batches_planned"] as? Int == 3)
        #expect(batching["maximum_observed_prompt_utf8_bytes"] as? Int == 2_048)
        #expect(batching["maximum_observed_input_text_utf8_bytes"] as? Int == 1_120)
        #expect(batching["maximum_observed_estimated_output_tokens"] as? Int == 2_368)
        #expect(batching["maximum_observed_output_text_utf8_bytes"] as? Int == 884)
        #expect(batching["maximum_observed_accepted_output_token_upper_bound"] as? Int
            == 1_012)
        #expect(try JSONDecoder().decode(
            ManifestPostprocess.self,
            from: encoded
        ) == translation)
    }

    @Test func glossaryParsesSyntheticUTF8AccordingToContract() throws {
        let data = Data("\u{FEFF}# people\r\nGiovanni Ferrero\r\n김마케로니\r\nGiovanni Ferrero\r\nQwen3-ASR # literal\r\n".utf8)
        let glossary = try Glossary.parse(data: data)

        #expect(glossary.entries == ["Giovanni Ferrero", "김마케로니", "Qwen3-ASR # literal"])
        #expect(glossary.sha256.count == 64)
        #expect(try glossary.payload(for: .freeTextContext) == "Giovanni Ferrero\n김마케로니\nQwen3-ASR # literal")
    }

    @Test func zeroEntryGlossaryResolvesAsAbsent() throws {
        let data = Data("\u{FEFF}# owner note\r\n\r\n  # category: terms  \r\n".utf8)

        #expect(try Glossary.parse(data: data).entries.isEmpty)
        #expect(try Glossary.parseOptional(data: data) == nil)
    }

    @Test func optionalGlossaryStillRejectsInvalidSourceBytes() {
        #expect(throws: GlossaryError.containsNUL) {
            try Glossary.parseOptional(data: Data("# note\0".utf8))
        }
        #expect(throws: GlossaryError.invalidUTF8) {
            try Glossary.parseOptional(data: Data([0xFF]))
        }
    }

    @Test func absentGlossaryEncodesRequiredNullHash() throws {
        let encoded = try JSONEncoder().encode(ManifestGlossary.absent)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["sha256"] is NSNull)
        #expect(object["item_count"] as? Int == 0)
        #expect(object["injection_mode"] as? String == "none")
    }

    @Test func languagePinRoundTrips() throws {
        let encoded = try JSONEncoder().encode(LanguagePin.fixed("it"))
        let decoded = try JSONDecoder().decode(LanguagePin.self, from: encoded)
        #expect(decoded == .fixed("it"))
    }

    @Test func canonicalSegmentsFixtureRoundTripsWithoutChangingJSON() throws {
        let original = try Data(contentsOf: fixtureURL(
            "benchmarks/scripts/scoring/fixtures/segments.example.json"
        ))
        let document = try JSONDecoder().decode(SegmentsDocument.self, from: original)
        let encoded = try JSONEncoder().encode(document)

        #expect(try parsedJSONObject(encoded) == parsedJSONObject(original))
    }

    @Test func canonicalManifestFixtureRoundTripsWithoutChangingJSON() throws {
        let original = try Data(contentsOf: fixtureURL(
            "benchmarks/scripts/scoring/fixtures/manifest.example.json"
        ))
        let manifest = try JSONDecoder().decode(Manifest.self, from: original)
        let encoded = try JSONEncoder().encode(manifest)

        #expect(try parsedJSONObject(encoded) == parsedJSONObject(original))
    }

    @Test func glossaryRejectsInvalidBytesAndHonorsNormalization() throws {
        #expect(glossaryError(for: Data([0xFF])) == .invalidUTF8)
        #expect(glossaryError(for: Data("alpha\0beta".utf8)) == .containsNUL)
        #expect(
            glossaryError(for: Data("alpha\tbeta".utf8))
                == .containsControlCharacter(line: 1)
        )
        #expect(
            glossaryError(for: Data(String(repeating: "a", count: 257).utf8))
                == .entryTooLong(line: 1)
        )

        let glossary = try Glossary.parse(data: Data("e\u{301}\né\nE\n".utf8))
        #expect(glossary.entries == ["é", "E"])
    }

    @Test func derivedManifestRoundTripsExplicitSourceAndGlossaryLineage() throws {
        let manifest = DerivedManifest(
            derivedID: "20260812T120000Z-derived",
            status: .succeeded,
            source: DerivedSourceLineage(
                runID: "source-run",
                manifestSHA256: sha256,
                segmentsPath: "merged/segments.json",
                segmentsSHA256: sha256
            ),
            operation: DerivedOperation(
                profileName: "ko-meeting",
                mode: .translation,
                targetLanguage: "en",
                glossarySemantics: .currentProfile,
                glossarySHA256: sha256,
                glossaryItemCount: 2
            ),
            timing: RunTiming(
                startedAt: "2026-08-12T12:00:00Z",
                finishedAt: "2026-08-12T12:00:01Z",
                wallTimeS: 1
            ),
            artifacts: [Artifact(
                kind: "postprocess_translation",
                path: "postprocess/translation.json",
                sha256: sha256
            )],
            failure: nil,
            postprocess: ManifestPostprocess(
                backend: BackendDescriptor(name: "fixture", version: "1"),
                modelID: "fixture/model",
                glossarySHA256: sha256,
                mode: .translation,
                targetLanguage: "en",
                sourceSegmentsSHA256: sha256
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["derived_id"] as? String == manifest.derivedID)
        let source = try #require(object["source"] as? [String: Any])
        #expect(source["run_id"] as? String == "source-run")
        #expect(source["manifest_sha256"] as? String == sha256)
        let operation = try #require(object["operation"] as? [String: Any])
        #expect(operation["glossary_semantics"] as? String == "current-profile")
        #expect(operation["glossary_item_count"] as? Int == 2)
        #expect(try JSONDecoder().decode(DerivedManifest.self, from: data) == manifest)
    }

    // MARK: - Derived operation kind and the merged-source gate

    @Test func aDerivedOperationWrittenBeforeTheKindFieldReadsAsATextOperation() throws {
        let legacy = Data(#"""
        {"profile_name":"ko-meeting","mode":"correction","target_language":null,
         "glossary_semantics":"current-profile","glossary_sha256":null,
         "glossary_item_count":0}
        """#.utf8)
        let decoded = try JSONDecoder().decode(DerivedOperation.self, from: legacy)
        #expect(decoded.kind == .textPostprocess)
        #expect(decoded.sourceCoverageComplete)

        let proposal = DerivedOperation(
            profileName: "ko-meeting",
            mode: .correction,
            glossarySemantics: .currentProfile,
            glossaryItemCount: 0,
            kind: .speakerProposal,
            sourceCoverage: DerivedSourceCoverage(
                complete: false,
                inputDurationS: 1_243.08,
                processedDurationS: 1_212.52,
                message: "1 range(s) produced no transcript: [871.552, 902.112) s"
            )
        )
        let object = try #require(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(proposal)
        ) as? [String: Any])
        #expect(object["kind"] as? String == "speaker-proposal")
        // The bare flag stays, so a skim cannot miss it, and the durations sit
        // beside it so the reader knows how much of the meeting is missing.
        #expect(object["source_coverage_complete"] as? Bool == false)
        let coverage = try #require(object["source_coverage"] as? [String: Any])
        #expect(coverage["complete"] as? Bool == false)
        #expect(coverage["input_duration_s"] as? Double == 1_243.08)
        #expect(coverage["processed_duration_s"] as? Double == 1_212.52)
        #expect(
            abs((coverage["missing_duration_s"] as? Double ?? 0) - 30.56) < 0.001
        )
        #expect((coverage["message"] as? String)?.contains("871.552") == true)
        #expect(try JSONDecoder().decode(
            DerivedOperation.self,
            from: try JSONEncoder().encode(proposal)
        ) == proposal)
    }

    /// Build a run directory that passes every integrity check, then let the
    /// caller decide whether its coverage is complete.
    ///
    /// `chunkBoundaries` overrides the single full-range chunk, so a caller can
    /// build a run whose totals look complete while its boundaries leave a gap.
    /// `partialCoverageArtifact` writes the `primary/partial-coverage.json` a
    /// run that lost audio is required to carry.
    private func writeRunFixture(
        at root: URL,
        runID: String,
        status: RunStatus,
        truncated: Bool,
        processedDurationS: Double,
        failure: Failure?,
        chunkBoundaries: [ChunkBoundary]? = nil,
        partialCoverageArtifact: Bool = false
    ) throws -> URL {
        let run = root.appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(
            at: run,
            withIntermediateDirectories: true
        )
        let inputHash = String(repeating: "c", count: 64)
        let document = SegmentsDocument(
            segments: [
                Segment(speaker: "0", startS: 0, endS: 1, text: "one"),
                Segment(speaker: "UNKNOWN", startS: 1, endS: 2, text: "two"),
            ],
            numSpeakers: 1,
            source: SourceAudio(
                fileName: "meeting.wav",
                sha256: inputHash,
                durationS: 2
            )
        )
        var files: [(kind: String, path: String, data: Data)] = [
            ("primary_raw", "primary/raw.txt", Data("one\ntwo\n".utf8)),
            (
                "primary_segments",
                "primary/segments.json",
                try JSONEncoder().encode(document)
            ),
            (
                "diarization_timeline",
                "diarization/timeline.json",
                try JSONEncoder().encode(Timeline(segments: [
                    TimelineSegment(speaker: "0", startS: 0, endS: 1),
                ]))
            ),
            (
                "merged_segments",
                "merged/segments.json",
                try JSONEncoder().encode(document)
            ),
            ("merged_conflicts", "merged/conflicts.json", Data("[]".utf8)),
        ]
        if partialCoverageArtifact {
            files.append((
                "partial_coverage",
                "primary/partial-coverage.json",
                Data(#"""
                {"input_duration_s":2,"promoted_duration_s":1.5,
                 "missing_duration_s":0.5,
                 "missing":[{"start_s":1.5,"end_s":2}],
                 "partial_attempt_ids":[]}
                """#.utf8)
            ))
        }
        var artifacts: [Artifact] = []
        for file in files {
            let url = run.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try file.data.write(to: url)
            artifacts.append(Artifact(
                kind: file.kind,
                path: file.path,
                sha256: try RunIntegrityVerifier.sha256(of: url)
            ))
        }
        files.removeAll()
        let manifest = Manifest(
            runID: runID,
            status: status,
            input: InputAudio(
                fileName: "meeting.wav",
                sha256: inputHash,
                sizeBytes: 1_024
            ),
            backend: BackendDescriptor(name: "fixture", version: "1"),
            models: [ModelDescriptor(
                role: .asr,
                hfModelID: "fixture/model",
                revision: String(repeating: "d", count: 40),
                quantization: "int8"
            )],
            glossary: .absent,
            preprocessing: PreprocessingConfiguration(
                sampleRateHz: 16_000,
                channels: 1,
                peakNormalization: true,
                vad: ProcessingSwitch(enabled: true, backend: "silero"),
                enhancement: ProcessingSwitch(enabled: false, backend: nil)
            ),
            coverage: Coverage(
                inputDurationS: 2,
                processedDurationS: processedDurationS,
                truncated: truncated,
                strategy: truncated
                    ? .backendTruncated
                    : ((chunkBoundaries?.count ?? 1) > 1 ? .chunked : .full),
                chunksPlanned: chunkBoundaries?.count
                    ?? (processedDurationS > 0 ? 1 : 0),
                chunksCompleted: chunkBoundaries?.count
                    ?? (processedDurationS > 0 ? 1 : 0)
            ),
            chunkBoundaries: chunkBoundaries
                ?? (processedDurationS > 0
                    ? [ChunkBoundary(
                        index: 0,
                        startS: 0,
                        endS: processedDurationS,
                        status: .succeeded
                    )]
                    : []),
            timing: RunTiming(
                startedAt: "2026-09-02T12:00:00Z",
                finishedAt: "2026-09-02T12:00:01Z",
                wallTimeS: 1
            ),
            artifacts: artifacts,
            failure: failure
        )
        try JSONEncoder().encode(manifest).write(
            to: run.appendingPathComponent("manifest.json")
        )
        return run
    }

    @Test func aPartialRunIsADerivableMergedSourceButNotACompletedRun() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniCoreMergedSource-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let complete = try writeRunFixture(
            at: root,
            runID: "complete",
            status: .succeeded,
            truncated: false,
            processedDurationS: 2,
            failure: nil
        )
        #expect(try RunIntegrityVerifier
            .verifyCompletedRun(at: complete).coverageIsComplete)
        #expect(try RunIntegrityVerifier
            .verifyMergedRun(at: complete).coverageIsComplete)

        let partial = try writeRunFixture(
            at: root,
            runID: "partial",
            status: .partial,
            truncated: true,
            processedDurationS: 1.5,
            failure: Failure(
                code: "ASR_REPETITION_LOOPING",
                message: "one range produced no transcript"
            ),
            partialCoverageArtifact: true
        )
        #expect(throws: RunIntegrityError.sourceRunNotComplete) {
            _ = try RunIntegrityVerifier.verifyCompletedRun(at: partial)
        }
        let merged = try RunIntegrityVerifier.verifyMergedRun(at: partial)
        #expect(!merged.coverageIsComplete)
        #expect(merged.lineage.segmentsPath == "merged/segments.json")
        #expect(merged.document.segments.count == 2)

        // Dropping the coverage gate drops nothing else: a tampered artifact
        // is still refused on the relaxed path.
        try Data("[{}]".utf8).write(
            to: partial.appendingPathComponent("merged/conflicts.json")
        )
        #expect(throws: RunIntegrityError.artifactHashMismatch(
            "merged/conflicts.json"
        )) {
            _ = try RunIntegrityVerifier.verifyMergedRun(at: partial)
        }
    }

    @Test func aFailedRunIsNeverADerivableMergedSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniCoreFailedSource-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }

        for status in [RunStatus.failed, .canceled] {
            let run = try writeRunFixture(
                at: root,
                runID: "run-\(status.rawValue)",
                status: status,
                truncated: true,
                processedDurationS: 1,
                failure: Failure(code: "RUN_ERROR", message: "stopped")
            )
            #expect(throws: RunIntegrityError.sourceRunNotComplete) {
                _ = try RunIntegrityVerifier.verifyMergedRun(at: run)
            }
        }

        // Nor is a run that promoted nothing at all.
        let empty = try writeRunFixture(
            at: root,
            runID: "run-empty",
            status: .partial,
            truncated: true,
            processedDurationS: 0,
            failure: Failure(code: "RUN_ERROR", message: "nothing promoted")
        )
        #expect(throws: RunIntegrityError.sourceRunNotComplete) {
            _ = try RunIntegrityVerifier.verifyMergedRun(at: empty)
        }
    }

    @Test func theMergedSourceGateProvesCoverageRatherThanReadingStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniCoreCoverageProof-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // A run that claims success while its coverage record stops short of
        // the input is a false claim, not a partial result, and must not seed
        // a derived set.
        let short = try writeRunFixture(
            at: root,
            runID: "succeeded-short",
            status: .succeeded,
            truncated: false,
            processedDurationS: 1.5,
            failure: nil
        )
        #expect(throws: RunIntegrityError.sourceCoverageContradictsStatus) {
            _ = try RunIntegrityVerifier.verifyMergedRun(at: short)
        }

        // The same holds when the totals add up but the boundaries leave a
        // hole between two chunks: the transcript has a gap the durations do
        // not disclose.
        let gapped = try writeRunFixture(
            at: root,
            runID: "succeeded-gapped",
            status: .succeeded,
            truncated: false,
            processedDurationS: 2,
            failure: nil,
            chunkBoundaries: [
                ChunkBoundary(index: 0, startS: 0, endS: 0.5, status: .succeeded),
                ChunkBoundary(index: 1, startS: 1, endS: 2, status: .succeeded),
            ]
        )
        #expect(throws: RunIntegrityError.sourceCoverageContradictsStatus) {
            _ = try RunIntegrityVerifier.verifyMergedRun(at: gapped)
        }

        // `partial` is a claim that something was lost, so the run has to say
        // what failed.
        let unexplained = try writeRunFixture(
            at: root,
            runID: "partial-unexplained",
            status: .partial,
            truncated: true,
            processedDurationS: 1.5,
            failure: nil,
            partialCoverageArtifact: true
        )
        #expect(throws: RunIntegrityError.sourceFailureEvidenceMissing) {
            _ = try RunIntegrityVerifier.verifyMergedRun(at: unexplained)
        }

        // And it has to name the ranges it lost.
        let unnamed = try writeRunFixture(
            at: root,
            runID: "partial-unnamed",
            status: .partial,
            truncated: true,
            processedDurationS: 1.5,
            failure: Failure(
                code: "ASR_REPETITION_LOOPING",
                message: "one range produced no transcript"
            )
        )
        #expect(throws: RunIntegrityError.requiredArtifactMissing(
            kind: "partial_coverage",
            path: "primary/partial-coverage.json"
        )) {
            _ = try RunIntegrityVerifier.verifyMergedRun(at: unnamed)
        }
    }

    @Test func aPostprocessFailureOverFullASRCoverageStaysCoverageComplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniCorePostprocessFailure-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // ASR reached every second of the input and text post-processing then
        // failed. The run exits `partial`, but no audio was lost, so a derived
        // proposal over it must not tell the reader that a transcript is
        // missing for zero seconds of the meeting.
        let run = try writeRunFixture(
            at: root,
            runID: "postprocess-failed",
            status: .partial,
            truncated: false,
            processedDurationS: 2,
            failure: Failure(
                code: "POSTPROCESS_ERROR",
                message: "the correction backend returned no output"
            )
        )
        let source = try RunIntegrityVerifier.verifyMergedRun(at: run)
        #expect(source.coverageIsComplete)
        #expect(source.coverage.missingDurationS == 0)
        #expect(source.coverage.processedDurationS == 2)

        // The stricter gate is unchanged: correction and translation still
        // require a run that finished.
        #expect(throws: RunIntegrityError.sourceRunNotComplete) {
            _ = try RunIntegrityVerifier.verifyCompletedRun(at: run)
        }
    }

    @Test func aDerivedOperationRefusesDisagreeingCoverageClaims() throws {
        let disagreeing = Data(#"""
        {"profile_name":"ko-meeting","mode":"correction","target_language":null,
         "glossary_semantics":"current-profile","glossary_sha256":null,
         "glossary_item_count":0,"kind":"speaker-proposal",
         "source_coverage":{"complete":false,"input_duration_s":1243.08,
           "processed_duration_s":1212.52,"missing_duration_s":30.56,
           "message":"1 range(s) produced no transcript"},
         "source_coverage_complete":true}
        """#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(DerivedOperation.self, from: disagreeing)
        }

        // The agreeing form still decodes, and the flag still reads back.
        let agreeing = Data(#"""
        {"profile_name":"ko-meeting","mode":"correction","target_language":null,
         "glossary_semantics":"current-profile","glossary_sha256":null,
         "glossary_item_count":0,"kind":"speaker-proposal",
         "source_coverage":{"complete":false,"input_duration_s":1243.08,
           "processed_duration_s":1212.52,"missing_duration_s":30.56,
           "message":"1 range(s) produced no transcript"},
         "source_coverage_complete":false}
        """#.utf8)
        let decoded = try JSONDecoder().decode(
            DerivedOperation.self,
            from: agreeing
        )
        #expect(!decoded.sourceCoverageComplete)

        // A manifest written before either field is unaffected.
        let legacy = Data(#"""
        {"profile_name":"ko-meeting","mode":"correction","target_language":null,
         "glossary_semantics":"current-profile","glossary_sha256":null,
         "glossary_item_count":0}
        """#.utf8)
        #expect(try JSONDecoder().decode(
            DerivedOperation.self,
            from: legacy
        ).sourceCoverageComplete)
    }

    @Test func completedRunVerifierRejectsTypedIntegrityFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniCoreIntegrity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try RunIntegrityVerifier.verifyCompletedRun(at: root)
            Issue.record("expected missing manifest rejection")
        } catch let error as RunIntegrityError {
            #expect(error == .manifestMissing)
        }

        try Data("not-json".utf8).write(
            to: root.appendingPathComponent("manifest.json")
        )
        do {
            _ = try RunIntegrityVerifier.verifyCompletedRun(at: root)
            Issue.record("expected invalid manifest rejection")
        } catch let error as RunIntegrityError {
            guard case .manifestInvalid = error else {
                Issue.record("unexpected integrity error: \(error)")
                return
            }
        }
    }

    @Test func adapterProtocolsCarryLanguageGlossaryAndSpeakerBounds() async throws {
        let glossary = Glossary(entries: ["Giovanni"], sha256: sha256)
        let asr: any ASRBackend = FakeASRBackend(revision: revision)
        let result = try await asr.transcribe(ASRRequest(
            audioURL: URL(fileURLWithPath: "/tmp/synthetic.wav"),
            startS: 1,
            endS: 2,
            language: .fixed("it"),
            glossary: glossary,
            injectionMode: .hotwordInstruction
        ))
        #expect(result.rawText == "it:Giovanni")
        #expect(result.glossaryApplied)

        let diarizer: any DiarizerBackend = FakeDiarizerBackend(revision: revision)
        let timeline = try await diarizer.diarize(DiarizationRequest(
            audioURL: URL(fileURLWithPath: "/tmp/synthetic.wav"),
            speakerCountHint: 2...3
        ))
        #expect(timeline.segments.map(\.speaker) == ["SPEAKER_02", "SPEAKER_03"])
    }
}

private struct FakeASRBackend: ASRBackend {
    let descriptor = BackendDescriptor(name: "fake-asr", version: "1")
    let model: ModelDescriptor

    init(revision: String) {
        model = ModelDescriptor(
            role: .asr,
            hfModelID: "example/fake-asr",
            revision: revision,
            quantization: "test"
        )
    }

    func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        let language: String
        switch request.language {
        case .automatic:
            language = "auto"
        case let .fixed(identifier):
            language = identifier
        }
        let term = request.glossary?.entries.first ?? "none"
        return ASRResult(
            rawText: "\(language):\(term)",
            segments: [],
            glossaryApplied: request.glossary != nil && request.injectionMode != .none
        )
    }
}

private struct FakeDiarizerBackend: DiarizerBackend {
    let descriptor = BackendDescriptor(name: "fake-diarizer", version: "1")
    let model: ModelDescriptor

    init(revision: String) {
        model = ModelDescriptor(
            role: .diarization,
            hfModelID: "example/fake-diarizer",
            revision: revision,
            quantization: "test"
        )
    }

    func diarize(_ request: DiarizationRequest) async throws -> Timeline {
        let bounds = request.speakerCountHint ?? 1...1
        return Timeline(segments: [
            TimelineSegment(
                speaker: String(format: "SPEAKER_%02d", bounds.lowerBound),
                startS: 0,
                endS: 1
            ),
            TimelineSegment(
                speaker: String(format: "SPEAKER_%02d", bounds.upperBound),
                startS: 1,
                endS: 2
            ),
        ])
    }
}
