import Foundation

enum CLIOutputError: Error, LocalizedError {
    case malformedDoctorLine(String)
    case duplicateDoctorKey(String)
    case encoding(String)
    case write(String)

    var errorDescription: String? {
        switch self {
        case let .malformedDoctorLine(line):
            "doctor returned a malformed diagnostic line: \(line)"
        case let .duplicateDoctorKey(key):
            "doctor returned a duplicate diagnostic key: \(key)"
        case let .encoding(message):
            "could not encode CLI JSON output: \(message)"
        case let .write(message):
            "could not write CLI output: \(message)"
        }
    }
}

enum CLIOutput {
    static let schemaVersion = "1.0.0"

    static let commandCapabilities = [
        CommandCapability(
            name: "help",
            summary: "Show root or command-specific help.",
            sideEffect: "None; reads and writes no product data.",
            output: "Human-readable usage on stdout.",
            supportsJSON: false
        ),
        CommandCapability(
            name: "run",
            summary: "Create a local transcription run from audio.",
            sideEffect: "Creates a new run directory and may download local model assets.",
            output: "Run directory path or a JSON run_path envelope on stdout.",
            supportsJSON: true
        ),
        CommandCapability(
            name: "doctor",
            summary: "Inspect local profile and dependency readiness.",
            sideEffect: "None; performs read-only local checks.",
            output: "key=value diagnostics or a JSON readiness envelope on stdout.",
            supportsJSON: true
        ),
        CommandCapability(
            name: "capabilities",
            summary: "List commands and their contracts.",
            sideEffect: "None; reports static metadata only.",
            output: "Command inventory as text or JSON on stdout.",
            supportsJSON: true
        ),
    ]

    static func runJSON(runPath: String) throws -> String {
        try encode(RunEnvelope(
            command: "run",
            runPath: runPath,
            schemaVersion: schemaVersion
        ))
    }

    static func doctorJSON(
        diagnostics: String,
        ready: Bool = true
    ) throws -> String {
        try encode(DoctorEnvelope(
            command: "doctor",
            ready: ready,
            schemaVersion: schemaVersion,
            values: try doctorValues(from: diagnostics)
        ))
    }

    static func capabilitiesJSON() throws -> String {
        try encode(CapabilitiesEnvelope(
            command: "capabilities",
            commands: commandCapabilities,
            program: "maccheroni",
            schemaVersion: schemaVersion
        ))
    }

    static func capabilitiesText() -> String {
        commandCapabilities.map { capability in
            "\(capability.name): \(capability.summary) "
                + "Side effect: \(capability.sideEffect) "
                + "Output: \(capability.output)"
        }.joined(separator: "\n")
    }

    static func doctorValues(from diagnostics: String) throws -> [String: String] {
        var lines = diagnostics.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        var values: [String: String] = [:]
        for line in lines {
            guard !line.isEmpty,
                  let separator = line.firstIndex(of: "=")
            else {
                throw CLIOutputError.malformedDoctorLine(line)
            }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard key.range(
                of: "^[A-Za-z0-9][A-Za-z0-9_.-]*$",
                options: .regularExpression
            ) != nil else {
                throw CLIOutputError.malformedDoctorLine(line)
            }
            guard values[key] == nil else {
                throw CLIOutputError.duplicateDoctorKey(key)
            }
            values[key] = privacyBoundDoctorValue(value)
        }
        return values
    }

    static func write(_ value: String) throws {
        let data = Data((value + "\n").utf8)
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            throw CLIOutputError.write(error.localizedDescription)
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value)
            guard let output = String(data: data, encoding: .utf8) else {
                throw CLIOutputError.encoding("encoder produced non-UTF-8 data")
            }
            return output
        } catch let error as CLIOutputError {
            throw error
        } catch {
            throw CLIOutputError.encoding(error.localizedDescription)
        }
    }

    private static func privacyBoundDoctorValue(_ value: String) -> String {
        var output = ""
        var token = ""
        for character in value {
            if character.isWhitespace {
                output += redactedPathToken(token)
                output.append(character)
                token = ""
            } else {
                token.append(character)
            }
        }
        return output + redactedPathToken(token)
    }

    private static func redactedPathToken(_ token: String) -> String {
        if token.hasPrefix("/") || token.hasPrefix("file:///") {
            return "<redacted-path>"
        }
        return token
    }
}

struct CommandCapability: Codable, Equatable {
    var name: String
    var summary: String
    var sideEffect: String
    var output: String
    var supportsJSON: Bool

    enum CodingKeys: String, CodingKey {
        case name, summary, output
        case sideEffect = "side_effect"
        case supportsJSON = "supports_json"
    }
}

private struct RunEnvelope: Codable {
    var command: String
    var runPath: String
    var schemaVersion: String

    enum CodingKeys: String, CodingKey {
        case command
        case runPath = "run_path"
        case schemaVersion = "schema_version"
    }
}

private struct DoctorEnvelope: Codable {
    var command: String
    var ready: Bool
    var schemaVersion: String
    var values: [String: String]

    enum CodingKeys: String, CodingKey {
        case command, ready, values
        case schemaVersion = "schema_version"
    }
}

private struct CapabilitiesEnvelope: Codable {
    var command: String
    var commands: [CommandCapability]
    var program: String
    var schemaVersion: String

    enum CodingKeys: String, CodingKey {
        case command, commands, program
        case schemaVersion = "schema_version"
    }
}
