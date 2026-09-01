import Foundation
import Testing
@testable import MaccheroniASR
@testable import MaccheroniCore

@Suite(.serialized) struct MaccheroniASRTests {
    private let systemPython = URL(fileURLWithPath: "/usr/bin/python3")

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func expectRegularPackagedFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil)
    }

    @Test func packagedASRRunnerAndPinsAreAdjacentRegularFiles() throws {
        let runtime = ASRRuntime.localRuntime(
            environment: [:],
            home: URL(fileURLWithPath: "/packaged-asr-test", isDirectory: true)
        )
        let resourceDirectory = runtime.runnerURL.deletingLastPathComponent()

        for name in ["maccheroni_asr_runner.py", "pyproject.toml", "uv.lock"] {
            try expectRegularPackagedFile(resourceDirectory.appendingPathComponent(name))
        }
        #expect(runtime.runnerURL.lastPathComponent == "maccheroni_asr_runner.py")
    }

    private func scratchDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "maccheroni-asr-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func syntheticAudio(in directory: URL) throws -> URL {
        let sampleCount: UInt32 = 1_600
        let dataSize = sampleCount * 2
        var wav = Data()
        func appendASCII(_ value: String) {
            wav.append(contentsOf: value.utf8)
        }
        func appendUInt16LE(_ value: UInt16) {
            wav.append(UInt8(truncatingIfNeeded: value))
            wav.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func appendUInt32LE(_ value: UInt32) {
            wav.append(UInt8(truncatingIfNeeded: value))
            wav.append(UInt8(truncatingIfNeeded: value >> 8))
            wav.append(UInt8(truncatingIfNeeded: value >> 16))
            wav.append(UInt8(truncatingIfNeeded: value >> 24))
        }

        appendASCII("RIFF")
        appendUInt32LE(36 + dataSize)
        appendASCII("WAVEfmt ")
        appendUInt32LE(16)
        appendUInt16LE(1)
        appendUInt16LE(1)
        appendUInt32LE(16_000)
        appendUInt32LE(32_000)
        appendUInt16LE(2)
        appendUInt16LE(16)
        appendASCII("data")
        appendUInt32LE(dataSize)
        wav.append(Data(repeating: 0, count: Int(dataSize)))

        let audio = directory.appendingPathComponent("synthetic-silence.wav")
        try wav.write(to: audio, options: .withoutOverwriting)
        return audio
    }

    private func syntheticGlossary() throws -> Glossary {
        try Glossary.parse(data: Data("Maccheroni\nMLX\n".utf8))
    }

    private func fakeLimitRuntime(
        nonzeroExit: Bool = false,
        invalidEOSOutput: Bool = false,
        unsafeInvalidEOSMessage: Bool = false
    ) throws -> (ASRRuntime, URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccheroni-asr-fake-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let runner = scratch.appendingPathComponent(
            unsafeInvalidEOSMessage
                ? "invalid-eos-unsafe.py"
                : (invalidEOSOutput ? "invalid-eos.py" : (nonzeroExit ? "limit-nonzero.py" : "limit.py"))
        )
        let source = #"""
        import argparse, hashlib, json, pathlib, sys
        parser = argparse.ArgumentParser()
        parser.add_argument("operation"); parser.add_argument("--backend")
        parser.add_argument("--audio"); parser.add_argument("--start-s", type=float); parser.add_argument("--end-s", type=float)
        parser.add_argument("--language"); parser.add_argument("--glossary"); parser.add_argument("--glossary-sha256")
        parser.add_argument("--injection-mode"); parser.add_argument("--cache-root"); parser.add_argument("--output")
        parser.add_argument("--timeout-seconds"); parser.add_argument("--max-tokens")
        args = parser.parse_args()
        output = pathlib.Path(args.output); raw = output.with_suffix(".helper.json")
        raw.write_text('{"partial":"never promote"}\n', encoding="utf-8")
        invalid_eos = "invalid-eos" in pathlib.Path(sys.argv[0]).name
        unsafe_message = "unsafe" in pathlib.Path(sys.argv[0]).name
        failure_message = "민감한 전사 표식 private English transcript Bearer secret-token https://user:pass@example.test/private.wav" if unsafe_message else "MOSS EOS output has no validated segments"
        h = lambda value: hashlib.sha256(value.encode()).hexdigest()
        audio_hash = hashlib.sha256(pathlib.Path(args.audio).read_bytes()).hexdigest()
        entries = [line for line in pathlib.Path(args.glossary).read_text(encoding="utf-8").splitlines() if line] if args.glossary else []
        instruction = h("instruction")
        swift = "Swift synthetic"
        document = {
          "backend":"moss", "model":{"hf_model_id":"aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8", "revision":"90aa65287111a327db98eb83e325bd5332945edd", "quantization":"int8-decoder+fp16-audio-vq-kv"},
          "outcome":"invalid_eos_output" if invalid_eos else "limit", "stop_reason":"endOfSequence" if invalid_eos else "maximumTokens", "terminal_evidence":"observed", "timing_granularity":"segment", "raw_text":"", "segments":[],
          "failure":{"code":"invalid_eos_output","message":failure_message} if invalid_eos else None,
          "language":{"requested":args.language,"instruction_sha256":instruction,"prompt_guidance_applied":args.language != "auto"},
          "glossary":{"provided":bool(entries),"sha256":args.glossary_sha256,"item_count":len(entries),"injection_mode":args.injection_mode if entries else "none","applied":bool(entries),"payload_sha256":instruction if entries else None,"payload_entry_count":len(entries),"instruction_sha256":instruction},
          "coverage":{"input_duration_s":args.end_s-args.start_s,"processed_duration_s":0,"truncated":True},
          "input":{"sha256_before":audio_hash,"sha256_after":audio_hash}, "command":["synthetic-helper","--max-tokens",args.max_tokens,"--language",args.language],
          "backend_raw_artifact":{"path":str(raw),"sha256":hashlib.sha256(raw.read_bytes()).hexdigest()},
          "helper_fingerprint":{"path":"/synthetic/helper.fingerprint.json","sha256":h("sidecar"),"contract_version":"moss-harness-v2","source_tree_sha256":h("source"),"package_swift_sha256":h("package"),"package_resolved_sha256":h("resolved"),"swift_version":swift,"swift_version_sha256":h(swift),"target_architecture":"arm64","configuration":"release","build_flags":["--configuration","release","--arch","arm64","--product","MaccheroniMossHarness"],"executable_sha256":h("binary"),"metallib_sha256":h("metallib")},
          "runner_wall_time_s":0.1, "metrics":{"preprocessing_s":0,"audio_encoder_s":0,"decoder_prefill_s":0,"token_decode_s":0,"total_s":0,"model_load_s":0,"audio_duration_s":args.end_s-args.start_s,"prompt_tokens":1,"generated_tokens":5120,"requested_max_tokens":int(args.max_tokens),"max_tokens":int(args.max_tokens),"context_hard_cap_tokens":131072,"peak_rss_bytes":0}, "metrics_unavailable":{}
        }
        with output.open("x", encoding="utf-8") as stream: json.dump(document, stream)
        sys.exit(2 if invalid_eos else (75 if "nonzero" in pathlib.Path(sys.argv[0]).name else 0))
        """#
        try Data(source.utf8).write(to: runner, options: .withoutOverwriting)
        return (ASRRuntime(
            pythonExecutable: systemPython,
            runnerURL: runner,
            cacheRoot: scratch.appendingPathComponent("cache", isDirectory: true),
            outputRoot: scratch.appendingPathComponent("output", isDirectory: true),
            timeout: 10
        ), scratch)
    }

    private func fakeQwenEvidenceRuntime(
        unavailable: Bool
    ) throws -> (ASRRuntime, URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "maccheroni-asr-fake-qwen-evidence-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        let runner = scratch.appendingPathComponent(
            unavailable ? "qwen-unverified.py" : "qwen-chunk-timing.py"
        )
        let source = #"""
        import argparse, hashlib, json, pathlib, sys
        parser = argparse.ArgumentParser()
        parser.add_argument("operation"); parser.add_argument("--backend")
        parser.add_argument("--audio"); parser.add_argument("--start-s", type=float); parser.add_argument("--end-s", type=float)
        parser.add_argument("--language"); parser.add_argument("--glossary"); parser.add_argument("--glossary-sha256")
        parser.add_argument("--injection-mode"); parser.add_argument("--cache-root"); parser.add_argument("--output")
        parser.add_argument("--timeout-seconds"); parser.add_argument("--max-tokens", type=int)
        args = parser.parse_args()
        output = pathlib.Path(args.output); raw = output.with_suffix(".stdout.txt")
        raw.write_text("Result: synthetic Qwen transcript\n", encoding="utf-8")
        h = lambda value: hashlib.sha256(value.encode()).hexdigest()
        audio_hash = hashlib.sha256(pathlib.Path(args.audio).read_bytes()).hexdigest()
        duration = args.end_s - args.start_s
        unavailable = "unverified" in pathlib.Path(sys.argv[0]).name
        nullable_metrics = {
          "preprocessing_s":None,"audio_encoder_s":None,"decoder_prefill_s":None,"token_decode_s":None,
          "total_s":None,"model_load_s":None,"audio_duration_s":duration,"prompt_tokens":None,
          "generated_tokens":None,"requested_max_tokens":args.max_tokens,"max_tokens":None,
          "context_hard_cap_tokens":None,"peak_rss_bytes":None
        }
        measured_metrics = {
          "preprocessing_s":0.01,"audio_encoder_s":0.02,"decoder_prefill_s":0.03,"token_decode_s":0.04,
          "total_s":0.1,"model_load_s":0.01,"audio_duration_s":duration,"prompt_tokens":2,
          "generated_tokens":3,"requested_max_tokens":args.max_tokens,"max_tokens":args.max_tokens,
          "context_hard_cap_tokens":131072,"peak_rss_bytes":1024
        }
        unavailable_reasons = {key:"speech 0.0.23 does not expose this measurement" for key, value in nullable_metrics.items() if value is None}
        document = {
          "backend":"qwen3", "model":{"hf_model_id":"aufklarer/Qwen3-ASR-1.7B-MLX-8bit", "revision":"e5450a26d1fd417c45fc9c405651ddc3180a27a6", "quantization":"int8"},
          "outcome":"unverified" if unavailable else "complete", "stop_reason":None if unavailable else "endOfSequence",
          "terminal_evidence":"unavailable" if unavailable else "observed", "timing_granularity":"chunk",
          "raw_text":"synthetic Qwen transcript", "segments":[] if unavailable else [{"start_s":args.start_s,"end_s":args.end_s,"text":"synthetic Qwen transcript","speaker":""}],
          "failure":{"code":"evidence_unavailable","message":"Qwen cannot observe a terminal reason or intra-chunk timing"} if unavailable else None,
          "language":{"requested":args.language,"instruction_sha256":h("qwen3-no-context"),"prompt_guidance_applied":False},
          "glossary":{"provided":False,"sha256":None,"item_count":0,"injection_mode":"none","applied":False,"payload_sha256":None,"payload_entry_count":0,"instruction_sha256":h("qwen3-no-context")},
          "coverage":{"input_duration_s":duration,"processed_duration_s":0 if unavailable else duration,"truncated":unavailable},
          "input":{"sha256_before":audio_hash,"sha256_after":audio_hash}, "command":["speech","transcribe"],
          "backend_raw_artifact":{"path":str(raw),"sha256":hashlib.sha256(raw.read_bytes()).hexdigest()},
          "helper_fingerprint":None, "runner_wall_time_s":0.1,
          "metrics":nullable_metrics if unavailable else measured_metrics,
          "metrics_unavailable":unavailable_reasons if unavailable else {}
        }
        with output.open("x", encoding="utf-8") as stream: json.dump(document, stream)
        sys.exit(3 if unavailable else 0)
        """#
        try Data(source.utf8).write(to: runner, options: .withoutOverwriting)
        return (
            ASRRuntime(
                pythonExecutable: systemPython,
                runnerURL: runner,
                cacheRoot: scratch.appendingPathComponent(
                    "cache",
                    isDirectory: true
                ),
                outputRoot: scratch.appendingPathComponent(
                    "output",
                    isDirectory: true
                ),
                timeout: 10
            ),
            scratch
        )
    }

    private func fakeVibeVoiceLimitRuntime(
        stopReason: String = "maximumTokens",
        partialPrefixJSON: String? = nil
    ) throws -> (ASRRuntime, URL) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "maccheroni-asr-fake-vibe-limit-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        let runner = scratch.appendingPathComponent("vibe-limit.py")
        let source = #"""
        import argparse, hashlib, json, pathlib
        parser = argparse.ArgumentParser()
        parser.add_argument("operation"); parser.add_argument("--backend")
        parser.add_argument("--audio"); parser.add_argument("--start-s", type=float); parser.add_argument("--end-s", type=float)
        parser.add_argument("--language"); parser.add_argument("--glossary"); parser.add_argument("--glossary-sha256")
        parser.add_argument("--injection-mode"); parser.add_argument("--cache-root"); parser.add_argument("--output")
        parser.add_argument("--timeout-seconds"); parser.add_argument("--max-tokens", type=int)
        args = parser.parse_args()
        output = pathlib.Path(args.output); raw = output.with_suffix(".backend.json")
        raw.write_text('{"generation_tokens": "cap reached"}\n', encoding="utf-8")
        h = lambda value: hashlib.sha256(value.encode()).hexdigest()
        audio_hash = hashlib.sha256(pathlib.Path(args.audio).read_bytes()).hexdigest()
        duration = args.end_s - args.start_s
        unavailable = {
          "preprocessing_s":"mlx-audio exposes aggregate time only", "audio_encoder_s":"mlx-audio exposes aggregate time only",
          "decoder_prefill_s":"mlx-audio exposes aggregate time only", "token_decode_s":"mlx-audio exposes aggregate time only",
          "model_load_s":"mlx-audio exposes aggregate time only", "context_hard_cap_tokens":"mlx-audio does not expose this cap",
          "peak_rss_bytes":"mlx-audio does not expose peak RSS"
        }
        document = {
          "backend":"vibevoice", "model":{"hf_model_id":"mlx-community/VibeVoice-ASR-8bit", "revision":"725c72e54d6ef875472c27fbc50fab470a960940", "quantization":"int8"},
          "outcome":"limit", "stop_reason":"maximumTokens", "terminal_evidence":"observed", "timing_granularity":"segment",
          "raw_text":"", "segments":[], "failure":None,
          "language":{"requested":args.language,"instruction_sha256":h("vibevoice-no-prompt"),"prompt_guidance_applied":False},
          "glossary":{"provided":False,"sha256":None,"item_count":0,"injection_mode":"none","applied":False,"payload_sha256":None,"payload_entry_count":0,"instruction_sha256":h("vibevoice-no-prompt")},
          "coverage":{"input_duration_s":duration,"processed_duration_s":0,"truncated":True},
          "input":{"sha256_before":audio_hash,"sha256_after":audio_hash}, "command":["mlx_audio.stt.generate"],
          "backend_raw_artifact":{"path":str(raw),"sha256":hashlib.sha256(raw.read_bytes()).hexdigest()},
          "helper_fingerprint":None, "runner_wall_time_s":0.2,
          "metrics":{"preprocessing_s":None,"audio_encoder_s":None,"decoder_prefill_s":None,"token_decode_s":None,"total_s":0.1,"model_load_s":None,"audio_duration_s":duration,"prompt_tokens":4,"generated_tokens":args.max_tokens,"requested_max_tokens":args.max_tokens,"max_tokens":args.max_tokens,"context_hard_cap_tokens":None,"peak_rss_bytes":None},
          "metrics_unavailable":unavailable
        }
        document["stop_reason"] = STOP_REASON
        if PARTIAL_PREFIX is not None:
            document["partial_prefix"] = json.loads(base64.b64decode(PARTIAL_PREFIX))
        with output.open("x", encoding="utf-8") as stream: json.dump(document, stream)
        """#
        // The prefix fixture travels as base64 so no escaping convention has
        // to agree between the Swift literal and the generated Python.
        let encodedPrefix = partialPrefixJSON
            .map { "\"\(Data($0.utf8).base64EncodedString())\"" } ?? "None"
        let prelude = """
        import base64
        STOP_REASON = "\(stopReason)"
        PARTIAL_PREFIX = \(encodedPrefix)

        """
        try Data((prelude + source).utf8).write(
            to: runner,
            options: .withoutOverwriting
        )
        return (
            ASRRuntime(
                pythonExecutable: systemPython,
                runnerURL: runner,
                cacheRoot: scratch.appendingPathComponent(
                    "cache",
                    isDirectory: true
                ),
                outputRoot: scratch.appendingPathComponent(
                    "output",
                    isDirectory: true
                ),
                timeout: 10
            ),
            scratch
        )
    }

    @Test func selectedBackendsExposeTheApprovedPinnedModels() {
        #expect(SelectedASRBackend.koreanDefault == .vibeVoice)
        #expect(SelectedASRBackend.koreanFallback == nil)
        #expect(SelectedASRBackend.italianDefault == .moss)
        #expect(SelectedASRBackend.italianFallback == .vibeVoice)
        #expect(SelectedASRBackend.vibeVoice.model.revision.count == 40)
        #expect(SelectedASRBackend.qwen3.model.hfModelID == "aufklarer/Qwen3-ASR-1.7B-MLX-8bit")
        #expect(SelectedASRBackend.moss.requiredInjectionMode == .hotwordInstruction)
    }

    @Test func localRuntimeUsesTheUserCacheWhenNoOverrideIsSet() {
        let fakeHome = URL(fileURLWithPath: "/tmp/maccheroni-home", isDirectory: true)
        let runtime = ASRRuntime.localRuntime(environment: [:], home: fakeHome)

        #expect(runtime.cacheRoot.path == "/tmp/maccheroni-home/Library/Caches/Maccheroni/benchmarks")
        #expect(runtime.pythonExecutable.path == "/tmp/maccheroni-home/Library/Caches/Maccheroni/benchmarks/venvs/mlx-audio/bin/python")
    }

    @Test func localRuntimeHonorsAnExplicitCacheOverride() {
        let fakeHome = URL(fileURLWithPath: "/tmp/maccheroni-home", isDirectory: true)
        let runtime = ASRRuntime.localRuntime(
            environment: ["MACCHERONI_BENCHMARK_CACHE": "/tmp/maccheroni-cache"],
            home: fakeHome
        )

        #expect(runtime.cacheRoot.path == "/tmp/maccheroni-cache")
        #expect(runtime.pythonExecutable.path == "/tmp/maccheroni-cache/venvs/mlx-audio/bin/python")
    }

    @Test func rejectsWrongGlossaryModeBeforeLaunching() async throws {
        let scratch = try scratchDirectory("wrong-glossary-mode")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let runtime = ASRRuntime(
            pythonExecutable: scratch.appendingPathComponent("missing-python"),
            runnerURL: scratch.appendingPathComponent("missing-runner.py"),
            cacheRoot: scratch.appendingPathComponent("cache"),
            outputRoot: scratch.appendingPathComponent("output"),
            timeout: 1
        )
        let adapter = PinnedASRAdapter(.moss, runtime: runtime)
        let request = ASRRequest(
            audioURL: audio,
            startS: 0,
            endS: 0.1,
            language: .fixed("it"),
            glossary: try syntheticGlossary(),
            injectionMode: .freeTextContext
        )
        await #expect(throws: ASRAdapterError.unsupportedInjectionMode(
            expected: .hotwordInstruction,
            actual: .freeTextContext
        )) {
            _ = try await adapter.transcribeDetailed(request)
        }
    }

    @Test func missingPinnedPythonIsTypedBeforeRunnerLaunch() async throws {
        let scratch = try scratchDirectory("missing-runtime")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let runner = scratch.appendingPathComponent("must-not-run.py")
        try Data("raise SystemExit('runner must not launch')\n".utf8)
            .write(to: runner, options: .withoutOverwriting)
        let missingPython = scratch.appendingPathComponent("missing-python")
        let runtime = ASRRuntime(
            pythonExecutable: missingPython,
            runnerURL: runner,
            cacheRoot: scratch.appendingPathComponent("cache"),
            outputRoot: scratch.appendingPathComponent("output"),
            timeout: 1
        )
        let adapter = PinnedASRAdapter(.vibeVoice, runtime: runtime)

        await #expect(throws: ASRAdapterError.runtimeMissing(
            "pinned Python executable is missing: \(missingPython.path)"
        )) {
            _ = try await adapter.transcribeDetailed(ASRRequest(
                audioURL: audio,
                startS: 0,
                endS: 0.1,
                language: .automatic
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: runtime.outputRoot.path))
    }

    @Test func turnsCoverageShortfallIntoTypedBackendFailure() async throws {
        let scratch = try scratchDirectory("coverage-shortfall")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let runner = scratch.appendingPathComponent("coverage-shortfall.py")
        try Data(#"""
        import json
        import sys
        error = {
          "error": {
            "code": "coverage_shortfall",
            "message": "chunk duration 0.100s does not match request range 3600.000s"
          }
        }
        print(json.dumps(error), file=sys.stderr)
        raise SystemExit(2)
        """#.utf8).write(to: runner, options: .withoutOverwriting)
        let runtime = ASRRuntime(
            pythonExecutable: systemPython,
            runnerURL: runner,
            cacheRoot: scratch.appendingPathComponent("cache"),
            outputRoot: scratch.appendingPathComponent("output"),
            timeout: 5
        )
        let adapter = PinnedASRAdapter(.vibeVoice, runtime: runtime)
        let request = ASRRequest(
            audioURL: audio,
            startS: 0,
            endS: 3_600,
            language: .fixed("it")
        )
        do {
            _ = try await adapter.transcribeDetailed(request)
            Issue.record("expected coverage shortfall")
        } catch let error as ASRAdapterError {
            #expect(error == .backendFailed(
                code: "coverage_shortfall",
                message: "chunk duration 0.100s does not match request range 3600.000s"
            ))
        }
    }

    @Test func mossLanguageOnlyLimitDoesNotClaimGlossaryTransport() async throws {
        let (runtime, scratch) = try fakeLimitRuntime()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let adapter = PinnedASRAdapter(.moss, runtime: runtime)

        let outcome = try await adapter.transcribeAttempt(ASRRequest(
            audioURL: audio,
            startS: 0,
            endS: 0.1,
            language: .fixed("it")
        ))
        guard case let .limit(limit) = outcome else {
            Issue.record("expected typed MOSS limit")
            return
        }

        #expect(!limit.glossary.provided)
        #expect(!limit.glossary.applied)
        #expect(limit.glossaryPayloadEntryCount == 0)
        #expect(limit.glossaryPayloadSHA256 == nil)
        #expect(limit.language.requested == "it")
        #expect(limit.language.promptGuidanceApplied)
    }

    @Test func qwenRefusesUnavailableTerminalAndTimingEvidence() async throws {
        let (runtime, scratch) = try fakeQwenEvidenceRuntime(unavailable: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let adapter = PinnedASRAdapter(.qwen3, runtime: runtime)

        await #expect(throws: ASRAdapterError.evidenceUnavailable(
            "Qwen output cannot be promoted without terminal and intra-chunk timing evidence"
        )) {
            _ = try await adapter.transcribeDetailed(ASRRequest(
                audioURL: audio,
                startS: 0,
                endS: 4.08,
                language: .fixed("ko")
            ))
        }
    }

    @Test func qwenRefusesChunkOnlyTimingEvenWithClaimedEOS() async throws {
        let (runtime, scratch) = try fakeQwenEvidenceRuntime(unavailable: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let adapter = PinnedASRAdapter(.qwen3, runtime: runtime)

        await #expect(throws: ASRAdapterError.evidenceUnavailable(
            "Qwen output has no intra-chunk timestamp evidence"
        )) {
            _ = try await adapter.transcribeDetailed(ASRRequest(
                audioURL: audio,
                startS: 0,
                endS: 4.08,
                language: .fixed("ko")
            ))
        }
    }

    @Test func vibeVoiceTokenCapReturnsTypedLimitWithUnavailableMetrics() async throws {
        let (runtime, scratch) = try fakeVibeVoiceLimitRuntime()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let adapter = PinnedASRAdapter(.vibeVoice, runtime: runtime)
        let request = ASRRequest(
            audioURL: audio,
            startS: 0,
            endS: 4.08,
            language: .fixed("ko")
        )

        let outcome = try await adapter.transcribeAttempt(
            request,
            maximumTokens: 7
        )
        guard case let .limit(limit) = outcome else {
            Issue.record("expected typed VibeVoice token limit")
            return
        }
        #expect(limit.stopReason == .maximumTokens)
        #expect(limit.metrics.maxTokens == 7)
        #expect(limit.metrics.generatedTokens == 7)
        #expect(limit.metrics.contextHardCapTokens == nil)
        #expect(limit.metrics.preprocessingS == nil)
        #expect(limit.metrics.unavailable["preprocessing_s"] != nil)
        #expect(limit.helperFingerprint == nil)
        await #expect(throws: ASRAdapterError.inferenceLimit(.maximumTokens)) {
            _ = try await adapter.transcribeDetailed(request)
        }
    }

    private func vibeVoicePrefixJSON(
        promoted: Int = 2,
        coverageS: Double = 2.5,
        terminalCollapse: Bool = true,
        segments: String = """
        [{"start_s":0.0,"end_s":1.2,"text":"clean opening","speaker":"0"},\
        {"start_s":1.2,"end_s":2.5,"text":"second clean passage","speaker":"0","degenerate":true}]
        """
    ) -> String {
        """
        {"complete_object_count":4,"validated_object_count":4,\
        "promoted_object_count":\(promoted),"degenerate_object_count":1,\
        "coverage_s":\(coverageS),"repetition_run_threshold":12,\
        "repetition_run_maximum":40,"tail_repetition_run":\
        \(terminalCollapse ? 900 : 1),"terminal_collapse":\(terminalCollapse),\
        "raw_text":"[{}]","segments":\(segments)}
        """
    }

    @Test func vibeVoiceCollapseIsTypedApartAndCarriesTheRecoveredPrefix() async throws {
        let (runtime, scratch) = try fakeVibeVoiceLimitRuntime(
            stopReason: "repetitionDegeneration",
            partialPrefixJSON: vibeVoicePrefixJSON()
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let adapter = PinnedASRAdapter(.vibeVoice, runtime: runtime)
        let request = ASRRequest(
            audioURL: audio,
            startS: 0,
            endS: 4.08,
            language: .fixed("ko")
        )

        let outcome = try await adapter.transcribeAttempt(
            request,
            maximumTokens: 7
        )
        guard case let .limit(limit) = outcome else {
            Issue.record("expected a typed VibeVoice degeneration limit")
            return
        }
        #expect(limit.stopReason == .repetitionDegeneration)
        #expect(limit.stopReason.isLimitOutcome)
        let prefix = try #require(limit.partialPrefix)
        #expect(prefix.terminalCollapse)
        #expect(prefix.promotedObjectCount == 2)
        #expect(prefix.completeObjectCount == 4)
        #expect(abs(prefix.coverageS - 2.5) < 0.000_1)
        #expect(prefix.segments.count == 2)
        #expect(prefix.segments.allSatisfy { $0.speaker == "UNASSIGNED" })
        #expect(prefix.segments[0].flags == ["backend_speaker_evidence"])
        #expect(prefix.segments[1].flags == [
            "backend_speaker_evidence", "repetition_degenerate",
        ])
        await #expect(throws: ASRAdapterError.inferenceLimit(.repetitionDegeneration)) {
            _ = try await adapter.transcribeDetailed(request)
        }
    }

    @Test func vibeVoiceDegenerationWithoutRecoveryEvidenceIsRejected() async throws {
        let (runtime, scratch) = try fakeVibeVoiceLimitRuntime(
            stopReason: "repetitionDegeneration"
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let adapter = PinnedASRAdapter(.vibeVoice, runtime: runtime)

        await #expect(throws: ASRAdapterError.malformedOutput(
            "ASR repetition-degeneration outcome carries no recovery evidence"
        )) {
            _ = try await adapter.transcribeAttempt(
                ASRRequest(
                    audioURL: audio,
                    startS: 0,
                    endS: 4.08,
                    language: .fixed("ko")
                ),
                maximumTokens: 7
            )
        }
    }

    @Test func vibeVoicePrefixMustAgreeWithItsOwnSegments() async throws {
        let inconsistent = [
            "coverage": vibeVoicePrefixJSON(coverageS: 3.9),
            "count": vibeVoicePrefixJSON(promoted: 1),
            "collapse": vibeVoicePrefixJSON(terminalCollapse: false),
            "range": vibeVoicePrefixJSON(
                coverageS: 9.5,
                segments: """
                [{"start_s":0.0,"end_s":1.2,"text":"clean","speaker":"0"},\
                {"start_s":1.2,"end_s":9.5,"text":"beyond the chunk","speaker":"0"}]
                """
            ),
        ]
        for (name, prefixJSON) in inconsistent {
            let (runtime, scratch) = try fakeVibeVoiceLimitRuntime(
                stopReason: "repetitionDegeneration",
                partialPrefixJSON: prefixJSON
            )
            defer { try? FileManager.default.removeItem(at: scratch) }
            let audio = try syntheticAudio(in: scratch)
            let adapter = PinnedASRAdapter(.vibeVoice, runtime: runtime)
            var thrown: Error?
            do {
                _ = try await adapter.transcribeAttempt(
                    ASRRequest(
                        audioURL: audio,
                        startS: 0,
                        endS: 4.08,
                        language: .fixed("ko")
                    ),
                    maximumTokens: 7
                )
            } catch {
                thrown = error
            }
            #expect(thrown is ASRAdapterError, "case \(name) was accepted")
        }
    }

    @Test func timeoutKillsAChildAndRemovesCaptureFiles() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccheroni-asr-timeout-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let runner = scratch.appendingPathComponent("ignores-term.py")
        try Data("""
        import signal
        import time
        signal.signal(signal.SIGTERM, lambda _signal, _frame: None)
        time.sleep(60)
        """.utf8)
            .write(to: runner, options: .withoutOverwriting)
        let audio = try syntheticAudio(in: scratch)
        let capturePrefix = "maccheroni-asr-stdout-"
        let capturesBefore = Set(try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        ).filter { $0.hasPrefix(capturePrefix) })
        let runtime = ASRRuntime(
            pythonExecutable: systemPython,
            runnerURL: runner,
            cacheRoot: scratch.appendingPathComponent("cache"),
            outputRoot: scratch.appendingPathComponent("output", isDirectory: true),
            timeout: 0.05
        )
        let adapter = PinnedASRAdapter(.vibeVoice, runtime: runtime)
        await #expect(throws: ASRAdapterError.timedOut(0.05)) {
            _ = try await adapter.transcribeDetailed(ASRRequest(
                audioURL: audio,
                startS: 0,
                endS: 0.1,
                language: .fixed("it")
            ))
        }
        let capturesAfter = Set(try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        ).filter { $0.hasPrefix(capturePrefix) })
        #expect(capturesAfter == capturesBefore)
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: scratch.appendingPathComponent("output").path
        ).isEmpty)
    }

    @Test func typedMossLimitPreservesEvidenceWithoutPromotingPartialText() async throws {
        let (runtime, scratch) = try fakeLimitRuntime()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let adapter = PinnedASRAdapter(.moss, runtime: runtime)
        let terms = try syntheticGlossary()
        let request = ASRRequest(audioURL: audio, startS: 0, endS: 0.1, language: .fixed("it"), glossary: terms, injectionMode: .hotwordInstruction)
        let outcome = try await adapter.transcribeAttempt(request)
        guard case let .limit(limit) = outcome else { Issue.record("expected typed limit"); return }
        #expect(limit.stopReason == .maximumTokens)
        #expect(limit.glossaryPayloadEntryCount == terms.entries.count)
        #expect(limit.glossaryPayloadSHA256?.count == 64)
        #expect(limit.language.requested == "it")
        #expect(limit.command.contains("--max-tokens"))
        #expect(limit.command.contains("5120"))
        #expect(limit.command.contains("--language"))
        #expect(FileManager.default.fileExists(atPath: limit.outputURL.path))
        #expect(FileManager.default.fileExists(atPath: limit.backendRawArtifactURL.path))
        await #expect(throws: ASRAdapterError.inferenceLimit(.maximumTokens)) {
            _ = try await adapter.transcribeDetailed(request)
        }
    }

    @Test func nonzeroPythonRunnerNeverLeaksALimitAsSuccess() async throws {
        let (runtime, scratch) = try fakeLimitRuntime(nonzeroExit: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let adapter = PinnedASRAdapter(.moss, runtime: runtime)
        await #expect(throws: ASRAdapterError.backendFailed(code: "subprocess_exit_75", message: "diagnostic unavailable")) {
            _ = try await adapter.transcribeAttempt(ASRRequest(audioURL: audio, startS: 0, endS: 0.1, language: .fixed("it")))
        }
    }

    @Test func doctorKeepsOnlyTheFinalStructuredDiagnostic() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "maccheroni-asr-doctor-diagnostic-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let runner = scratch.appendingPathComponent("doctor.py")
        try Data(#"""
        import json
        import sys
        sys.stderr.write("\033[31m민감한 전사 표식 private English transcript Bearer secret https://user:pass@example.test /Users/private/audio.wav\033[0m\n")
        print(json.dumps({"error": {"code": "runtime_missing", "message": "민감한 전사 표식 private English transcript Bearer secret https://user:pass@example.test/private.wav"}}), file=sys.stderr)
        raise SystemExit(9)
        """#.utf8).write(to: runner, options: .withoutOverwriting)
        let runtime = ASRRuntime(
            pythonExecutable: systemPython,
            runnerURL: runner,
            cacheRoot: scratch,
            outputRoot: scratch.appendingPathComponent("outputs"),
            timeout: 5
        )

        await #expect(throws: ASRAdapterError.backendFailed(
            code: "runtime_missing",
            message: "diagnostic unavailable"
        )) {
            _ = try await ASRDoctor.diagnose(.vibeVoice, runtime: runtime)
        }
    }

    @Test func invalidEOSRecordDoesNotPromoteUntrustedHelperMessage() async throws {
        let (runtime, scratch) = try fakeLimitRuntime(
            invalidEOSOutput: true,
            unsafeInvalidEOSMessage: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let adapter = PinnedASRAdapter(.moss, runtime: runtime)
        let terms = try syntheticGlossary()
        let request = ASRRequest(
            audioURL: audio,
            startS: 0,
            endS: 0.1,
            language: .fixed("it"),
            glossary: terms,
            injectionMode: .hotwordInstruction
        )

        await #expect(throws: ASRAdapterError.invalidEOSOutput(
            "diagnostic unavailable"
        )) {
            _ = try await adapter.transcribeAttempt(request)
        }

        let output = scratch.appendingPathComponent("output")
        let record = try #require(FileManager.default.contentsOfDirectory(
            at: output,
            includingPropertiesForKeys: nil
        ).first { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let document = try? JSONSerialization.jsonObject(
                    with: data
                  ) as? [String: Any]
            else { return false }
            return document["outcome"] as? String == "invalid_eos_output"
        })
        let protectedData = try Data(contentsOf: record)
        let protectedRecord = try #require(
            JSONSerialization.jsonObject(with: protectedData) as? [String: Any]
        )
        let failure = try #require(protectedRecord["failure"] as? [String: Any])
        let message = try #require(failure["message"] as? String)
        #expect(message.contains("민감한 전사 표식"))
        #expect(message.contains("Bearer secret-token"))
        #expect(message.contains("https://user:pass@example.test"))
    }

    @Test func invalidEOSOutputIsTypedAndKeepsOnlyTheProtectedRecord() async throws {
        let (runtime, scratch) = try fakeLimitRuntime(invalidEOSOutput: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = try syntheticAudio(in: scratch)
        let adapter = PinnedASRAdapter(.moss, runtime: runtime)
        let terms = try syntheticGlossary()
        let request = ASRRequest(
            audioURL: audio,
            startS: 0,
            endS: 0.1,
            language: .fixed("it"),
            glossary: terms,
            injectionMode: .hotwordInstruction
        )
        await #expect(throws: ASRAdapterError.invalidEOSOutput(
            "MOSS EOS output has no validated segments"
        )) {
            _ = try await adapter.transcribeAttempt(request)
        }
        let output = scratch.appendingPathComponent("output")
        let records = try FileManager.default.contentsOfDirectory(
            at: output,
            includingPropertiesForKeys: nil
        ).filter { url in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let document = try? JSONSerialization.jsonObject(
                    with: data
                  ) as? [String: Any]
            else { return false }
            return document["outcome"] as? String == "invalid_eos_output"
        }
        #expect(records.count == 1)
        guard let protectedRecord = records.first else {
            Issue.record("expected one protected runner record")
            return
        }
        let record = try String(contentsOf: protectedRecord, encoding: .utf8)
        #expect(record.contains("\"outcome\": \"invalid_eos_output\""))
        #expect(record.contains("\"code\": \"invalid_eos_output\""))
        #expect(record.contains("\"raw_text\": \"\""))
        #expect(record.contains("\"segments\": []"))
    }
}
