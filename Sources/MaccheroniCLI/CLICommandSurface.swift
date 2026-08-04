import ArgumentParser
import Foundation

enum CLICommandSurface {
    static func runArguments(
        audio: String,
        profile: String,
        profiles: String?,
        outputRoot: String?,
        glossary: String?
    ) -> [String] {
        var arguments = ["run", audio, "--profile", profile]
        append("--profiles", value: profiles, to: &arguments)
        append("--output-root", value: outputRoot, to: &arguments)
        append("--glossary", value: glossary, to: &arguments)
        return arguments
    }

    static func doctorArguments(
        profile: String?,
        profiles: String?
    ) -> [String] {
        var arguments = ["doctor"]
        append("--profile", value: profile, to: &arguments)
        append("--profiles", value: profiles, to: &arguments)
        return arguments
    }

    static func help(for topic: HelpTopic?) -> String {
        switch topic {
        case nil:
            MaccheroniCommand.helpMessage()
        case .run:
            MaccheroniCommand.helpMessage(for: RunCommand.self)
        case .doctor:
            MaccheroniCommand.helpMessage(for: DoctorCommand.self)
        case .capabilities:
            MaccheroniCommand.helpMessage(for: CapabilitiesCommand.self)
        }
    }

    private static func append(
        _ option: String,
        value: String?,
        to arguments: inout [String]
    ) {
        guard let value else { return }
        arguments.append(contentsOf: [option, value])
    }
}

enum HelpTopic: String, CaseIterable, ExpressibleByArgument {
    case run
    case doctor
    case capabilities
}

struct HelpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "help",
        abstract: "Show root or command-specific help.",
        discussion: """
        Prints help only. It does not read audio, inspect models, or write files.

        OUTPUT:
          Human-readable command usage on standard output.

        PRIVACY:
          No audio or transcript data is read or emitted.

        EXAMPLES:
          maccheroni help
          maccheroni help run
        """
    )

    @Argument(help: "The command to explain: run, doctor, or capabilities.")
    var topic: HelpTopic?

    func run() throws {
        try CLIOutput.write(CLICommandSurface.help(for: topic))
    }
}

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Create a new local transcription run from an audio file.",
        discussion: """
        Requires an audio path and profile name. Creates a new run directory without
        overwriting an existing run. The selected profile may download and use model
        assets stored locally on this Mac.

        OUTPUT:
          Text mode prints the resulting run directory path. --json prints a stable
          object containing command, run_path, and schema_version.

        PRIVACY:
          Audio remains on this Mac. A profile may use a configured text-only
          post-processing backend, but audio is never sent to it.

        EXAMPLE:
          maccheroni run recording.wav --profile it-dialogue
        """
    )

    @Argument(help: "Path to the source audio file.")
    var audio: String

    @Option(name: .long, help: "Required transcription profile name.")
    var profile: String

    @Option(name: .long, help: "Path to a profile registry JSON file.")
    var profiles: String?

    @Option(
        name: .customLong("output-root"),
        help: "Directory under which the new run directory is created."
    )
    var outputRoot: String?

    @Option(name: .long, help: "Path to a glossary file injected during decoding.")
    var glossary: String?

    @Flag(name: .long, help: "Emit deterministic JSON instead of the run path.")
    var json = false

    mutating func run() async throws {
        let runPath = try await CLIApplication().execute(arguments: CLICommandSurface
            .runArguments(
                audio: audio,
                profile: profile,
                profiles: profiles,
                outputRoot: outputRoot,
                glossary: glossary
            ))
        if json {
            try CLIOutput.write(try CLIOutput.runJSON(runPath: runPath))
        } else {
            try CLIOutput.write(runPath)
        }
    }
}

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Inspect whether a local profile and its dependencies are ready.",
        discussion: """
        Uses the bundled default profile unless --profile selects another one. This
        command is read-only and does not create a run or download models.

        OUTPUT:
          Text mode prints the existing key=value diagnostics. --json prints those
          values as strings in a stable object.

        PRIVACY:
          No audio, transcript, or glossary contents are read or emitted.

        EXAMPLE:
          maccheroni doctor --profile ko-meeting --json
        """
    )

    @Option(name: .long, help: "Profile name to inspect (default: ko-meeting).")
    var profile: String?

    @Option(name: .long, help: "Path to a profile registry JSON file.")
    var profiles: String?

    @Flag(name: .long, help: "Emit deterministic JSON instead of key=value lines.")
    var json = false

    mutating func run() async throws {
        let diagnostics = try await CLIApplication().execute(
            arguments: CLICommandSurface.doctorArguments(
                profile: profile,
                profiles: profiles
            )
        )
        if json {
            try CLIOutput.write(try CLIOutput.doctorJSON(diagnostics: diagnostics))
        } else {
            try CLIOutput.write(diagnostics)
        }
    }
}

struct CapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "List the CLI commands, side effects, and output contracts.",
        discussion: """
        This command is read-only. It reports static command metadata and does not
        inspect local audio, profiles, model assets, credentials, or run artifacts.

        OUTPUT:
          Text mode prints a concise command inventory. --json prints the same
          inventory as a stable machine-readable object.

        PRIVACY:
          No private paths, audio, transcript, glossary, token, or credential data is
          read or emitted.

        EXAMPLE:
          maccheroni capabilities --json
        """
    )

    @Flag(name: .long, help: "Emit deterministic JSON instead of text.")
    var json = false

    func run() throws {
        if json {
            try CLIOutput.write(try CLIOutput.capabilitiesJSON())
        } else {
            try CLIOutput.write(CLIOutput.capabilitiesText())
        }
    }
}
