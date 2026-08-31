import Darwin
import Foundation
import Testing
@testable import MaccheroniCore
@testable import MaccheroniPostprocess

@Suite(.serialized)
struct SubprocessCancellationTests {
    @Test
    func cancellationEscalatesAndLeavesNoIgnoringChild() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidURL = root.appendingPathComponent("pid")
        let readinessURL = root.appendingPathComponent("ready")
        let script = try ignoringTERMExecutable(in: root, pidURL: pidURL, readinessURL: readinessURL)
        let executor = FoundationSubprocessExecutor(
            terminationTiming: ProcessTerminationTiming(gracePeriodS: 0.02, pollIntervalS: 0.005, exitWaitS: 0.5)
        )
        let execution = Task {
            try await executor.run(SubprocessInvocation(
                executableURL: script,
                arguments: [],
                standardInput: Data(),
                timeoutS: 60
            ))
        }
        let pid = try await readyPID(for: execution, pidURL: pidURL, readinessURL: readinessURL)
        defer { _ = Darwin.kill(pid, SIGKILL) }

        let startedAt = Date()
        execution.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await execution.value
        }

        #expect(Date().timeIntervalSince(startedAt) < 0.75)
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func timeoutEscalatesAndPreservesTheCurrentTimeoutError() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidURL = root.appendingPathComponent("pid")
        let readinessURL = root.appendingPathComponent("ready")
        let script = try ignoringTERMExecutable(in: root, pidURL: pidURL, readinessURL: readinessURL)
        let executor = FoundationSubprocessExecutor(
            terminationTiming: ProcessTerminationTiming(gracePeriodS: 0.02, pollIntervalS: 0.005, exitWaitS: 0.5)
        )
        let execution = Task {
            try await executor.run(SubprocessInvocation(
                executableURL: script,
                arguments: [],
                standardInput: Data(),
                timeoutS: 5
            ))
        }
        let pid = try await readyPID(
            for: execution,
            pidURL: pidURL,
            readinessURL: readinessURL
        )
        defer { _ = Darwin.kill(pid, SIGKILL) }

        let startedAt = Date()
        await #expect(throws: PostprocessError.backendFailed("subprocess timed out after 5 seconds")) {
            _ = try await execution.value
        }
        #expect(Date().timeIntervalSince(startedAt) < 6)
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    private func ignoringTERMExecutable(in root: URL, pidURL: URL, readinessURL: URL) throws -> URL {
        let script = root.appendingPathComponent("ignores-term.sh")
        try Data("""
        #!/bin/sh
        trap '' TERM
        printf '%s' "$$" > '\(pidURL.path)'
        printf '%s\\n' 'sigterm-handler-and-pid-ready' > '\(readinessURL.path)'
        exec /usr/bin/tail -f /dev/null
        """.utf8).write(to: script, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func readyPID(
        for execution: Task<SubprocessOutput, Error>,
        pidURL: URL,
        readinessURL: URL,
        readinessTimeout: Duration = .seconds(10)
    ) async throws -> Int32 {
        do {
            return try await waitForReadyPID(
                at: pidURL,
                readinessURL: readinessURL,
                timeout: readinessTimeout
            )
        } catch {
            execution.cancel()
            _ = try? await execution.value
            throw error
        }
    }

    private func waitForReadyPID(at pidURL: URL, readinessURL: URL, timeout: Duration) async throws -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let isReady = (try? String(contentsOf: readinessURL, encoding: .utf8))
                == "sigterm-handler-and-pid-ready\n"
            if isReady,
               let value = try? String(contentsOf: pidURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(value),
               Darwin.kill(pid, 0) == 0 {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ReadinessTimeoutError()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccheroni-subprocess-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private struct ReadinessTimeoutError: Error {}
