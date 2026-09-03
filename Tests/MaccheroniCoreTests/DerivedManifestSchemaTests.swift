import Foundation
import Testing
@testable import MaccheroniCore

/// The published `derived-manifest.schema.json` is the contract the canonical
/// scorer validates a sealed set against. These tests encode each derived form
/// this package writes and validate the bytes against that file, so a manifest
/// the application produces and a manifest the contract accepts cannot drift
/// apart unnoticed.
@Suite struct DerivedManifestSchemaTests {
    private let sourceManifestHash = String(repeating: "1", count: 64)
    private let sourceSegmentsHash = String(repeating: "2", count: 64)
    private let glossaryHash = String(repeating: "4", count: 64)
    private let artifactHash = String(repeating: "5", count: 64)
    private let secondArtifactHash = String(repeating: "6", count: 64)

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func validator() throws -> JSONSchemaValidator {
        try JSONSchemaValidator(
            schemaURL: repositoryRoot.appendingPathComponent(
                "docs/contracts/derived-manifest.schema.json"
            ),
            siblingFileNames: ["manifest.schema.json"]
        )
    }

    private func encoded(_ manifest: DerivedManifest) throws -> JSONValue {
        try JSONValue.parse(try JSONEncoder().encode(manifest))
    }

    private func batching() -> ManifestPostprocessBatching {
        ManifestPostprocessBatching(
            maximumPromptUTF8Bytes: 16_384,
            maximumSegmentsPerBatch: 32,
            maximumOutputTokens: nil,
            outputTokenLimitStatus: .serviceManagedUnavailable,
            outputTokenPlanningBudget: 4_096,
            outputTokensPerInputUTF8BytePermille: 2_000,
            baseOutputTokenReserve: 32,
            perSegmentOutputTokenReserve: 96,
            batchesPlanned: 1,
            maximumObservedPromptUTF8Bytes: 412,
            maximumObservedInputTextUTF8Bytes: 96,
            maximumObservedEstimatedOutputTokens: 320,
            maximumObservedOutputTextUTF8Bytes: 101,
            maximumObservedResponseUTF8Bytes: 188,
            maximumObservedAcceptedOutputTokenUpperBound: 353
        )
    }

    private var lineage: DerivedSourceLineage {
        DerivedSourceLineage(
            runID: "20260901T101500Z-ab12cd",
            manifestSHA256: sourceManifestHash,
            segmentsPath: "merged/segments.json",
            segmentsSHA256: sourceSegmentsHash
        )
    }

    private var timing: RunTiming {
        RunTiming(
            startedAt: "2026-09-02T03:00:00Z",
            finishedAt: "2026-09-02T03:00:05Z",
            wallTimeS: 5
        )
    }

    private var completeCoverage: DerivedSourceCoverage {
        DerivedSourceCoverage(
            complete: true,
            inputDurationS: 1_243.08,
            processedDurationS: 1_243.08,
            message: nil
        )
    }

    private var partialCoverage: DerivedSourceCoverage {
        DerivedSourceCoverage(
            complete: false,
            inputDurationS: 1_243.08,
            processedDurationS: 1_212.52,
            message: "1 range(s) produced no transcript: [871.552, 902.112) s"
        )
    }

    /// The correction set an existing-run post-process seals.
    private func correctionManifest() -> DerivedManifest {
        DerivedManifest(
            derivedID: "20260902T030000Z-3f9c1a",
            status: .succeeded,
            source: lineage,
            operation: DerivedOperation(
                profileName: "ko-meeting",
                mode: .correction,
                targetLanguage: nil,
                glossarySemantics: .currentProfile,
                glossarySHA256: glossaryHash,
                glossaryItemCount: 7,
                sourceCoverage: completeCoverage
            ),
            timing: timing,
            artifacts: [
                Artifact(
                    kind: "postprocess_segments",
                    path: "postprocess/segments.json",
                    sha256: artifactHash
                ),
                Artifact(
                    kind: "postprocess_conflicts",
                    path: "postprocess/conflicts.json",
                    sha256: secondArtifactHash
                ),
            ],
            failure: nil,
            postprocess: ManifestPostprocess(
                backend: BackendDescriptor(
                    name: "codex-app-server",
                    version: "codex-cli 0.146.0"
                ),
                modelID: "gpt-5.6-sol",
                glossarySHA256: glossaryHash,
                mode: .correction,
                targetLanguage: nil,
                sourceSegmentsSHA256: nil,
                batching: batching()
            )
        )
    }

    /// The translation set an existing-run post-process seals.
    private func translationManifest() -> DerivedManifest {
        DerivedManifest(
            derivedID: "20260902T031000Z-77aa01",
            status: .succeeded,
            source: lineage,
            operation: DerivedOperation(
                profileName: "ko-meeting",
                mode: .translation,
                targetLanguage: "en",
                glossarySemantics: .sourceRun,
                glossarySHA256: glossaryHash,
                glossaryItemCount: 7,
                sourceCoverage: completeCoverage
            ),
            timing: timing,
            artifacts: [Artifact(
                kind: "postprocess_translation",
                path: "postprocess/translation.json",
                sha256: artifactHash
            )],
            failure: nil,
            postprocess: ManifestPostprocess(
                backend: BackendDescriptor(
                    name: "codex-app-server",
                    version: "codex-cli 0.146.0"
                ),
                modelID: "gpt-5.6-sol",
                glossarySHA256: glossaryHash,
                mode: .translation,
                targetLanguage: "en",
                sourceSegmentsSHA256: sourceSegmentsHash,
                batching: batching()
            )
        )
    }

    /// The D46/D49 speaker-proposal set: one artifact, no glossary, a non-null
    /// source transcript hash, and the source coverage it was made over.
    private func speakerProposalManifest() -> DerivedManifest {
        DerivedManifest(
            derivedID: "20260902T032000Z-91bb42",
            status: .succeeded,
            source: lineage,
            operation: DerivedOperation(
                profileName: "ko-meeting",
                mode: .correction,
                targetLanguage: nil,
                glossarySemantics: .currentProfile,
                glossarySHA256: nil,
                glossaryItemCount: 0,
                kind: .speakerProposal,
                sourceCoverage: partialCoverage
            ),
            timing: timing,
            artifacts: [Artifact(
                kind: "speaker_proposals",
                path: "speaker/proposals.json",
                sha256: artifactHash
            )],
            failure: nil,
            postprocess: ManifestPostprocess(
                backend: BackendDescriptor(
                    name: "codex-app-server",
                    version: "codex-cli 0.146.0"
                ),
                modelID: "gpt-5.6-sol",
                glossarySHA256: nil,
                mode: .correction,
                targetLanguage: nil,
                sourceSegmentsSHA256: sourceSegmentsHash,
                batching: batching()
            )
        )
    }

    @Test func everyDerivedFormThisPackageWritesValidatesAgainstItsSchema() throws {
        let validator = try validator()
        for (name, manifest) in [
            ("correction", correctionManifest()),
            ("translation", translationManifest()),
            ("speaker proposal", speakerProposalManifest()),
        ] {
            let failures = validator.failures(for: try encoded(manifest))
            #expect(failures.isEmpty, "\(name): \(failures)")
        }
    }

    @Test func theSchemaStillAcceptsAManifestWrittenBeforeTheKindField() throws {
        let validator = try validator()
        let example = try JSONValue.parse(try Data(contentsOf: repositoryRoot
            .appendingPathComponent(
                "benchmarks/scripts/scoring/fixtures/derived-manifest.example.json"
            )))
        #expect(validator.failures(for: example).isEmpty)
    }

    @Test func theSchemaRejectsDerivedFormsThatBreakTheirOwnShape() throws {
        let validator = try validator()

        // A proposal that does not say how much of the source it covers is the
        // claim D49 exists to prevent.
        var coverageless = try encoded(speakerProposalManifest())
        mutateOperation(&coverageless) { $0["source_coverage"] = nil }
        #expect(!validator.failures(for: coverageless).isEmpty)

        // The proposal form carries exactly one artifact.
        var twoArtifacts = try encoded(speakerProposalManifest())
        if case .object(var root) = twoArtifacts,
           case .array(let artifacts) = root["artifacts"] ?? .null
        {
            root["artifacts"] = .array(artifacts + artifacts)
            twoArtifacts = .object(root)
        }
        #expect(!validator.failures(for: twoArtifacts).isEmpty)

        // A correction still has to be a correction: the text forms did not
        // become permissive when the proposal form arrived.
        var correctionMissingConflicts = try encoded(correctionManifest())
        if case .object(var root) = correctionMissingConflicts,
           case .array(let artifacts) = root["artifacts"] ?? .null
        {
            root["artifacts"] = .array(Array(artifacts.prefix(1)))
            correctionMissingConflicts = .object(root)
        }
        #expect(!validator.failures(for: correctionMissingConflicts).isEmpty)

        // An unknown operation key is still an unknown operation key.
        var strayKey = try encoded(speakerProposalManifest())
        mutateOperation(&strayKey) { $0["acoustic_leader"] = .string("0") }
        #expect(!validator.failures(for: strayKey).isEmpty)
    }

    private func mutateOperation(
        _ manifest: inout JSONValue,
        _ change: (inout [String: JSONValue]) -> Void
    ) {
        guard case .object(var root) = manifest,
              case .object(var operation) = root["operation"] ?? .null
        else { return }
        change(&operation)
        root["operation"] = .object(operation)
        manifest = .object(root)
    }
}
