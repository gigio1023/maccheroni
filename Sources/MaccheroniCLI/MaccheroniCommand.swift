import ArgumentParser

@main
struct MaccheroniCommand: AsyncParsableCommand {
    static var _errorPrefix: String { "" }

    static let configuration = CommandConfiguration(
        commandName: "maccheroni",
        abstract: "Transcribe mixed-language audio locally on Apple Silicon.",
        discussion: """
        Choose a command below to inspect the local setup or create a transcription run.
        Audio stays on this Mac. Commands never prompt for input.

        EXAMPLES:
          maccheroni help run
          maccheroni doctor --json
          maccheroni capabilities --json
        """,
        subcommands: [
            HelpCommand.self,
            RunCommand.self,
            DoctorCommand.self,
            CapabilitiesCommand.self,
        ]
    )
}
