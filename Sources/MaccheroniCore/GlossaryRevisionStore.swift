import Foundation

public struct GlossaryRevision: Equatable, Sendable {
    public let data: Data
    public let glossary: Glossary
    public let url: URL

    public init(data: Data, glossary: Glossary, url: URL) {
        self.data = data
        self.glossary = glossary
        self.url = url
    }
}

public enum GlossaryRevisionUnavailableReason: Equatable, Sendable {
    case missing
    case notRegularFile
    case unreadable
    case hashMismatch(actualSHA256: String)
    case invalidGlossary(GlossaryError)
    case emptyGlossary
    case itemCountMismatch(expected: Int, actual: Int)
}

public enum GlossaryRevisionError: Error, Equatable, Sendable {
    case invalidRevisionHash(String)
    case revisionUnavailable(
        sha256: String,
        reason: GlossaryRevisionUnavailableReason
    )
    case revisionCreationFailed(sha256: String)
}

extension GlossaryRevisionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidRevisionHash(sha256):
            "Invalid glossary revision hash: \(sha256)"
        case let .revisionCreationFailed(sha256):
            "The glossary revision could not be created: \(sha256)"
        case let .revisionUnavailable(sha256, reason):
            "Glossary revision unavailable: \(sha256) (\(reason.description))"
        }
    }
}

private extension GlossaryRevisionUnavailableReason {
    var description: String {
        switch self {
        case .missing:
            "missing"
        case .notRegularFile:
            "not a regular file"
        case .unreadable:
            "unreadable"
        case let .hashMismatch(actualSHA256):
            "hash mismatch: \(actualSHA256)"
        case let .invalidGlossary(error):
            "invalid glossary: \(String(describing: error))"
        case .emptyGlossary:
            "the stored source has no glossary entries"
        case let .itemCountMismatch(expected, actual):
            "item count mismatch: expected \(expected), found \(actual)"
        }
    }
}

public struct GlossaryRevisionStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public func revisionURL(for sha256: String) throws -> URL {
        guard Self.isValidRevisionHash(sha256) else {
            throw GlossaryRevisionError.invalidRevisionHash(sha256)
        }
        return root.appendingPathComponent("\(sha256).txt", isDirectory: false)
    }

    @discardableResult
    public func createRevision(from data: Data) throws -> GlossaryRevision? {
        guard let glossary = try Glossary.parseOptional(data: data) else {
            return nil
        }
        let target = try revisionURL(for: glossary.sha256)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let temporary = root.appendingPathComponent(
            ".\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
        } catch {
            throw GlossaryRevisionError.revisionCreationFailed(
                sha256: glossary.sha256
            )
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            try FileManager.default.linkItem(at: temporary, to: target)
        } catch {
            guard Self.pathEntryExists(target) else {
                throw GlossaryRevisionError.revisionCreationFailed(
                    sha256: glossary.sha256
                )
            }
        }

        let revision = try resolve(
            sha256: glossary.sha256,
            expectedItemCount: glossary.entries.count
        )
        guard revision.data == data else {
            throw GlossaryRevisionError.revisionUnavailable(
                sha256: glossary.sha256,
                reason: .hashMismatch(actualSHA256: revision.glossary.sha256)
            )
        }
        return revision
    }

    public func resolve(
        sha256: String,
        expectedItemCount: Int? = nil
    ) throws -> GlossaryRevision {
        let url = try revisionURL(for: sha256)
        guard Self.pathEntryExists(url) else {
            throw GlossaryRevisionError.revisionUnavailable(
                sha256: sha256,
                reason: .missing
            )
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw GlossaryRevisionError.revisionUnavailable(
                sha256: sha256,
                reason: Self.pathEntryExists(url) ? .unreadable : .missing
            )
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw GlossaryRevisionError.revisionUnavailable(
                sha256: sha256,
                reason: .notRegularFile
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .uncached)
        } catch {
            throw GlossaryRevisionError.revisionUnavailable(
                sha256: sha256,
                reason: .unreadable
            )
        }
        let parsed: Glossary
        do {
            parsed = try Glossary.parse(data: data)
        } catch let error as GlossaryError {
            throw GlossaryRevisionError.revisionUnavailable(
                sha256: sha256,
                reason: .invalidGlossary(error)
            )
        } catch {
            throw GlossaryRevisionError.revisionUnavailable(
                sha256: sha256,
                reason: .unreadable
            )
        }
        guard parsed.sha256 == sha256 else {
            throw GlossaryRevisionError.revisionUnavailable(
                sha256: sha256,
                reason: .hashMismatch(actualSHA256: parsed.sha256)
            )
        }
        guard !parsed.entries.isEmpty else {
            throw GlossaryRevisionError.revisionUnavailable(
                sha256: sha256,
                reason: .emptyGlossary
            )
        }
        if let expectedItemCount,
           parsed.entries.count != expectedItemCount
        {
            throw GlossaryRevisionError.revisionUnavailable(
                sha256: sha256,
                reason: .itemCountMismatch(
                    expected: expectedItemCount,
                    actual: parsed.entries.count
                )
            )
        }
        return GlossaryRevision(data: data, glossary: parsed, url: url)
    }

    public func resolve(_ provenance: ManifestGlossary) throws -> GlossaryRevision? {
        guard provenance.provided else { return nil }
        guard let sha256 = provenance.sha256 else {
            throw GlossaryRevisionError.invalidRevisionHash("")
        }
        return try resolve(
            sha256: sha256,
            expectedItemCount: provenance.itemCount
        )
    }

    private static func isValidRevisionHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func pathEntryExists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
