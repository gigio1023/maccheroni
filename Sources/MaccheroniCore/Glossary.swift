import CryptoKit
import Foundation

public struct Glossary: Codable, Equatable, Sendable {
    public var entries: [String]
    public var sha256: String

    public init(entries: [String], sha256: String) {
        self.entries = entries
        self.sha256 = sha256
    }

    public static func parse(data: Data) throws -> Glossary {
        guard !data.contains(0) else {
            throw GlossaryError.containsNUL
        }
        guard var contents = String(data: data, encoding: .utf8) else {
            throw GlossaryError.invalidUTF8
        }
        if contents.unicodeScalars.first == "\u{FEFF}" {
            contents.removeFirst()
        }

        var entries: [String] = []
        var seen = Set<String>()
        for (index, rawLine) in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let entry = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty, !entry.hasPrefix("#") else { continue }
            let normalized = entry.precomposedStringWithCanonicalMapping
            guard normalized.unicodeScalars.count <= 256 else {
                throw GlossaryError.entryTooLong(line: index + 1)
            }
            guard !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw GlossaryError.containsControlCharacter(line: index + 1)
            }
            if seen.insert(normalized).inserted {
                entries.append(normalized)
            }
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Glossary(entries: entries, sha256: digest)
    }

    /// Parses a glossary source and treats a valid source with no entries as absent.
    ///
    /// Comments and blank lines may remain in an operator-owned file after its
    /// final entry is removed. Callers preparing an operation should use this
    /// method so that such a file does not claim glossary injection or provenance.
    public static func parseOptional(data: Data) throws -> Glossary? {
        let glossary = try parse(data: data)
        return glossary.entries.isEmpty ? nil : glossary
    }

    public func payload(for mode: GlossaryInjectionMode) throws -> String {
        switch mode {
        case .freeTextContext:
            return entries.joined(separator: "\n")
        case .hotwordInstruction, .ctcVocabulary:
            return entries.joined(separator: "\n")
        case .none:
            guard entries.isEmpty else { throw GlossaryError.modeDoesNotAcceptEntries }
            return ""
        }
    }
}

public enum GlossaryError: Error, Equatable, Sendable {
    case invalidUTF8
    case containsNUL
    case entryTooLong(line: Int)
    case containsControlCharacter(line: Int)
    case modeDoesNotAcceptEntries
}
