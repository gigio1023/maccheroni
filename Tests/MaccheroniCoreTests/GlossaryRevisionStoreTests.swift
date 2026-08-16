import Foundation
import Testing
@testable import MaccheroniCore

@Suite struct GlossaryRevisionStoreTests {
    @Test
    func revisionRoundTripPreservesExactBOMCommentsCRLFAndTrailingBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlossaryRevisionStore(root: root)
        let data = Data("\u{FEFF}# owner note\r\nMaccheroni\r\n\r\n".utf8)

        let created = try #require(try store.createRevision(from: data))
        let resolved = try store.resolve(
            sha256: created.glossary.sha256,
            expectedItemCount: 1
        )

        #expect(resolved.data == data)
        #expect(resolved.glossary.entries == ["Maccheroni"])
        #expect(resolved.url == created.url)
        #expect(try Data(contentsOf: resolved.url) == data)
    }

    @Test
    func unchangedBytesReuseOneCreateOnlyRevisionWhileChangedBytesRemainResolvable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlossaryRevisionStore(root: root)
        let firstData = Data("# terms\nMaccheroni\n".utf8)
        let secondData = Data("# terms\nMaccheroni\nCoreAudio\n".utf8)

        let first = try #require(try store.createRevision(from: firstData))
        let unchanged = try #require(try store.createRevision(from: firstData))
        let second = try #require(try store.createRevision(from: secondData))

        #expect(first.url == unchanged.url)
        #expect(first.url != second.url)
        #expect(try regularFileNames(in: root) == [
            "\(first.glossary.sha256).txt",
            "\(second.glossary.sha256).txt",
        ].sorted())
        #expect(try store.resolve(
            sha256: first.glossary.sha256,
            expectedItemCount: 1
        ).data == firstData)
        #expect(try store.resolve(
            sha256: second.glossary.sha256,
            expectedItemCount: 2
        ).data == secondData)
    }

    @Test
    func zeroEntrySourceCreatesNoRevision() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlossaryRevisionStore(root: root)

        #expect(try store.createRevision(
            from: Data("# retained comment\r\n\r\n".utf8)
        ) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func missingAndTamperedRevisionsFailWithTypedUnavailableErrors() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlossaryRevisionStore(root: root)
        let data = Data("Maccheroni\n".utf8)
        let glossary = try Glossary.parse(data: data)

        do {
            _ = try store.resolve(
                sha256: glossary.sha256,
                expectedItemCount: 1
            )
            Issue.record("Expected a missing revision error")
        } catch let error as GlossaryRevisionError {
            #expect(error == .revisionUnavailable(
                sha256: glossary.sha256,
                reason: .missing
            ))
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let revisionURL = try store.revisionURL(for: glossary.sha256)
        let conflictingData = Data("different bytes\n".utf8)
        let conflictingSHA256 = try Glossary.parse(data: conflictingData).sha256
        try conflictingData.write(to: revisionURL, options: .withoutOverwriting)

        do {
            _ = try store.createRevision(from: data)
            Issue.record("Expected the conflicting revision to be rejected")
        } catch let error as GlossaryRevisionError {
            guard case let .revisionUnavailable(sha256, .hashMismatch(actualSHA256)) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(sha256 == glossary.sha256)
            #expect(actualSHA256 == conflictingSHA256)
        }
        #expect(try Data(contentsOf: revisionURL) == conflictingData)
    }

    @Test
    func unsearchableRevisionsDirectoryReportsUnreadableNotMissing() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.path
            )
            try? FileManager.default.removeItem(at: root)
        }
        let store = GlossaryRevisionStore(root: root)
        let data = Data("Maccheroni\n".utf8)
        let glossary = try Glossary.parse(data: data)
        _ = try store.createRevision(from: data)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: root.path
        )
        do {
            _ = try store.resolve(
                sha256: glossary.sha256,
                expectedItemCount: 1
            )
            Issue.record("Expected an unreadable revision error")
        } catch let error as GlossaryRevisionError {
            #expect(error == .revisionUnavailable(
                sha256: glossary.sha256,
                reason: .unreadable
            ))
        }
    }

    @Test
    func manifestResolutionChecksRecordedItemCountAndAbsentState() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GlossaryRevisionStore(root: root)
        let revision = try #require(try store.createRevision(
            from: Data("Maccheroni\nCoreAudio\n".utf8)
        ))

        #expect(try store.resolve(.absent) == nil)
        let provenance = ManifestGlossary(
            provided: true,
            sha256: revision.glossary.sha256,
            itemCount: 1,
            injectionMode: .freeTextContext,
            applied: true
        )
        do {
            _ = try store.resolve(provenance)
            Issue.record("Expected an item-count mismatch")
        } catch let error as GlossaryRevisionError {
            #expect(error == .revisionUnavailable(
                sha256: revision.glossary.sha256,
                reason: .itemCountMismatch(expected: 1, actual: 2)
            ))
        }
    }

    @Test
    func derivedSemanticsRoundTripSourceRunValue() throws {
        let encoded = try JSONEncoder().encode(DerivedGlossarySemantics.sourceRun)

        #expect(String(decoding: encoded, as: UTF8.self) == #""source-run""#)
        #expect(try JSONDecoder().decode(
            DerivedGlossarySemantics.self,
            from: encoded
        ) == .sourceRun)
    }

    @Test
    func derivedManifestSchemaAllowsBothGlossarySemantics() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
            "docs/contracts/derived-manifest.schema.json"
        ))
        let schema = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let definitions = try #require(schema["$defs"] as? [String: Any])
        let operation = try #require(definitions["operation"] as? [String: Any])
        let properties = try #require(operation["properties"] as? [String: Any])
        let semantics = try #require(
            properties["glossary_semantics"] as? [String: Any]
        )

        #expect(semantics["enum"] as? [String] == [
            "current-profile",
            "source-run",
        ])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniGlossaryRevisions-\(UUID().uuidString)",
            isDirectory: true
        )
        return url
    }

    private func regularFileNames(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.map(\.lastPathComponent).sorted()
    }
}
