// P6: render every app screen offscreen and read the images back (D48).
//
// These tests write PNGs; they are not assertions about pixels. They are the
// instrument D48 asks for, kept in the repository so the next person who
// changes a screen can look at it instead of guessing. Every test is skipped
// unless `P6_RENDER` is set, and every test that needs the private 2026-09-01
// recording is skipped when that directory is absent, so a fresh clone reports
// this file as skipped rather than as passing tests that asserted nothing.
//
// Two rendering paths, because they see different things:
//
//   * `ImageRenderer` — SwiftUI's own rasteriser. Needs no window server, and
//     is what D48 recorded. It returns *nothing* for content inside a
//     `ScrollView`, `List` or grouped `Form`, and draws `TextField`, `Slider`
//     and AppKit-backed button styles as placeholders.
//   * `NSHostingView` laid out offscreen and drawn with `cacheDisplay(in:to:)`.
//     Also needs no window server and no Screen Recording permission, and it
//     *does* draw `ScrollView`, grouped `Form`, `TextField` and `Slider`
//     correctly. `List` is still blank (it is `NSTableView`-backed and needs a
//     real window), and so are menus and sheets.
//
// The second path is what lets a whole screen be rendered as the app composes
// it, rather than as a harness re-composes its parts.
import AppKit
import Foundation
import MaccheroniCore
import MaccheroniMerge
import MaccheroniPostprocess
import SwiftUI
import Testing
import Vision
@testable import MaccheroniApp

@Suite(.serialized)
struct ScreenSnapshotTests {
    // MARK: - Where things are

    static let home = NSHomeDirectory()
    static let usage = URL(fileURLWithPath: "\(home)/maccheroni-usage-20260901", isDirectory: true)
    /// `screens/<tag>`, so a later pass writes its own images beside the ones
    /// it is being compared against rather than over them. `P6_OUT` names a
    /// directory to write to instead, for a pass that must keep its images
    /// outside the usage directory.
    static var outRoot: URL {
        if let out = ProcessInfo.processInfo.environment["P6_OUT"], !out.isEmpty {
            return URL(fileURLWithPath: out, isDirectory: true)
        }
        return usage.appendingPathComponent("screens/\(tag)", isDirectory: true)
    }
    /// The real 20.7-minute run, `status: partial`, 248 merged segments.
    static let realRunURL = usage.appendingPathComponent(
        "t4-verify/full-acceptance/20260901T122702Z-f2d938", isDirectory: true
    )
    /// A copy of the same run carrying P4b's D50 speaker-proposal derived set.
    static let proposalRunURL = usage.appendingPathComponent(
        "p4-speaker-proposal/20260901T122702Z-f2d938", isDirectory: true
    )
    /// Preserved failures.
    static let runErrorURL = usage.appendingPathComponent(
        "runs/20260831T182603Z-8fc7c0", isDirectory: true
    )
    static let diarizationErrorURL = usage.appendingPathComponent(
        "ablation/ko-420-late/20260901T103155Z-ae7e94", isDirectory: true
    )

    static var enabled: Bool { ProcessInfo.processInfo.environment["P6_RENDER"] != nil }
    static var tag: String { ProcessInfo.processInfo.environment["P6_TAG"] ?? "p6" }

    /// Skipped, not passed. Without `P6_RENDER` these tests used to return
    /// early and count as green on a fresh clone while asserting nothing;
    /// as traits, `swift test` reports them as skipped and says why.
    static var whenRendering: ConditionTrait {
        .enabled(if: enabled, "P6_RENDER is not set")
    }

    /// The same, for a test that renders the private 2026-09-01 recording.
    static var whenRenderingTheRealRun: ConditionTrait {
        .enabled(
            if: enabled && exists(proposalRunURL),
            "P6_RENDER is not set or the private 2026-09-01 run is absent"
        )
    }
    static let english = Locale(identifier: "en")

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Narrow and wide, as the acceptance asks. 820 is the width the previous
    /// passes measured; 1400 is a wide window.
    static let widths: [(String, CGFloat)] = [("narrow", 820), ("wide", 1400)]
    static let schemes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]

    // MARK: - Rendering

    enum RenderError: Error { case noImage(String) }

    /// Lay a SwiftUI view out inside an `NSHostingView` and draw it into a
    /// bitmap. No window server, no Screen Recording permission.
    @MainActor
    @discardableResult
    static func host(
        _ view: some View,
        width: CGFloat,
        height: CGFloat,
        scheme: ColorScheme,
        name: String,
        subdirectory: String = "",
        drawAt: CGFloat? = nil
    ) throws -> CGSize {
        let directory = subdirectory.isEmpty
            ? outRoot
            : outRoot.appendingPathComponent(subdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        // The frame has to be imposed inside SwiftUI, not only on the AppKit
        // view: `NSHostingView` lays its root out at the root's own ideal size
        // and centres the overflow, which silently cut the header off the top
        // of every screen taller than its window.
        let root = AnyView(
            view
                .environment(\.locale, english)
                .environment(\.colorScheme, scheme)
                .frame(width: width, height: height, alignment: .top)
                .clipped()
                .background(Color(nsColor: .windowBackgroundColor))
        )
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = appearance
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        // `.navigationTitle` wraps a screen in a `SystemSplitView` whose
        // AppKit host is *not* flipped, so a subtree taller than the frame is
        // laid out from the bottom and the top of the screen — the header —
        // falls outside the drawn rect. Give the view its natural height and
        // crop the window back afterwards.
        let natural = drawAt ?? hosting.fittingSize.height
        let drawnHeight = min(max(height, natural.isFinite ? natural : height), 12_000)
        if drawnHeight > height {
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: drawnHeight)
            hosting.layoutSubtreeIfNeeded()
        }
        // Let SwiftUI settle: `.task` bodies, `ViewThatFits` measurement and
        // AppKit control layout all land on later run-loop turns.
        for _ in 0 ..< 12 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            hosting.layoutSubtreeIfNeeded()
        }
        // A `LazyVStack` of 248 rows inside a `ScrollView` settles at a
        // non-zero offset offscreen: rows materialise with their real heights
        // after the estimate, and the clip view keeps the old offset. Put it
        // back at the top so the render shows the screen as it opens, then let
        // it settle again.
        scrollToTop(hosting)
        for _ in 0 ..< 6 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            hosting.layoutSubtreeIfNeeded()
        }
        scrollToTop(hosting)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw RenderError.noImage(name)
        }
        rep.size = hosting.bounds.size
        let saved = NSAppearance.currentDrawing()
        appearance?.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }
        saved.performAsCurrentDrawingAppearance {}
        // `bitmapImageRepForCachingDisplay` hands back a rep in the display's
        // own space — `sips` reports "Generic RGB Profile", gamma 1.8 — so a
        // token's sRGB hex is never reproduced byte for byte and every
        // contrast measurement taken off the raw pixels is wrong. Convert
        // before writing, so what the report measures is sRGB.
        let sRGB = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
        guard var image = sRGB.cgImage else { throw RenderError.noImage(name) }
        if drawnHeight > height {
            let scale = CGFloat(image.height) / drawnHeight
            let window = CGRect(
                x: 0, y: 0,
                width: CGFloat(image.width),
                height: (height * scale).rounded()
            )
            guard let cropped = image.cropping(to: window) else {
                throw RenderError.noImage(name)
            }
            image = cropped
        }
        guard let data = NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:])
        else { throw RenderError.noImage(name) }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        return CGSize(width: image.width, height: image.height)
    }


    /// Every `NSScrollView` under this view, back to the top of its content.
    @MainActor
    static func scrollToTop(_ view: NSView) {
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            let top = document.isFlipped
                ? NSPoint.zero
                : NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: top)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        for child in view.subviews { scrollToTop(child) }
    }

    /// SwiftUI's own rasteriser, kept so the two paths can be compared on the
    /// same view and the difference reported rather than assumed.
    @MainActor
    @discardableResult
    static func imageRenderer(
        _ view: some View,
        width: CGFloat,
        height: CGFloat?,
        scheme: ColorScheme,
        name: String,
        subdirectory: String = ""
    ) throws -> CGSize {
        let directory = subdirectory.isEmpty
            ? outRoot
            : outRoot.appendingPathComponent(subdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = view
            .frame(width: width)
            .frame(height: height, alignment: .top)
            .clipped()
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
            .environment(\.locale, english)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw RenderError.noImage(name) }
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        return CGSize(width: image.width, height: image.height)
    }

    // MARK: - Fixtures

    struct RealRun {
        var run: LoadedRun
        var record: LibraryRecord
    }

    @MainActor
    static func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniScreenSnapshots-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Read the real run through the shipped repository, so what is rendered
    /// is what the app would load rather than what a harness assembled.
    @MainActor
    static func realRun(at runURL: URL, name: String, state: LibraryItemState) throws -> RealRun {
        let repository = LibraryRepository(root: try temporaryRoot())
        let run = try repository.loadRun(at: runURL)
        let record = record(
            named: name,
            runURL: runURL,
            durationS: run.manifest.coverage.inputDurationS,
            state: state
        )
        return RealRun(run: run, record: record)
    }

    static func record(
        named name: String,
        runURL: URL?,
        durationS: Double,
        state: LibraryItemState,
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000f2")!,
        postprocess: PostprocessChoice = .none,
        failureMessage: String? = nil,
        speakerNames: [String: String] = ["0": "Jina"]
    ) -> LibraryRecord {
        LibraryRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_788_000_000),
            displayName: name,
            sourceKind: .importedFile,
            sourceURL: URL(fileURLWithPath: "/tmp/meeting.wav"),
            securityScopedBookmark: nil,
            microphoneURL: nil,
            systemAudioURL: nil,
            runURL: runURL,
            profileID: .koreanITMeeting,
            postprocess: postprocess,
            durationS: durationS,
            state: state,
            speakerNames: speakerNames,
            conflictResolutions: [:],
            failureMessage: failureMessage
        )
    }

    // MARK: - Reading an image back

    /// Every line of text Vision recognises in the image, top to bottom and
    /// left to right, so an assertion can say what the screen printed rather
    /// than what the view model held.
    static func recognisedText(in url: URL) throws -> [String] {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw RenderError.noImage(url.lastPathComponent) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let sorted = (request.results ?? []).sorted { left, right in
            if abs(left.boundingBox.midY - right.boundingBox.midY) > 0.006 {
                return left.boundingBox.midY > right.boundingBox.midY
            }
            return left.boundingBox.minX < right.boundingBox.minX
        }
        return sorted.compactMap { $0.topCandidates(1).first?.string }
    }

    /// Letters and digits only, lowercased, so a comparison survives the
    /// hyphens, commas and spacing OCR is loose about.
    static func compact(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The horizontal extent, in pixels, of the longest run of accent-coloured
    /// pixels in the top half of the image: the 2-point underline beneath the
    /// displayed layer tab. The playhead knob is accent too, but round and a
    /// dozen pixels wide, so a run has to be at least `minimumRun` long to
    /// count. `nil` when no such run exists.
    static func accentUnderline(
        in url: URL,
        hex: String,
        tolerance: Int = 28,
        minimumRun: Int = 60
    ) throws -> ClosedRange<Int>? {
        guard let rep = NSBitmapImageRep(data: try Data(contentsOf: url)),
              rep.bitsPerSample == 8,
              let data = rep.bitmapData
        else { throw RenderError.noImage(url.lastPathComponent) }
        let digits = hex.dropFirst()
        let target = (0 ..< 3).map { index -> Int in
            let start = digits.index(digits.startIndex, offsetBy: index * 2)
            return Int(digits[start ..< digits.index(start, offsetBy: 2)], radix: 16) ?? 0
        }
        let samples = rep.samplesPerPixel
        let bytesPerRow = rep.bytesPerRow
        let channel = rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        func isAccent(_ x: Int, _ y: Int) -> Bool {
            let pixel = data + y * bytesPerRow + x * samples
            return (0 ..< 3).allSatisfy { abs(Int(pixel[channel + $0]) - target[$0]) <= tolerance }
        }
        var best: ClosedRange<Int>?
        for y in 0 ..< rep.pixelsHigh / 2 {
            var start: Int?
            for x in 0 ... rep.pixelsWide {
                if x < rep.pixelsWide, isAccent(x, y) {
                    if start == nil { start = x }
                } else if let runStart = start {
                    let run = runStart ... (x - 1)
                    if run.count >= minimumRun, run.count > (best?.count ?? 0) { best = run }
                    start = nil
                }
            }
        }
        return best
    }

    @MainActor
    static func model(
        probe: SnapshotReadinessProbe? = nil,
        permissions: CapturePermissions = CapturePermissions(microphone: .granted, systemAudio: .granted)
    ) throws -> MaccheroniAppModel {
        let suite = "MaccheroniScreenSnapshots-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return try MaccheroniAppModel(
            repository: LibraryRepository(root: try temporaryRoot()),
            profiles: try AppProfileRegistry.load(),
            runner: SnapshotRunner(),
            recorder: SnapshotRecorder(),
            defaults: defaults,
            readinessProbe: probe ?? SnapshotReadinessProbe(outcome: .report(Self.readyReport())),
            capturePermissions: { permissions },
            readinessWaitBudget: .seconds(5)
        )
    }

    static func readyReport() -> ProfileReadinessReport {
        ProfileReadinessReport(
            ready: true,
            schemaVersion: "1.1.0",
            values: [
                "profile": "ko-it-meeting",
                "check.asr.model_files": "true",
                "check.asr.mlx_audio": "true",
                "check.asr_runner": "true",
                "check.asr_python_3_12": "true",
                "check.diarization_model_cache": "true",
                "check.diarization_revision": "true",
                "check.vad_model_cache": "true",
                "check.offline_speech_runtime": "true",
                "check.postprocess": "true",
                "check.storage": "true",
            ]
        )
    }

    static func unprovisionedReport() -> ProfileReadinessReport {
        ProfileReadinessReport(
            ready: false,
            schemaVersion: "1.1.0",
            values: [
                "profile": "ko-it-meeting",
                "check.asr.model_files": "false",
                "check.asr.mlx_audio": "false",
                "check.asr_runner": "false",
                "check.asr_python_3_12": "false",
                "check.diarization_model_cache": "false",
                "check.diarization_revision": "false",
                "check.vad_model_cache": "false",
                "check.offline_speech_runtime": "false",
                "check.postprocess": "true",
                "check.storage": "true",
            ]
        )
    }

    @MainActor
    static func settleReadiness(_ model: MaccheroniAppModel) async {
        model.evaluateProfileReadiness()
        for _ in 0 ..< 800 {
            if model.profileReadiness.hasResult, !model.profileReadiness.isEvaluating { return }
            await Task.yield()
        }
    }

    // MARK: - Screens: capture readiness

    @Test(ScreenSnapshotTests.whenRendering) @MainActor
    func captureReadiness() async throws {
        for (label, report) in [
            ("notready", Self.unprovisionedReport()),
            ("ready", Self.readyReport()),
        ] {
            let model = try Self.model(probe: SnapshotReadinessProbe(outcome: .report(report)))
            await Self.settleReadiness(model)
            for (widthLabel, width) in Self.widths {
                for (schemeLabel, scheme) in Self.schemes {
                    let size = try Self.host(
                        CaptureView(model: model, chooseFile: {}),
                        width: width, height: 1_000, scheme: scheme,
                        name: "\(Self.tag)-capture-\(label)-\(widthLabel)-\(schemeLabel)"
                    )
                    print("capture \(label) \(widthLabel) \(schemeLabel) \(size)")
                }
            }
        }
    }

    // MARK: - Screens: run failure

    @Test(ScreenSnapshotTests.whenRendering) @MainActor
    func runFailureScreens() throws {
        let cases: [(String, URL, LibraryItemState, Double)] = [
            ("runerror", Self.runErrorURL, .failed, 1_243.08),
            ("diarizationerror", Self.diarizationErrorURL, .failed, 420.048),
            ("partial", Self.realRunURL, .failed, 1_243.08),
        ]
        for (label, url, state, duration) in cases {
            guard Self.exists(url) else {
                print("SKIP failure \(label): \(url.path) absent")
                continue
            }
            let model = try Self.model()
            let record = Self.record(
                named: label == "diarizationerror" ? "Late clip" : "Weekly product sync",
                runURL: url,
                durationS: duration,
                state: state,
                failureMessage: nil
            )
            for (widthLabel, width) in Self.widths {
                for (schemeLabel, scheme) in Self.schemes {
                    let size = try Self.host(
                        RunProgressView(model: model, record: record),
                        width: width, height: 1_000, scheme: scheme,
                        name: "\(Self.tag)-failure-\(label)-\(widthLabel)-\(schemeLabel)"
                    )
                    print("failure \(label) \(widthLabel) \(schemeLabel) \(size)")
                }
            }
        }
    }

    // MARK: - Screens: transcript

    @Test(ScreenSnapshotTests.whenRenderingTheRealRun) @MainActor
    func transcriptScreen() throws {
        // The P1-merged copy. `t4-verify/full-acceptance` was merged on
        // 2026-09-01, before P1, so its `conflicts.json` carries no
        // `speaker_attribution` at all; that run is rendered separately below
        // as the pre-P1 case rather than used as the design's subject.
        let real = try Self.realRun(
            at: Self.proposalRunURL, name: "Weekly product sync", state: .hasConflicts
        )
        let focus = real.run.segments.first {
            !SpeakerRoster.isAttributed($0.segment.speaker) && $0.index > 2
        }?.index
        for (widthLabel, width) in Self.widths {
            for (schemeLabel, scheme) in Self.schemes {
                let size = try Self.host(
                    Self.composedTranscript(
                        real: real, proposal: nil, layer: .speakerLabelled, width: width,
                        focused: nil, selected: []
                    ),
                    width: width, height: 1_000, scheme: scheme,
                    name: "\(Self.tag)-transcript-\(widthLabel)-\(schemeLabel)"
                )
                print("transcript \(widthLabel) \(schemeLabel) \(size)")
            }
        }
        // A focused row and a checked selection box, which are otherwise never
        // on screen: the focused row prints the reason sentence and carries the
        // accent rule and accent time.
        for (schemeLabel, scheme) in Self.schemes {
            try Self.host(
                Self.composedTranscript(
                    real: real, proposal: nil, layer: .speakerLabelled, width: 1_400,
                    focused: focus, selected: [3]
                ),
                width: 1_400, height: 1_000, scheme: scheme,
                name: "\(Self.tag)-transcript-focused-\(schemeLabel)"
            )
        }
        // A long page so the rhythm of 60 real rows can be read at once.
        try Self.host(
            Self.composedTranscript(
                real: real, proposal: nil, layer: .speakerLabelled, width: 1_400,
                focused: focus, selected: [], rows: 60
            ),
            width: 1_400, height: 3_600, scheme: .light,
            name: "\(Self.tag)-transcript-page-light"
        )
        // The shipped `TranscriptView` itself, for the record. Its own
        // `ScrollView` settles at a non-zero offset offscreen and its
        // `.navigationTitle` wrapper lays the screen out taller than the frame,
        // so this image starts part-way down the list and has no header. It is
        // kept because it is the only render of the real composition, and its
        // limitation is stated in the report rather than hidden.
        let model = try Self.model()
        for (schemeLabel, scheme) in Self.schemes {
            try Self.host(
                TranscriptView(model: model, record: real.record, run: real.run),
                width: 1_400, height: 1_000, scheme: scheme,
                name: "\(Self.tag)-transcript-shipped-\(schemeLabel)"
            )
        }
        // The same recording merged before P1: every acoustic figure is absent
        // from the run's own records. What the screen does with that is worth
        // seeing, because every run written before 2026-09-02 is this run.
        if Self.exists(Self.realRunURL) {
            let preP1 = try Self.realRun(
                at: Self.realRunURL, name: "Weekly product sync", state: .hasConflicts
            )
            try Self.host(
                Self.composedTranscript(
                    real: preP1, proposal: nil, layer: .speakerLabelled, width: 1_400,
                    focused: nil, selected: []
                ),
                width: 1_400, height: 1_000, scheme: .light,
                name: "\(Self.tag)-transcript-prep1-light"
            )
        }
    }

    /// The proposal layer. `TranscriptView` chooses its layer in private
    /// `@State` and never opens on `.proposed` by construction (D46), so the
    /// screen is composed here from the same shipped views the real screen
    /// uses: `TranscriptHeaderBar`, `ProposalLayerNotice`, `AppHairline` and
    /// `TranscriptSegmentColumn`.
    @Test(ScreenSnapshotTests.whenRenderingTheRealRun) @MainActor
    func proposalLayerScreen() throws {
        let real = try Self.realRun(
            at: Self.proposalRunURL, name: "Weekly product sync", state: .hasConflicts
        )
        guard let document = real.run.speakerProposal else {
            print("SKIP proposal: run carries no speaker proposal")
            return
        }
        for (widthLabel, width) in Self.widths {
            for (schemeLabel, scheme) in Self.schemes {
                let size = try Self.host(
                    Self.composedTranscript(
                        real: real, proposal: document, layer: .proposed, width: width,
                        focused: nil, selected: []
                    ),
                    width: width, height: 1_000, scheme: scheme,
                    name: "\(Self.tag)-proposal-\(widthLabel)-\(schemeLabel)"
                )
                print("proposal \(widthLabel) \(schemeLabel) \(size)")
            }
        }
        // A focused unnamed row so the reason sentence and the decline
        // sentences are on screen, and a long page so the rhythm is readable.
        let focus = real.run.segments.first {
            !SpeakerRoster.isAttributed($0.segment.speaker) && $0.index > 2
        }?.index
        for (schemeLabel, scheme) in Self.schemes {
            try Self.host(
                Self.composedTranscript(
                    real: real, proposal: document, layer: .proposed, width: 1_400,
                    focused: focus, selected: [3]
                ),
                width: 1_400, height: 1_000, scheme: scheme,
                name: "\(Self.tag)-proposal-focused-\(schemeLabel)"
            )
        }
        try Self.host(
            Self.composedTranscript(
                real: real, proposal: document, layer: .proposed, width: 1_400,
                focused: focus, selected: [], rows: 60
            ),
            width: 1_400, height: 3_600, scheme: .light,
            name: "\(Self.tag)-proposal-page-light"
        )
    }

    @MainActor
    static func composedTranscript(
        real: RealRun,
        proposal: SpeakerProposalDocument?,
        layer: TranscriptDisplayLayer,
        width: CGFloat,
        focused: Int?,
        selected: Set<Int>,
        rows: Int = 40,
        firstRow: Int = 0
    ) -> some View {
        let run = real.run
        let record = real.record
        let roster = SpeakerRoster(segments: run.transcript.segments)
        let proposalLayer = proposal.map(TranscriptProposalLayer.init(document:))
        let options = TranscriptLayerCatalog.options(run: run, record: record, proposal: proposal)
        func name(_ raw: String) -> String {
            if let n = record.speakerNames[raw], !n.isEmpty { return n }
            return SpeakerRoster.fallbackName(for: raw, locale: english)
        }
        func needsReview(_ item: TranscriptSegment) -> Bool {
            item.conflict != nil || TranscriptFlagVocabulary.marksUncertainty(item.segment.flags ?? [])
        }
        let queue = run.segments.filter(needsReview).map(\.index)
        // The same predicate `TranscriptView.missingEvidence` uses, so the header
        // sentence appears here exactly when it appears in the app.
        let unnamed = run.segments.filter { !SpeakerRoster.isAttributed($0.segment.speaker) }
        let gapLayer = layer == .proposed ? proposalLayer : nil
        let missingEvidence: TranscriptMissingEvidence? = unnamed.isEmpty
            ? nil
            : (
                run.isTranslation
                    ? .notLoadedWithTranslation
                    : (
                        unnamed.contains {
                            $0.conflict?.speakerAttribution == nil
                                && gapLayer?.inlineEvidence(at: $0.index) == nil
                        } ? .someSegmentsHaveNoRecord : nil
                    )
            )
        let unattributed = run.transcript.segments.count { !SpeakerRoster.isAttributed($0.speaker) }
        let summary = "\(run.transcript.segments.count) segments · \(run.transcript.numSpeakers) speakers · \(unattributed) without a speaker · \(queue.count) to review"
        let playback = TranscriptPlaybackController()
        let missingCoverage = TranscriptMissingCoverage.load(run: run, record: record)
        let visible = Array(run.segments.dropFirst(firstRow).prefix(rows))
        let selectedIDs = Set(visible.filter { selected.contains($0.index) }.map(\.id))
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
                TranscriptHeaderBar(
                    title: record.displayName,
                    summary: summary,
                    layerOptions: options,
                    selectedLayer: layer,
                    selectLayer: { _ in },
                    searchText: .constant(""),
                    matchCount: nil,
                    reviewQueue: queue,
                    focusedSegmentIndex: focused,
                    step: { _ in },
                    missingEvidence: missingEvidence,
                    missingCoverage: missingCoverage,
                    playback: playback,
                    totalDurationS: run.manifest.coverage.inputDurationS,
                    togglePlayback: {},
                    seek: { _ in }
                )
                if layer == .proposed, let proposalLayer {
                    ProposalLayerNotice(layer: proposalLayer, showsCoverage: missingCoverage == nil)
                }
            }
            .frame(maxWidth: AppTheme.Layout.measure, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.screen)
            .padding(.top, AppTheme.Spacing.large)
            .padding(.bottom, AppTheme.Spacing.medium)
            .frame(maxWidth: .infinity)
            AppHairline()
            TranscriptSegmentColumn(
                segments: visible,
                roster: roster,
                displayName: name,
                text: { $0.segment.text },
                needsReview: needsReview,
                isReviewable: needsReview,
                focusedSegmentIndex: focused,
                playingSegmentIndex: nil,
                selectedSegmentIDs: selectedIDs,
                evidenceIsLoaded: true,
                proposalLayer: layer == .proposed ? proposalLayer : nil,
                gaps: missingCoverage?.gaps.filter { gap in
                    visible.contains { $0.segment.startS >= gap.startS }
                } ?? [],
                play: { _ in },
                select: { _ in },
                rename: { _ in },
                review: { _ in }
            )
            Spacer(minLength: 0)
        }
    }

    /// One row of each D50 decline cause, plus a confirmation, so the three
    /// sentences a reader has to tell apart are on screen together.
    @Test(ScreenSnapshotTests.whenRenderingTheRealRun) @MainActor
    func proposalDeclineCauses() throws {
        let real = try Self.realRun(
            at: Self.proposalRunURL, name: "Weekly product sync", state: .hasConflicts
        )
        guard let document = real.run.speakerProposal else { return }
        // 4: the model declined. 38: the top candidates hold exactly equal
        // overlap. 25: no overlapping turn at all. 3: a confirmation.
        let wanted = [3, 4, 38, 25]
        for (widthLabel, width) in Self.widths {
            for (schemeLabel, scheme) in Self.schemes {
                try Self.host(
                    Self.composedRows(real: real, proposal: document, indices: wanted, focused: nil),
                    width: width, height: 520, scheme: scheme,
                    name: "\(Self.tag)-proposal-causes-\(widthLabel)-\(schemeLabel)"
                )
            }
        }
        // The same four with the tie focused, so its sentence competes with
        // the focused row's acoustic reason.
        for (schemeLabel, scheme) in Self.schemes {
            try Self.host(
                Self.composedRows(real: real, proposal: document, indices: wanted, focused: 38),
                width: 1_400, height: 560, scheme: scheme,
                name: "\(Self.tag)-proposal-causes-focused-\(schemeLabel)"
            )
        }
    }

    @MainActor
    static func composedRows(
        real: RealRun,
        proposal: SpeakerProposalDocument?,
        indices: [Int],
        focused: Int?
    ) -> some View {
        let run = real.run
        let record = real.record
        let roster = SpeakerRoster(segments: run.transcript.segments)
        let proposalLayer = proposal.map(TranscriptProposalLayer.init(document:))
        func name(_ raw: String) -> String {
            if let n = record.speakerNames[raw], !n.isEmpty { return n }
            return SpeakerRoster.fallbackName(for: raw, locale: english)
        }
        func needsReview(_ item: TranscriptSegment) -> Bool {
            item.conflict != nil || TranscriptFlagVocabulary.marksUncertainty(item.segment.flags ?? [])
        }
        let picked = indices.compactMap { index in
            run.segments.first { $0.index == index }
        }
        return VStack(spacing: 0) {
            TranscriptSegmentColumn(
                segments: picked,
                roster: roster,
                displayName: name,
                text: { $0.segment.text },
                needsReview: needsReview,
                isReviewable: needsReview,
                focusedSegmentIndex: focused,
                playingSegmentIndex: nil,
                selectedSegmentIDs: [],
                evidenceIsLoaded: true,
                proposalLayer: proposalLayer,
                play: { _ in },
                select: { _ in },
                rename: { _ in },
                review: { _ in }
            )
            Spacer(minLength: 0)
        }
    }

    /// The shipped screen inside the container the app gives it. On its own,
    /// `TranscriptView` reports a fitting height of zero and its
    /// `.navigationTitle` wrapper lays the screen out taller than the frame,
    /// so a bare render starts part-way down the list with no header, and one
    /// opened on the proposed layer drew nothing at all. Inside the
    /// `NavigationSplitView` that `RootView` composes it in, with a stub
    /// sidebar, the same view lays out inside the frame: title, counts, tabs,
    /// notice, rule and rows. This is the path for rendering the shipped
    /// composition; the sidebar column itself still does not draw.
    static func shippedScreen(_ screen: some View) -> some View {
        NavigationSplitView {
            Text(verbatim: "Library")
        } detail: {
            screen
        }
    }

    // MARK: - Screens: the layer switch in the shipped view

    /// The shipped `TranscriptView` opened on each of its two available layers
    /// through the initial-selection seam, over the synthetic four-segment run
    /// that carries a D50 speaker-proposal set, so no private recording is
    /// needed. The app end-to-end pass ran with post-processing off and the
    /// switch had never been rendered. Each image is read back twice: by OCR,
    /// for what the rows say, and by pixel, for where the accent underline
    /// under the displayed tab sits.
    @Test(ScreenSnapshotTests.whenRendering) @MainActor
    func layerSwitchRendersEachAvailableLayerInTheShippedView() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root, complete: false)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "proposal-a",
            finishedAt: "2026-09-01T23:13:07Z"
        )
        let run = try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        let proposal = try #require(run.speakerProposal)
        let record = Self.record(
            named: "Layer switch fixture",
            runURL: fixture.runURL,
            durationS: 8,
            state: .hasConflicts,
            speakerNames: ["SPEAKER_00": "Jina", "SPEAKER_01": "Minsu"]
        )
        let model = try Self.model()
        let layers: [TranscriptDisplayLayer] = [.speakerLabelled, .proposed]
        var readings: [TranscriptDisplayLayer: String] = [:]
        var underlines: [TranscriptDisplayLayer: [String: ClosedRange<Int>]] = [:]
        for layer in layers {
            for (schemeLabel, scheme) in Self.schemes {
                let name = "\(Self.tag)-layerswitch-\(layer.rawValue)-\(schemeLabel)"
                let size = try Self.host(
                    Self.shippedScreen(
                        TranscriptView(
                            model: model,
                            record: record,
                            run: run,
                            proposal: proposal,
                            initialLayer: layer
                        )
                    ),
                    width: 1_400, height: 700, scheme: scheme, name: name
                )
                let url = Self.outRoot.appendingPathComponent("\(name).png")
                let swatch = AppTheme.Palette.accentSwatch
                let underline = try Self.accentUnderline(
                    in: url, hex: scheme == .dark ? swatch.dark : swatch.light
                )
                underlines[layer, default: [:]][schemeLabel] = underline
                print("layerswitch \(layer.rawValue) \(schemeLabel) \(size) underline \(String(describing: underline))")
                if scheme == .light {
                    let lines = try Self.recognisedText(in: url)
                    print("layerswitch \(layer.rawValue) OCR lines: \(lines.count)")
                    readings[layer] = Self.compact(lines.joined(separator: "\n"))
                }
            }
        }
        let source = try #require(readings[.speakerLabelled])
        let proposed = try #require(readings[.proposed])
        // Both images carry the header, the tabs and the unnamed rows.
        for text in [source, proposed] {
            #expect(text.contains(Self.compact("Layer switch fixture")))
            #expect(text.contains(Self.compact("Speaker-labelled")))
            #expect(text.contains(Self.compact("Proposed")))
            #expect(text.contains(Self.compact("Speaker not named")))
        }
        // The proposal speaks on the two unnamed rows and in the notice only
        // when its layer is displayed.
        #expect(!source.contains(Self.compact("Proposed, not measured")))
        #expect(!source.contains(Self.compact("No speaker proposed")))
        #expect(!source.contains(Self.compact("1 proposed, 1 declined")))
        #expect(proposed.contains(Self.compact("Proposed, not measured")))
        #expect(proposed.contains(Self.compact("No speaker proposed")))
        #expect(proposed.contains(Self.compact("1 proposed, 1 declined")))
        // The accent underline sits under a different tab in each image, and
        // Proposed is the rightmost of the four, in both appearances.
        for (schemeLabel, _) in Self.schemes {
            let sourceUnderline = try #require(underlines[.speakerLabelled]?[schemeLabel])
            let proposedUnderline = try #require(underlines[.proposed]?[schemeLabel])
            #expect(sourceUnderline != proposedUnderline)
            #expect(proposedUnderline.lowerBound > sourceUnderline.upperBound)
        }
    }

    // MARK: - Screens: a run short of its input

    /// The shipped view over the synthetic partial run: the notice under the
    /// tabs naming the lost range, and the gap row at its place among the
    /// rows. Read back by OCR. The real 20.7-minute run's own gap, at 14:31,
    /// is rendered through `composedTranscript` when that run is present.
    @Test(ScreenSnapshotTests.whenRendering) @MainActor
    func partialTranscriptScreen() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root, complete: false)
        let run = try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        let record = Self.record(
            named: "Partial run fixture",
            runURL: fixture.runURL,
            durationS: 8,
            state: .hasConflicts,
            speakerNames: ["SPEAKER_00": "Jina", "SPEAKER_01": "Minsu"]
        )
        let model = try Self.model()
        var readings: [String: String] = [:]
        for (widthLabel, width) in Self.widths {
            for (schemeLabel, scheme) in Self.schemes {
                let name = "\(Self.tag)-partial-\(widthLabel)-\(schemeLabel)"
                try Self.host(
                    Self.shippedScreen(
                        TranscriptView(model: model, record: record, run: run, proposal: nil)
                    ),
                    width: width, height: 700, scheme: scheme, name: name
                )
                if scheme == .light {
                    let lines = try Self.recognisedText(in: Self.outRoot.appendingPathComponent("\(name).png"))
                    print("partial \(widthLabel) OCR lines: \(lines.count)")
                    readings[widthLabel] = Self.compact(lines.joined(separator: "\n"))
                }
            }
        }
        for (widthLabel, text) in readings {
            #expect(text.contains(Self.compact("2.0 sec of this recording produced no transcript, from 00:06 to 00:08")), Comment(rawValue: widthLabel))
            #expect(text.contains(Self.compact("The transcript covers 00:06 of 00:08")), Comment(rawValue: widthLabel))
            #expect(text.contains(Self.compact("No transcript from 00:06 to 00:08 (2.0 sec)")), Comment(rawValue: widthLabel))
            // The gap row sits between the third and fourth segments.
            let two = text.range(of: Self.compact("Two"))
            // The row's sentence, not the header's, which also starts this way.
            let gap = text.range(of: Self.compact("No transcript from 00:06 to 00:08 (2.0 sec)."))
            let three = text.range(of: Self.compact("Three"))
            if let two, let gap, let three {
                #expect(two.lowerBound < gap.lowerBound, Comment(rawValue: widthLabel))
                #expect(gap.lowerBound < three.lowerBound, Comment(rawValue: widthLabel))
            } else {
                Issue.record("rows or gap not read back at \(widthLabel)")
            }
        }
        // The real run, composed from the shipped views around its own gap at
        // 14:31: the rows on either side of the lost range and the row between.
        guard Self.exists(Self.proposalRunURL) else {
            print("SKIP partial real: real run absent")
            return
        }
        let real = try Self.realRun(
            at: Self.proposalRunURL, name: "Weekly product sync", state: .hasConflicts
        )
        let coverage = try #require(TranscriptMissingCoverage.load(run: real.run, record: real.record))
        print("partial real gaps: \(coverage.gaps.map { [$0.startS, $0.endS] })")
        for (schemeLabel, scheme) in Self.schemes {
            try Self.host(
                Self.composedTranscript(
                    real: real, proposal: nil, layer: .speakerLabelled, width: 1_400,
                    focused: nil, selected: [], rows: 8,
                    firstRow: max(0, (real.run.segments.firstIndex {
                        $0.segment.startS >= (coverage.gaps.first?.startS ?? 0)
                    } ?? 0) - 4)
                ),
                width: 1_400, height: 900, scheme: scheme,
                name: "\(Self.tag)-partial-real-\(schemeLabel)"
            )
        }
    }

    // MARK: - Screens: non-speech events

    /// Rows that hold no speech, between rows that do. The synthetic fixture
    /// runs on any machine; the real run's three event rows (indexes 25, 135
    /// and 247, each `UNKNOWN` and flagged for review) are rendered beside
    /// their neighbours when the private recording is present.
    @Test(ScreenSnapshotTests.whenRendering) @MainActor
    func nonSpeechEventRows() throws {
        var fixture = TranscriptFixtures.meetingShaped()
        // Row 2 is attributed with a contested share; row 3 is unnamed with
        // two candidates and a band. Both become event rows, as the real run's
        // are, and rows 1 and 4 stay speech around them, one carrying a marker
        // inside its words.
        fixture.run.segments[2].segment.text = "[Human Sounds]"
        fixture.run.segments[3].segment.text = "[Silence]"
        fixture.run.segments[4].segment.text = "Then we heard a [Buzzer] just then, and went on."
        fixture.run.segments[5].segment.text = "[Speech]"
        for index in [2, 3, 5] {
            fixture.run.segments[index].segment.flags?.append("non_speech_event")
        }
        let synthetic = RealRun(run: fixture.run, record: fixture.record)
        for (widthLabel, width) in Self.widths {
            for (schemeLabel, scheme) in Self.schemes {
                try Self.host(
                    Self.composedRows(real: synthetic, proposal: nil, indices: [1, 2, 3, 4, 5, 6], focused: nil),
                    width: width, height: 520, scheme: scheme,
                    name: "\(Self.tag)-nonspeech-synthetic-\(widthLabel)-\(schemeLabel)"
                )
            }
        }
        // The event row focused, so the reason sentence and the event share a
        // text column.
        try Self.host(
            Self.composedRows(real: synthetic, proposal: nil, indices: [2, 3, 4], focused: 3),
            width: 1_400, height: 320, scheme: .light,
            name: "\(Self.tag)-nonspeech-synthetic-focused-light"
        )
        guard Self.exists(Self.proposalRunURL) else {
            print("SKIP nonspeech real rows: real run absent")
            return
        }
        let real = try Self.realRun(
            at: Self.proposalRunURL, name: "Weekly product sync", state: .hasConflicts
        )
        let events = real.run.segments.filter {
            NonSpeechEvent.of(text: $0.segment.text, flags: $0.segment.flags) != nil
        }.map(\.index)
        print("nonspeech real rows: \(events)")
        let neighbours = Array(Set(events.flatMap { [$0 - 1, $0, $0 + 1] })).sorted()
            .filter { real.run.segments.indices.contains($0) }
        for (schemeLabel, scheme) in Self.schemes {
            try Self.host(
                Self.composedRows(real: real, proposal: nil, indices: neighbours, focused: nil),
                width: 1_400, height: 900, scheme: scheme,
                name: "\(Self.tag)-nonspeech-real-\(schemeLabel)"
            )
        }
        // The same rows under the proposal layer, where the derived set also
        // spoke about them.
        if let document = real.run.speakerProposal {
            try Self.host(
                Self.composedRows(real: real, proposal: document, indices: neighbours, focused: nil),
                width: 1_400, height: 1_100, scheme: .light,
                name: "\(Self.tag)-nonspeech-real-proposed-light"
            )
        }
    }

    // MARK: - Screens: sidebar

    @Test(ScreenSnapshotTests.whenRendering) @MainActor
    func sidebarScreens() throws {
        let states: [(LibraryItemState, String, Bool)] = [
            (.recorded, "Board review", false),
            (.transcribing, "Weekly product sync", false),
            (.done, "Italian call", false),
            (.hasConflicts, "Standup 2026-08-30", false),
            (.failed, "Late clip", false),
            (.cancelled, "Interview draft", false),
            (.interrupted, "Retro", false),
            (.done, "Post-processing now", true),
        ]
        let records = states.enumerated().map { index, item in
            Self.record(
                named: item.1,
                runURL: URL(fileURLWithPath: "/tmp/run-\(index)"),
                durationS: Double(300 + index * 137),
                state: item.0,
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            )
        }
        // Two sidebar widths: the minimum and the maximum the split view allows.
        for (widthLabel, width) in [("min", CGFloat(220)), ("max", CGFloat(340))] {
            for (schemeLabel, scheme) in Self.schemes {
                let stack = VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: "Library")
                        .font(AppTheme.Typography.sectionTitle)
                        .foregroundStyle(AppTheme.Palette.inkSecondary)
                        .padding(.bottom, AppTheme.Spacing.small)
                    ForEach(Array(records.enumerated()), id: \.offset) { index, item in
                        LibraryRecordRow(
                            record: item,
                            isPostprocessing: states[index].2,
                            draftName: nil
                        )
                        .padding(.vertical, 4)
                    }
                }
                .padding(AppTheme.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                let size = try Self.host(
                    stack, width: width, height: 560, scheme: scheme,
                    name: "\(Self.tag)-sidebar-\(widthLabel)-\(schemeLabel)"
                )
                print("sidebar \(widthLabel) \(schemeLabel) \(size)")
            }
        }
        // The rename field in place, which no previous pass could see.
        for (schemeLabel, scheme) in Self.schemes {
            let renaming = VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(records.prefix(3).enumerated()), id: \.offset) { index, item in
                    LibraryRecordRow(
                        record: item,
                        isPostprocessing: false,
                        draftName: index == 1 ? .constant("Weekly product sync") : nil
                    )
                    .padding(.vertical, 4)
                }
            }
            .padding(AppTheme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            try Self.host(
                renaming, width: 260, height: 220, scheme: scheme,
                name: "\(Self.tag)-sidebar-renaming-\(schemeLabel)"
            )
        }
        // The move-to-Trash confirmation's wording. The dialog itself is
        // presented by AppKit and never enters a render.
        let plan = LibraryTrashPlan(
            recordID: records[3].id,
            displayName: records[3].displayName,
            sourceURL: URL(fileURLWithPath: "/tmp/meeting.wav"),
            runURL: URL(fileURLWithPath: "/tmp/run-3")
        )
        for (schemeLabel, scheme) in Self.schemes {
            let wording = VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                Text(verbatim: LibraryTrashWording.title(for: plan, locale: Self.english))
                    .font(.headline)
                Text(verbatim: LibraryTrashWording.message(for: plan, locale: Self.english))
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(LibraryTrashWording.confirmLabel(for: plan, locale: Self.english))
                    Text(verbatim: "Cancel")
                }
                .font(.callout)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            try Self.host(
                wording, width: 520, height: 200, scheme: scheme,
                name: "\(Self.tag)-sidebar-trash-wording-\(schemeLabel)"
            )
        }
    }

    // MARK: - Screens: inspector

    @Test(ScreenSnapshotTests.whenRenderingTheRealRun) @MainActor
    func inspectorScreens() throws {
        let real = try Self.realRun(
            at: Self.proposalRunURL, name: "Weekly product sync", state: .hasConflicts
        )
        for (label, expanded) in [("collapsed", false), ("expanded", true)] {
            for (widthLabel, width) in [("narrow", CGFloat(300)), ("wide", CGFloat(450))] {
                for (schemeLabel, scheme) in Self.schemes {
                    let view = Form {
                        RunInspectorSections(
                            record: real.record,
                            run: real.run,
                            showsFingerprints: .constant(expanded)
                        )
                    }
                    .formStyle(.grouped)
                    // The expanded window is tall enough to reach the bottom of
                    // the fingerprint list. At 1400 the render stopped inside
                    // it, so the rows below `Glossary SHA-256` — the model
                    // revisions and the backend rows — had never been seen.
                    let size = try Self.host(
                        view, width: width, height: expanded ? 2_600 : 900, scheme: scheme,
                        name: "\(Self.tag)-inspector-\(label)-\(widthLabel)-\(schemeLabel)"
                    )
                    print("inspector \(label) \(widthLabel) \(schemeLabel) \(size)")
                }
            }
        }
    }


    // MARK: - The two rendering paths compared

    /// Records, in an image, exactly what the `ImageRenderer` path loses. The
    /// report cites this rather than asserting the limits from memory.
    @Test(ScreenSnapshotTests.whenRendering) @MainActor
    func rendererComparison() throws {
        let sample = VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Renderer probe").font(.title2)
            TextField("Search", text: .constant("glossary"))
            Slider(value: .constant(0.42))
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(0 ..< 4, id: \.self) { Text(verbatim: "scrolled row \($0)") }
                }
            }
            .frame(height: 90)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        try Self.host(sample, width: 460, height: 260, scheme: .light, name: "\(Self.tag)-probe-hosting")
        try Self.imageRenderer(sample, width: 460, height: 260, scheme: .light, name: "\(Self.tag)-probe-imagerenderer")
    }
}

// MARK: - Stubs

final class SnapshotRunner: TranscriptionRunning {
    enum Failure: Error { case unused }
    func run(
        _: TranscriptionRequest,
        progress _: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL {
        throw Failure.unused
    }

    func cancel() {}
}

final class SnapshotRecorder: RecordingControlling {
    enum Failure: Error { case unused }
    var meters = CaptureMeters.silent
    func setMeterHandler(_: (@MainActor (CaptureMeters) -> Void)?) {}
    func start(in _: URL) async throws -> RecordingSessionMetadata { throw Failure.unused }
    func stop() async throws -> RecordingArtifacts { throw Failure.unused }
    func cancel() async {}
}

actor SnapshotReadinessProbe: ProfileReadinessProbing {
    private let outcome: ProfileReadinessProbeOutcome
    init(outcome: ProfileReadinessProbeOutcome) { self.outcome = outcome }
    func probe(_: AppProfile) async -> ProfileReadinessProbeOutcome { outcome }
}
