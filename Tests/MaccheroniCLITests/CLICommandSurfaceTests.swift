import ArgumentParser
import Foundation
import Testing
@testable import MaccheroniCLI

@Suite(.serialized)
struct CLICommandSurfaceTests {
    @Test
    func rootAndExplicitHelpExposeTheCompleteContract() throws {
        let flagHelp = try invoke(["--help"])
        let shortHelp = try invoke(["-h"])
        let explicitHelp = try invoke(["help"])

        for result in [flagHelp, shortHelp, explicitHelp] {
            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            for fragment in Fixture.rootHelpFragments {
                #expect(result.stdout.contains(fragment))
            }
        }
        #expect(shortHelp.stdout == flagHelp.stdout)
        #expect(explicitHelp.stdout == flagHelp.stdout)
    }

    @Test
    func explicitAndFlagHelpAreEquivalentForEveryProductCommand() throws {
        for fixture in Fixture.commandHelp {
            let explicit = try invoke(["help", fixture.name])
            let flag = try invoke([fixture.name, "--help"])

            #expect(explicit.status == 0)
            #expect(flag.status == 0)
            #expect(explicit.stderr.isEmpty)
            #expect(flag.stderr.isEmpty)
            #expect(explicit.stdout == flag.stdout)
            for fragment in fixture.fragments {
                #expect(explicit.stdout.contains(fragment))
            }
        }
    }

    @Test
    func unknownCommandsTopicsAndOptionsFailWithoutResultOutput() throws {
        let cases = [
            (["unknown-command"], "Unexpected argument 'unknown-command'"),
            (["help", "unknown-topic"], "is invalid for '<topic>'"),
            (["capabilities", "--unknown-option"], "Unknown option '--unknown-option'"),
        ]

        for (arguments, diagnostic) in cases {
            let result = try invoke(arguments)
            #expect(result.status != 0)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains(diagnostic))
            #expect(!result.stderr.contains("\"schema_version\""))
        }
    }

    @Test
    func legacyAndLeadingDashValuesParseWithoutLoss() throws {
        let parsedRun = try #require(
            MaccheroniCommand.parseAsRoot([
                "run", "recording.wav",
                "--profile", "it-dialogue",
                "--profiles", "profiles.json",
                "--output-root", "runs",
                "--glossary", "terms.txt",
            ]) as? RunCommand
        )
        #expect(parsedRun.audio == "recording.wav")
        #expect(parsedRun.profile == "it-dialogue")
        #expect(parsedRun.profiles == "profiles.json")
        #expect(parsedRun.outputRoot == "runs")
        #expect(parsedRun.glossary == "terms.txt")
        #expect(!parsedRun.json)

        let parsedDoctor = try #require(
            MaccheroniCommand.parseAsRoot([
                "doctor", "--profile", "ko-meeting",
                "--profiles", "profiles.json",
            ]) as? DoctorCommand
        )
        #expect(parsedDoctor.profile == "ko-meeting")
        #expect(parsedDoctor.profiles == "profiles.json")
        #expect(!parsedDoctor.json)

        let leadingProfile = try #require(
            MaccheroniCommand.parseAsRoot([
                "run", "recording.wav", "--profile=--profile-name",
            ]) as? RunCommand
        )
        #expect(leadingProfile.profile == "--profile-name")

        let leadingAudio = try #require(
            MaccheroniCommand.parseAsRoot([
                "run", "--profile", "it-dialogue", "--", "--recording.wav",
            ]) as? RunCommand
        )
        #expect(leadingAudio.audio == "--recording.wav")
    }

    @Test
    func generatedZshCompletionIsAvailableForTheCommandInventory() throws {
        let result = try invoke(["--generate-completion-script", "zsh"])

        #expect(result.status == 0)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.contains("#compdef maccheroni"))
        #expect(result.stdout.contains("_maccheroni"))
        for name in Fixture.commandNames {
            #expect(result.stdout.contains(name))
        }
    }

    @Test
    func JSONSchemasAreExactSortedAndDeterministic() throws {
        let run = try CLIOutput.runJSON(runPath: Fixture.runPath)
        #expect(run == Fixture.runJSON)
        #expect(try CLIOutput.runJSON(runPath: Fixture.runPath) == run)

        let doctor = try CLIOutput.doctorJSON(
            diagnostics: "zeta=last\nalpha=one=two"
        )
        #expect(doctor == Fixture.doctorJSON)
        #expect(try CLIOutput.doctorJSON(
            diagnostics: "zeta=last\nalpha=one=two"
        ) == doctor)

        let capabilities = try CLIOutput.capabilitiesJSON()
        #expect(capabilities == Fixture.capabilitiesJSON)
        #expect(try CLIOutput.capabilitiesJSON() == capabilities)

        let runObject = try jsonObject(run)
        #expect(Set(runObject.keys) == ["command", "run_path", "schema_version"])
        #expect(runObject["command"] as? String == "run")
        #expect(runObject["schema_version"] as? String == "1.0.0")

        let doctorObject = try jsonObject(doctor)
        #expect(Set(doctorObject.keys) == [
            "command", "ready", "schema_version", "values",
        ])
        #expect(doctorObject["ready"] as? Bool == true)
        #expect(doctorObject["values"] as? [String: String] == [
            "alpha": "one=two",
            "zeta": "last",
        ])

        let privateDoctor = try CLIOutput.doctorJSON(
            diagnostics: "asr_error=missing /Users/private/model.bin"
        )
        let privateDoctorObject = try jsonObject(privateDoctor)
        let privateValues = try #require(
            privateDoctorObject["values"] as? [String: String]
        )
        #expect(privateValues["asr_error"] == "missing <redacted-path>")

        let capabilitiesObject = try jsonObject(capabilities)
        #expect(Set(capabilitiesObject.keys) == [
            "command", "commands", "program", "schema_version",
        ])
        #expect(capabilitiesObject["program"] as? String == "maccheroni")
        let entries = try #require(
            capabilitiesObject["commands"] as? [[String: Any]]
        )
        for entry in entries {
            #expect(Set(entry.keys) == [
                "name", "summary", "side_effect", "output", "supports_json",
            ])
        }
    }

    @Test
    func doctorDiagnosticsPreserveFirstEqualsAndRejectMalformedOrDuplicateKeys() throws {
        #expect(try CLIOutput.doctorValues(
            from: "profile=ko-meeting\nmodel.revision=a=b=c\n"
        ) == [
            "profile": "ko-meeting",
            "model.revision": "a=b=c",
        ])

        assertDoctorFailure("missing-separator") { error in
            guard case .malformedDoctorLine("missing-separator") = error else {
                return false
            }
            return true
        }
        assertDoctorFailure("bad key=value") { error in
            guard case .malformedDoctorLine("bad key=value") = error else {
                return false
            }
            return true
        }
        assertDoctorFailure("profile=one\nprofile=two") { error in
            guard case .duplicateDoctorKey("profile") = error else {
                return false
            }
            return true
        }
        assertDoctorFailure("profile=one\n\nmodel=two") { error in
            guard case .malformedDoctorLine("") = error else { return false }
            return true
        }
    }

    @Test
    func doctorFailureIsMachineReadableAndProductErrorsStayUnprefixed() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaccheroniDoctorFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let failedDoctor = try invoke(
            ["doctor", "--json"],
            environment: ["MACCHERONI_BENCHMARK_CACHE": fixtureRoot.path]
        )
        #expect(failedDoctor.status == 1)
        #expect(failedDoctor.stderr.isEmpty)
        #expect(failedDoctor.stdout.filter { $0 == "\n" }.count == 1)
        #expect(!failedDoctor.stdout.contains(fixtureRoot.path))
        #expect(failedDoctor.stdout.contains("<redacted-path>"))
        let failedObject = try jsonObject(failedDoctor.stdout)
        #expect(failedObject["command"] as? String == "doctor")
        #expect(failedObject["ready"] as? Bool == false)
        let failedValues = try #require(
            failedObject["values"] as? [String: String]
        )
        #expect(failedValues.values.contains("false"))

        let missingRegistry = fixtureRoot.appendingPathComponent("missing.json")
        let productFailure = try invoke([
            "doctor", "--profiles", missingRegistry.path,
        ])
        #expect(productFailure.status == 1)
        #expect(productFailure.stdout.isEmpty)
        #expect(!productFailure.stderr.hasPrefix("Error: "))
        #expect(productFailure.stderr == (
            "profile registry is unreadable: \(missingRegistry.path)\n"
        ))
    }

    @Test
    func RootHelpAndCapabilitiesHaveTheSameCommandInventory() throws {
        let help = try invoke(["--help"])
        let helpNames = commandNames(inRootHelp: help.stdout)
        let capabilityObject = try jsonObject(CLIOutput.capabilitiesJSON())
        let entries = try #require(
            capabilityObject["commands"] as? [[String: Any]]
        )
        let capabilityNames = entries.compactMap { $0["name"] as? String }

        #expect(helpNames == Fixture.commandNames)
        #expect(capabilityNames == Fixture.commandNames)
    }

    @Test
    func capabilityResultsArePureNewlineTerminatedAndPrivacyBounded() throws {
        let text = try invoke(["capabilities"])
        let json = try invoke(["capabilities", "--json"])

        #expect(text.status == 0)
        #expect(json.status == 0)
        #expect(text.stderr.isEmpty)
        #expect(json.stderr.isEmpty)
        #expect(text.stdout == CLIOutput.capabilitiesText() + "\n")
        let expectedJSON = try CLIOutput.capabilitiesJSON() + "\n"
        #expect(json.stdout == expectedJSON)
        #expect(json.stdout.filter { $0 == "\n" }.count == 1)
        #expect(!text.stdout.contains("\u{001B}"))
        #expect(!json.stdout.contains("\u{001B}"))

        for sentinel in Fixture.privateContentSentinels {
            #expect(!text.stdout.contains(sentinel))
            #expect(!json.stdout.contains(sentinel))
        }
    }
}

private enum Fixture {
    static let commandNames = ["help", "run", "doctor", "capabilities"]

    static let rootHelpFragments = [
        "OVERVIEW: Transcribe mixed-language audio locally on Apple Silicon.",
        "Audio stays on this Mac.",
        "USAGE: maccheroni <subcommand>",
        "maccheroni help run",
        "maccheroni doctor --json",
        "maccheroni capabilities --json",
    ]

    static let commandHelp: [(name: String, fragments: [String])] = [
        (
            "help",
            [
                "Show root or command-specific help.",
                "Prints help only.",
                "No audio or transcript data is read or emitted.",
                "maccheroni help run",
            ]
        ),
        (
            "run",
            [
                "Create a new local transcription run from an audio file.",
                "Requires an audio path and profile name.",
                "Creates a new run directory",
                "may download and use model",
                "assets stored locally",
                "Audio remains on this Mac.",
                "maccheroni run recording.wav --profile it-dialogue",
            ]
        ),
        (
            "doctor",
            [
                "Inspect whether a local profile and its dependencies are ready.",
                "command is read-only",
                "key=value diagnostics",
                "No audio, transcript, or glossary contents are read or emitted.",
                "maccheroni doctor --profile ko-meeting --json",
            ]
        ),
        (
            "capabilities",
            [
                "List the CLI commands, side effects, and output contracts.",
                "This command is read-only.",
                "static command metadata",
                "No private paths, audio, transcript, glossary, token, or credential",
                "maccheroni capabilities --json",
            ]
        ),
    ]

    static let runPath = "/tmp/maccheroni-runs/fixture"
    static let runJSON =
        "{\"command\":\"run\",\"run_path\":\"/tmp/maccheroni-runs/fixture\","
        + "\"schema_version\":\"1.0.0\"}"
    static let doctorJSON =
        "{\"command\":\"doctor\",\"ready\":true,"
        + "\"schema_version\":\"1.0.0\","
        + "\"values\":{\"alpha\":\"one=two\",\"zeta\":\"last\"}}"
    static let capabilitiesJSON =
        "{\"command\":\"capabilities\",\"commands\":["
        + "{\"name\":\"help\",\"output\":\"Human-readable usage on stdout.\","
        + "\"side_effect\":\"None; reads and writes no product data.\","
        + "\"summary\":\"Show root or command-specific help.\",\"supports_json\":false},"
        + "{\"name\":\"run\",\"output\":\"Run directory path or a JSON run_path envelope on stdout.\","
        + "\"side_effect\":\"Creates a new run directory and may download local model assets.\","
        + "\"summary\":\"Create a local transcription run from audio.\",\"supports_json\":true},"
        + "{\"name\":\"doctor\",\"output\":\"key=value diagnostics or a JSON readiness envelope on stdout.\","
        + "\"side_effect\":\"None; performs read-only local checks.\","
        + "\"summary\":\"Inspect local profile and dependency readiness.\",\"supports_json\":true},"
        + "{\"name\":\"capabilities\",\"output\":\"Command inventory as text or JSON on stdout.\","
        + "\"side_effect\":\"None; reports static metadata only.\","
        + "\"summary\":\"List commands and their contracts.\",\"supports_json\":true}],"
        + "\"program\":\"maccheroni\",\"schema_version\":\"1.0.0\"}"

    static let privateContentSentinels = [
        "PRIVATE_TRANSCRIPT_FIXTURE: roadmap discussion",
        "PRIVATE_GLOSSARY_FIXTURE: internal-product-codename",
        "/Users/private/recordings/meeting.wav",
        "PRIVATE_TOKEN_FIXTURE",
    ]
}

private struct InvocationResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

private func invoke(
    _ arguments: [String],
    environment overrides: [String: String] = [:]
) throws -> InvocationResult {
    let process = Process()
    process.executableURL = try maccheroniExecutableURL()
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "COLUMNS")
    environment.removeValue(forKey: "LINES")
    for (key, value) in overrides {
        environment[key] = value
    }
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    return InvocationResult(
        status: process.terminationStatus,
        stdout: String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ),
        stderr: String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
    )
}

private func maccheroniExecutableURL() throws -> URL {
    let fileManager = FileManager.default
    let searchRoots = [
        URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        ),
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent(),
    ]

    for root in searchRoots {
        var directory = root
        for _ in 0..<12 {
            let package = directory.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: package.path) {
                let candidate = directory
                    .appendingPathComponent(".build/debug/maccheroni")
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }

            let adjacentCandidate = directory.appendingPathComponent("maccheroni")
            if fileManager.isExecutableFile(atPath: adjacentCandidate.path) {
                return adjacentCandidate
            }

            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
    }
    throw TestFixtureError.executableNotFound
}

private func jsonObject(_ json: String) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
    guard let object = value as? [String: Any] else {
        throw TestFixtureError.expectedJSONObject
    }
    return object
}

private func commandNames(inRootHelp help: String) -> [String] {
    guard let start = help.range(of: "SUBCOMMANDS:\n"),
          let end = help.range(
            of: "\n\n  See 'maccheroni help <subcommand>'",
            range: start.upperBound..<help.endIndex
          )
    else { return [] }

    return help[start.upperBound..<end.lowerBound]
        .split(separator: "\n")
        .compactMap { line in
            guard line.hasPrefix("  "), !line.hasPrefix("    ") else {
                return nil
            }
            return line.dropFirst(2).split(whereSeparator: \Character.isWhitespace)
                .first.map(String.init)
        }
}

private func assertDoctorFailure(
    _ diagnostics: String,
    matches: (CLIOutputError) -> Bool
) {
    do {
        _ = try CLIOutput.doctorValues(from: diagnostics)
        Issue.record("expected doctor diagnostics to be rejected: \(diagnostics)")
    } catch let error as CLIOutputError {
        #expect(matches(error))
    } catch {
        Issue.record("unexpected doctor diagnostics error: \(error)")
    }
}

private enum TestFixtureError: Error {
    case executableNotFound
    case expectedJSONObject
}
