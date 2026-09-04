// The offscreen accessibility walk behind `AccessibilityAuditTests`.
//
// Each screen is laid out in an `NSHostingView` with no window, exactly as the
// P6 render harness does, and its AppKit accessibility tree is then read
// through `NSAccessibilityProtocol`'s attributes: role, label, title, value,
// help, identifier, placeholder, enabled and the child list. SwiftUI builds
// that tree lazily, and two switches decide what it exposes:
//
//   * `.environment(\.accessibilityEnabled, true)` on the root makes the hosting
//     view return SwiftUI's own nodes for content laid out directly under it.
//   * The `AXEnhancedUserInterface` attribute on `NSApplication`, which an
//     assistive client sets when it connects, is what makes SwiftUI also build
//     nodes for content inside a `ScrollView`, a `LazyVStack` or a grouped
//     `Form`. Without it those containers expose only their AppKit-backed
//     controls and a scroll bar. It is set once per test process through the
//     informal-protocol selector AppKit still honours for that attribute.
//
// Neither needs Screen Recording or Accessibility permission, and no pixel is
// drawn. What the walk still cannot see is listed in the report the tests cite.
import AppKit
import Foundation
import MaccheroniCore
import MaccheroniMerge
import MaccheroniPostprocess
import SwiftUI
import Testing
@testable import MaccheroniApp

// MARK: - The tree

/// One node of the accessibility tree, with the attributes an assistive client
/// reads. Values are captured as strings so a dump is diffable.
struct AccessibilityElement: Equatable, Sendable {
    /// Child indices from the hosting view down, joined by dots.
    var path: String
    var depth: Int
    var className: String
    var role: String
    var subrole: String
    /// `AXDescription`, which is what `.accessibilityLabel` sets.
    var label: String
    /// `AXTitle`, which AppKit controls carry instead.
    var title: String
    /// `AXValue` when it is a string or a number; `nil` otherwise.
    var value: String?
    var valueDescription: String
    var help: String
    var identifier: String
    var placeholder: String
    var roleDescription: String
    var isElement: Bool
    var isEnabled: Bool
    var isSelected: Bool
    var customActionCount: Int
    var childCount: Int

    /// The name an assistive client announces for a control: the label, else
    /// the title. A text field's placeholder is not a name, and is reported
    /// separately.
    var name: String {
        label.isEmpty ? title : label
    }

    /// What is read for a static text or heading: its name, else its value.
    var text: String {
        name.isEmpty ? (value ?? "") : name
    }

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXPopUpButton", "AXMenuButton",
        "AXCheckBox", "AXRadioButton", "AXSlider", "AXDisclosureTriangle", "AXLink",
        "AXComboBox", "AXIncrementor", "AXMenuItem", "AXSwitch",
    ]

    var isInteractive: Bool { Self.interactiveRoles.contains(role) }
    var isImage: Bool { role == "AXImage" }
    var isStaticText: Bool { role == "AXStaticText" || role == "AXHeading" }
    var isGroup: Bool { role == "AXGroup" }
    var isSegmentedControl: Bool { role == "AXRadioGroup" }
    var isProgressIndicator: Bool { role == "AXProgressIndicator" || role == "AXBusyIndicator" }
    /// An element a client can reach that has a name but no role: announced
    /// with no word for what it is or how to operate it.
    var lacksRole: Bool { isElement && (role.isEmpty || role == "AXUnknown") && !name.isEmpty }
    /// An `Image(systemName:)` that reached the tree. SwiftUI names it with
    /// its own description of the symbol, or the symbol name itself.
    var isSystemImage: Bool { isImage && identifier.wholeMatch(of: AccessibilityRules.symbolNamePattern) != nil }
    /// A control whose name is the text of the elements combined into it: a
    /// notice that became one button, announced as a paragraph.
    var isNamedByCombinedText: Bool {
        isInteractive && name.count > 80 && name.contains(", ")
    }
    /// The first sentence of a combined name, which is what an exception is
    /// keyed on so the rest of the paragraph can change.
    var firstSentence: String {
        if let end = name.range(of: ". ") { return String(name[..<end.upperBound]).trimmingCharacters(in: .whitespaces) }
        if let end = name.range(of: ", ") { return String(name[..<end.lowerBound]) }
        return name
    }

    var parentPath: String? {
        guard let dot = path.lastIndex(of: ".") else { return nil }
        return String(path[..<dot])
    }

    /// One line per node, for the dump the report is built from.
    var dumpLine: String {
        var parts: [String] = ["\(String(repeating: "  ", count: depth))\(role.isEmpty ? "?" : role)"]
        if !subrole.isEmpty { parts.append("sub=\(subrole)") }
        if !label.isEmpty { parts.append("label=\(quoted(label))") }
        if !title.isEmpty { parts.append("title=\(quoted(title))") }
        if let value, !value.isEmpty { parts.append("value=\(quoted(value))") }
        if !valueDescription.isEmpty { parts.append("valueDescription=\(quoted(valueDescription))") }
        if !placeholder.isEmpty { parts.append("placeholder=\(quoted(placeholder))") }
        if !help.isEmpty { parts.append("help=\(quoted(help))") }
        if !identifier.isEmpty { parts.append("id=\(quoted(identifier))") }
        if !isElement { parts.append("ignored") }
        if !isEnabled, isInteractive { parts.append("disabled") }
        if isSelected { parts.append("selected") }
        if customActionCount > 0 { parts.append("actions=\(customActionCount)") }
        parts.append("[\(className)]")
        return parts.joined(separator: " ")
    }

    private func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

/// The whole tree of one hosted screen, in tree order, which is also the order
/// an assistive client walks it in.
struct AccessibilityTree: Sendable {
    var name: String
    var elements: [AccessibilityElement]

    var interactive: [AccessibilityElement] { elements.filter(\.isInteractive) }
    var images: [AccessibilityElement] { elements.filter(\.isImage) }
    var staticTexts: [AccessibilityElement] { elements.filter(\.isStaticText) }
    var buttons: [AccessibilityElement] { elements.filter { $0.role == "AXButton" } }

    func first(role: String, named name: String) -> AccessibilityElement? {
        elements.first { $0.role == role && $0.name == name }
    }

    func contains(role: String, named name: String) -> Bool {
        first(role: role, named: name) != nil
    }

    func contains(text: String) -> Bool {
        elements.contains { $0.isStaticText && $0.text == text }
    }

    func containsText(containing fragment: String) -> Bool {
        elements.contains { $0.isStaticText && $0.text.contains(fragment) }
    }

    /// The names of the interactive elements in the order a client reaches
    /// them, which is the closest thing to a focus order the walk can read.
    var navigationOrder: [String] {
        interactive.map { element in
            let name = element.name.isEmpty ? "(unnamed)" : element.name
            return "\(element.role) \(name)"
        }
    }

    func children(of parent: AccessibilityElement) -> [AccessibilityElement] {
        elements.filter { $0.parentPath == parent.path }
    }

    var dump: String {
        (["# \(name): \(elements.count) elements, \(interactive.count) interactive"]
            + elements.map(\.dumpLine)).joined(separator: "\n")
    }
}

// MARK: - Findings

/// One thing an accessibility audit would report about one element.
struct AccessibilityFinding: Hashable, Sendable, CustomStringConvertible {
    enum Kind: String, Sendable {
        /// A control with neither a label nor a title.
        case unlabelledControl
        /// A text field whose only name is its placeholder.
        case textFieldNamedByPlaceholderOnly
        /// A segmented control with no name of its own; its label, if any,
        /// is a separate static text a client does not associate with it.
        case unnamedSegmentedControl
        /// A name that is an identifier or an enum token rather than words.
        case rawTokenName
        /// An image that is neither hidden nor described.
        case imageWithoutDescription
        /// An SF Symbol image that reached the tree. This app's glyphs carry
        /// meaning only beside a word, so an exposed one is announced by
        /// SwiftUI's generic description of the symbol, or by its raw name.
        case imageExposedWithSymbolName
        /// Two controls under one parent with the same role and name.
        case duplicateSiblingControls
        /// A progress or busy indicator with no label saying what is busy.
        case unnamedProgressIndicator
        /// A reachable element with a name and no role.
        case elementWithoutRole
        /// A control whose name is the paragraph of text combined into it.
        case controlNamedByCombinedText
        /// A screen-specific expectation: an element the screen should expose
        /// is not in the tree.
        case missingElement
        /// A screen-specific expectation: a text the screen should read out
        /// is not in the tree.
        case missingText
        /// A screen-specific expectation: a text that should not be read out
        /// is in the tree.
        case unexpectedText
    }

    var kind: Kind
    var role: String
    var name: String
    var path: String

    /// Findings are matched to known exceptions by kind, role and name, never
    /// by path, so a row added above an element does not turn an accepted
    /// exception into a failure.
    struct Exception: Hashable, Sendable {
        var kind: Kind
        var role: String
        var name: String
    }

    var exception: Exception { Exception(kind: kind, role: role, name: name) }

    var description: String {
        "\(kind.rawValue) \(role) \(name.isEmpty ? "(no name)" : "\"\(name)\"") at \(path)"
    }
}

enum AccessibilityRules {
    /// Names that are identifiers or enum tokens. Kept narrow on purpose: a
    /// sentence that happens to contain a hyphenated word is not a token, so
    /// each pattern must match the whole name.
    static var tokenPatterns: [Regex<Substring>] { [
        // SPEAKER_00, ASR_REPETITION_LOOPING
        /^[A-Z][A-Z0-9]*_[A-Z0-9_]+$/,
        // backend_speaker_evidence, free_text_context
        /^[a-z0-9]+(?:_[a-z0-9]+)+$/,
        // koreanITMeeting, noDominantSpeaker
        /^[a-z]+(?:[A-Z][a-z0-9]*)+$/,
        // ko-it-meeting
        /^[a-z0-9]+(?:-[a-z0-9]+)+$/,
    ] }

    /// Symbol and file names: checkmark.circle.fill, meeting.wav. Flagged on
    /// controls and images, where a client would announce them as the name.
    static var dottedTokenPattern: Regex<Substring> { /^[a-z0-9]+(?:\.[a-z0-9]+)+$/ }
    /// An SF Symbol name: one lowercase word, or dotted words.
    static var symbolNamePattern: Regex<Substring> { /^[a-z0-9]+(?:\.[a-z0-9]+)*$/ }

    static let bareTokens: Set<String> = [
        SpeakerRoster.unnamed, SpeakerRoster.unattributed,
    ]

    /// `forControl` widens the patterns to dotted symbol and file names and
    /// to kebab-case identifiers, which a control must never be named by. A
    /// static text may legitimately print a kebab-case product name as a
    /// value, so those two patterns are not applied to text.
    static func isRawToken(_ name: String, forControl: Bool) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if bareTokens.contains(trimmed) { return true }
        let patterns = forControl ? tokenPatterns : Array(tokenPatterns.dropLast())
        if patterns.contains(where: { trimmed.wholeMatch(of: $0) != nil }) { return true }
        if forControl, trimmed.wholeMatch(of: dottedTokenPattern) != nil { return true }
        return false
    }

    static func findings(in tree: AccessibilityTree) -> [AccessibilityFinding] {
        var findings: [AccessibilityFinding] = []
        var siblingsSeen: Set<String> = []

        for element in tree.elements where element.isElement {
            func report(_ kind: AccessibilityFinding.Kind, _ name: String = "") {
                findings.append(AccessibilityFinding(
                    kind: kind, role: element.role, name: name.isEmpty ? element.name : name, path: element.path
                ))
            }

            if element.isInteractive {
                if element.name.isEmpty {
                    if element.role == "AXTextField", !element.placeholder.isEmpty {
                        report(.textFieldNamedByPlaceholderOnly, element.placeholder)
                    } else {
                        report(.unlabelledControl)
                    }
                } else if isRawToken(element.name, forControl: true) {
                    report(.rawTokenName)
                }
                if !element.name.isEmpty {
                    let key = "\(element.parentPath ?? "")|\(element.role)|\(element.name)"
                    if siblingsSeen.contains(key) {
                        report(.duplicateSiblingControls)
                    }
                    siblingsSeen.insert(key)
                }
            }

            if element.isSegmentedControl, element.name.isEmpty {
                report(.unnamedSegmentedControl)
            }

            if element.isImage {
                if element.isSystemImage {
                    report(.imageExposedWithSymbolName, "\(element.name) (\(element.identifier))")
                } else if element.name.isEmpty {
                    report(.imageWithoutDescription)
                } else if isRawToken(element.name, forControl: true) {
                    report(.rawTokenName)
                }
            }

            if element.isStaticText, isRawToken(element.text, forControl: false) {
                report(.rawTokenName, element.text)
            }

            if element.isProgressIndicator, element.name.isEmpty {
                report(.unnamedProgressIndicator)
            }

            if element.lacksRole {
                report(.elementWithoutRole)
            }

            if element.isNamedByCombinedText {
                report(.controlNamedByCombinedText, element.firstSentence)
            }
        }
        return findings
    }

    /// What one screen is expected to expose, beyond the generic rules.
    enum Expectation: Sendable {
        case element(role: String, name: String)
        case text(String)
        case textContaining(String)
        case noText(String)
        case noTextContaining(String)

        func finding(in tree: AccessibilityTree) -> AccessibilityFinding? {
            switch self {
            case let .element(role, name):
                return tree.contains(role: role, named: name)
                    ? nil
                    : AccessibilityFinding(kind: .missingElement, role: role, name: name, path: "")
            case let .text(text):
                return tree.contains(text: text)
                    ? nil
                    : AccessibilityFinding(kind: .missingText, role: "AXStaticText", name: text, path: "")
            case let .textContaining(fragment):
                return tree.containsText(containing: fragment)
                    ? nil
                    : AccessibilityFinding(kind: .missingText, role: "AXStaticText", name: fragment, path: "")
            case let .noText(text):
                guard let element = tree.elements.first(where: { $0.isStaticText && $0.text == text })
                else { return nil }
                return AccessibilityFinding(kind: .unexpectedText, role: element.role, name: text, path: element.path)
            case let .noTextContaining(fragment):
                guard let element = tree.elements.first(where: { $0.isStaticText && $0.text.contains(fragment) })
                else { return nil }
                return AccessibilityFinding(kind: .unexpectedText, role: element.role, name: fragment, path: element.path)
            }
        }
    }

    /// The findings that are not on the screen's accepted list, and the
    /// accepted exceptions the screen no longer produces. The second list is
    /// as important as the first: an exception that stopped firing is either a
    /// fix that landed, in which case the exception should go, or a control
    /// that vanished from the tree.
    static func audit(
        _ tree: AccessibilityTree,
        expecting expectations: [Expectation] = [],
        accepting exceptions: [AccessibilityFinding.Exception]
    ) -> (unexpected: [AccessibilityFinding], stale: [AccessibilityFinding.Exception]) {
        let found = findings(in: tree) + expectations.compactMap { $0.finding(in: tree) }
        let accepted = Set(exceptions)
        let unexpected = found.filter { !accepted.contains($0.exception) }
        let fired = Set(found.map(\.exception))
        let stale = exceptions.filter { !fired.contains($0) }
        return (unexpected, stale)
    }
}

// MARK: - Hosting and walking

enum AccessibilityAudit {
    static let english = Locale(identifier: "en")

    /// `NSApplication` can be created only inside a window-server session.
    /// The audit needs no window, but it needs that much; a fresh clone
    /// without a GUI session skips the suite rather than aborting it.
    static var hasWindowServerSession: Bool {
        CGSessionCopyCurrentDictionary() != nil
    }

    /// Where dumps go when `A11Y_AUDIT_DUMP` names a directory. Off by
    /// default; the tests assert on the tree, not on the file.
    static var dumpDirectory: URL? {
        ProcessInfo.processInfo.environment["A11Y_AUDIT_DUMP"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    /// Sets the `AXEnhancedUserInterface` attribute an assistive client sets
    /// on the application when it connects. Process-wide, set once, and never
    /// reset: it only makes SwiftUI build nodes it would otherwise defer.
    @MainActor
    static let assistiveInterfaceEnabled: Bool = {
        let app = NSApplication.shared
        let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        guard app.responds(to: selector) else { return false }
        _ = app.perform(selector, with: NSNumber(value: true), with: "AXEnhancedUserInterface" as NSString)
        return ((app as NSObject).value(forKey: "accessibilityEnhancedUserInterface") as? Bool) ?? false
    }()

    /// Lay the view out offscreen and read its accessibility tree.
    @MainActor
    static func host(
        _ view: some View,
        name: String,
        width: CGFloat = 1_000,
        height: CGFloat = 1_000,
        scheme: ColorScheme = .light
    ) -> AccessibilityTree {
        read(mount(view, width: width, height: height, scheme: scheme), name: name)
    }

    /// Lay the view out offscreen and keep it, for a screen whose state has
    /// to change on the main actor before it is read.
    @MainActor
    static func mount(
        _ view: some View,
        width: CGFloat = 1_000,
        height: CGFloat = 1_000,
        scheme: ColorScheme = .light
    ) -> NSHostingView<AnyView> {
        _ = assistiveInterfaceEnabled
        let root = AnyView(
            view
                .environment(\.locale, english)
                .environment(\.colorScheme, scheme)
                .environment(\.accessibilityEnabled, true)
                .frame(width: width, height: height, alignment: .top)
        )
        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        settle(hosting)
        return hosting
    }

    /// Settle a mounted view again and read its tree.
    @MainActor
    static func read(_ hosting: NSHostingView<AnyView>, name: String) -> AccessibilityTree {
        settle(hosting)
        var elements: [AccessibilityElement] = []
        walk(hosting, path: "0", depth: 0, into: &elements)
        let tree = AccessibilityTree(name: name, elements: elements)
        writeDump(tree)
        return tree
    }

    /// Let SwiftUI settle: `.task` bodies, `ViewThatFits` measurement and
    /// AppKit control layout all land on later run-loop turns.
    @MainActor
    static func settle(_ view: NSView, turns: Int = 12) {
        view.layoutSubtreeIfNeeded()
        for _ in 0 ..< turns {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
        }
    }

    /// SwiftUI's accessibility nodes implement the `NSAccessibilityProtocol`
    /// selectors without declaring the conformance, so a protocol cast fails on
    /// them. Key-value coding reaches the same getters on every node kind.
    @MainActor
    static func attribute(_ object: AnyObject, _ key: String, getter: String? = nil) -> Any? {
        guard let object = object as? NSObject else { return nil }
        guard object.responds(to: NSSelectorFromString(getter ?? key)) else { return nil }
        return object.value(forKey: key)
    }

    @MainActor
    static func string(_ object: AnyObject, _ key: String) -> String {
        (attribute(object, key) as? String) ?? ""
    }

    @MainActor
    static func flag(_ object: AnyObject, _ key: String, getter: String) -> Bool {
        (attribute(object, key, getter: getter) as? Bool) ?? false
    }

    @MainActor
    static func walk(_ object: Any, path: String, depth: Int, into out: inout [AccessibilityElement]) {
        let node = object as AnyObject
        let children = (attribute(node, "accessibilityChildren") as? [Any]) ?? []
        let customActions = (attribute(node, "accessibilityCustomActions") as? [Any]) ?? []
        let value: String? = switch attribute(node, "accessibilityValue") {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
        out.append(AccessibilityElement(
            path: path,
            depth: depth,
            className: String(describing: type(of: object)),
            role: string(node, "accessibilityRole"),
            subrole: string(node, "accessibilitySubrole"),
            label: string(node, "accessibilityLabel"),
            title: string(node, "accessibilityTitle"),
            value: value,
            valueDescription: string(node, "accessibilityValueDescription"),
            help: string(node, "accessibilityHelp"),
            identifier: string(node, "accessibilityIdentifier"),
            placeholder: string(node, "accessibilityPlaceholderValue"),
            roleDescription: string(node, "accessibilityRoleDescription"),
            isElement: flag(node, "accessibilityElement", getter: "isAccessibilityElement"),
            isEnabled: flag(node, "accessibilityEnabled", getter: "isAccessibilityEnabled"),
            isSelected: flag(node, "accessibilitySelected", getter: "isAccessibilitySelected"),
            customActionCount: customActions.count,
            childCount: children.count
        ))
        for (index, child) in children.enumerated() {
            walk(child, path: "\(path).\(index)", depth: depth + 1, into: &out)
        }
    }

    static func writeDump(_ tree: AccessibilityTree) {
        guard let directory = dumpDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let findings = AccessibilityRules.findings(in: tree)
        let text = tree.dump
            + "\n\n# findings: \(findings.count)\n"
            + findings.map(\.description).joined(separator: "\n")
            + "\n\n# navigation order\n"
            + tree.navigationOrder.joined(separator: "\n")
            + "\n"
        try? text.write(
            to: directory.appendingPathComponent("\(tree.name).txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

// MARK: - Fixtures

/// Synthetic data only: the 248-segment shape `TranscriptFixtures` builds,
/// plus a wording conflict, a segment with no acoustic candidates and a tie,
/// so every kind of row and chip the transcript can show is on screen.
enum AccessibilityAuditFixtures {
    @MainActor
    static func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniAccessibilityAudit-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A valid, silent, 0.1-second 16 kHz mono PCM WAV, so a record that
    /// points at it counts as readable audio the way an imported file does.
    @MainActor
    static func silentWAV(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("silence.wav")
        let sampleRate: UInt32 = 16_000
        let frames: UInt32 = 1_600
        let dataBytes = frames * 2
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(sampleRate); append(sampleRate * 2)
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataBytes)
        data.append(Data(count: Int(dataBytes)))
        try data.write(to: url)
        return url
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
    static func model(
        report: ProfileReadinessReport = readyReport(),
        records: [LibraryRecord] = [],
        permissions: CapturePermissions = CapturePermissions(microphone: .granted, systemAudio: .granted)
    ) throws -> MaccheroniAppModel {
        let suite = "MaccheroniAccessibilityAudit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let repository = LibraryRepository(root: try temporaryRoot())
        if !records.isEmpty {
            try repository.saveRecords(records)
        }
        return try MaccheroniAppModel(
            repository: repository,
            profiles: try AppProfileRegistry.load(),
            runner: AuditRunner(),
            recorder: AuditRecorder(),
            defaults: defaults,
            readinessProbe: AuditReadinessProbe(outcome: .report(report)),
            capturePermissions: { permissions },
            readinessWaitBudget: .seconds(5)
        )
    }

    /// Ask the model to evaluate readiness and yield until it has. A nested
    /// run loop cannot drain main-actor continuations while a main-queue block
    /// is executing, so this has to be awaited rather than pumped: the
    /// probe's answer comes back to the main actor as one.
    @MainActor
    static func settleReadiness(_ model: MaccheroniAppModel) async -> Bool {
        model.evaluateProfileReadiness()
        for _ in 0 ..< 1_000 {
            if model.profileReadiness.hasResult, !model.profileReadiness.isEvaluating { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    static func record(
        named name: String,
        runURL: URL?,
        durationS: Double,
        state: LibraryItemState,
        id: UUID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
        postprocess: PostprocessChoice = .none,
        failureMessage: String? = nil,
        sourceURL: URL = URL(fileURLWithPath: "/tmp/meeting.wav")
    ) -> LibraryRecord {
        LibraryRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_788_000_000),
            displayName: name,
            sourceKind: .importedFile,
            sourceURL: sourceURL,
            securityScopedBookmark: nil,
            microphoneURL: nil,
            systemAudioURL: nil,
            runURL: runURL,
            profileID: .koreanITMeeting,
            postprocess: postprocess,
            durationS: durationS,
            state: state,
            speakerNames: ["0": "Jina"],
            conflictResolutions: [:],
            failureMessage: failureMessage
        )
    }

    /// One record per library state, as the sidebar render does.
    static func sidebarRecords() -> [LibraryRecord] {
        let states: [(LibraryItemState, String)] = [
            (.recorded, "Board review"),
            (.transcribing, "Weekly product sync"),
            (.done, "Italian call"),
            (.hasConflicts, "Standup 2026-08-30"),
            (.failed, "Late clip"),
            (.cancelled, "Interview draft"),
            (.interrupted, "Retro"),
            (.done, "Post-processing now"),
        ]
        return states.enumerated().map { index, item in
            record(
                named: item.1,
                runURL: URL(fileURLWithPath: "/tmp/run-\(index)"),
                durationS: Double(300 + index * 137),
                state: item.0,
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            )
        }
    }

    struct MeetingRun {
        var run: LoadedRun
        var record: LibraryRecord
        /// The attributed segment whose conflict was turned into a wording
        /// disagreement, so a *Wording* chip is on screen.
        var wordingSegmentIndex: Int
        /// The unnamed segment left with no acoustic candidates at all.
        var silentSegmentIndex: Int
        /// The unnamed segment whose two candidates hold equal overlap.
        var tieSegmentIndex: Int
    }

    /// The 248-segment shape with three rows changed so the rarer states the
    /// design names are all present: a wording disagreement, a segment with
    /// no overlapping turn, and an exact tie.
    static func meetingRun() -> MeetingRun {
        var fixture = TranscriptFixtures.meetingShaped()
        var run = fixture.run
        fixture.record.state = .hasConflicts

        let wordingIndex = run.segments.first {
            $0.index > 2 && $0.conflict?.kind == .overlappingSpeech
        }!.index
        let wordingConflict = MergeConflict(
            segmentIndex: wordingIndex,
            kind: .asrDisagreement,
            candidates: [
                run.segments[wordingIndex].segment.text,
                "An alternative wording of this line.",
            ],
            reason: "The comparison backend disagreed."
        )
        run.segments[wordingIndex].conflict = wordingConflict

        let unnamed = run.segments.filter { !SpeakerRoster.isAttributed($0.segment.speaker) && $0.index > 6 }
        let silentIndex = unnamed[0].index
        let silentConflict = MergeConflict(
            segmentIndex: silentIndex,
            kind: .ambiguousSpeaker,
            candidates: [],
            reason: "No speaker was active on the timeline during this segment.",
            speakerAttribution: TranscriptFixtures.attribution(
                outcome: .noOverlappingTurn, candidates: [], coverage: 0
            )
        )
        run.segments[silentIndex].conflict = silentConflict

        let tieIndex = unnamed[1].index
        let tieDuration = run.segments[tieIndex].segment.endS - run.segments[tieIndex].segment.startS
        let tieConflict = MergeConflict(
            segmentIndex: tieIndex,
            kind: .ambiguousSpeaker,
            candidates: ["0", "1"],
            reason: "The two speakers held equal overlap.",
            speakerAttribution: TranscriptFixtures.attribution(
                outcome: .noDominantSpeaker,
                candidates: [("0", tieDuration / 2, 0.5), ("1", tieDuration / 2, 0.5)],
                coverage: 0.95
            )
        )
        run.segments[tieIndex].conflict = tieConflict

        run.conflicts = run.segments.compactMap(\.conflict)
        return MeetingRun(
            run: run,
            record: fixture.record,
            wordingSegmentIndex: wordingIndex,
            silentSegmentIndex: silentIndex,
            tieSegmentIndex: tieIndex
        )
    }

    /// A D50 confirm-or-decline proposal set over every unnamed segment of
    /// `meetingRun`, with every decline cause the constraint writes, over a
    /// source whose coverage is short so the missing-range notice prints.
    static func proposalDocument(for meeting: MeetingRun) -> SpeakerProposalDocument {
        var proposals: [SpeakerProposal] = []
        var declined: [SpeakerProposalDecline] = []
        let unnamed = meeting.run.segments.filter { !SpeakerRoster.isAttributed($0.segment.speaker) }
        for (position, item) in unnamed.enumerated() {
            let attribution = item.conflict?.speakerAttribution
            let candidates = (attribution?.candidates ?? []).map {
                SpeakerCandidateEvidence(speaker: $0.speaker, overlapS: $0.overlapS, share: $0.share)
            }
            let outcome = (attribution?.outcome ?? .noDominantSpeaker).rawValue
            let coverage = attribution?.timelineCoverage ?? 0
            let topRanked = SpeakerProposalConstraint.topRankedCandidate(among: candidates)

            if item.index == meeting.silentSegmentIndex {
                declined.append(SpeakerProposalDecline(
                    segmentIndex: item.index,
                    reason: "No diarization turn overlapped this segment, so there is no top-ranked candidate to confirm. The segment is silence.",
                    acousticOutcome: outcome,
                    acousticTimelineCoverage: coverage,
                    acousticCandidates: candidates,
                    cause: .noAcousticCandidates,
                    topRankedCandidate: nil,
                    modelAnswer: SpeakerProposalDecision(
                        segmentIndex: item.index,
                        proposedSpeaker: "",
                        disposition: .decline,
                        reason: "The segment is silence and has no top-ranked candidate to confirm."
                    )
                ))
            } else if item.index == meeting.tieSegmentIndex {
                declined.append(SpeakerProposalDecline(
                    segmentIndex: item.index,
                    reason: "The two speakers held equal overlap, so there is no top-ranked candidate to confirm.",
                    acousticOutcome: outcome,
                    acousticTimelineCoverage: coverage,
                    acousticCandidates: candidates,
                    cause: .noTopRankedCandidate,
                    topRankedCandidate: nil,
                    modelAnswer: SpeakerProposalDecision(
                        segmentIndex: item.index,
                        proposedSpeaker: "0",
                        disposition: .propose,
                        reason: "The model named a speaker the acoustics did not single out."
                    )
                ))
            } else if let topRanked, position % 3 == 0 {
                proposals.append(SpeakerProposal(
                    segmentIndex: item.index,
                    proposedSpeaker: topRanked,
                    reason: "The preceding turn continues the same speaker's explanation.",
                    acousticOutcome: outcome,
                    acousticTimelineCoverage: coverage,
                    acousticCandidates: candidates
                ))
            } else if let topRanked, position % 3 == 1 {
                declined.append(SpeakerProposalDecline(
                    segmentIndex: item.index,
                    reason: "The model would not say which of the two was speaking.",
                    acousticOutcome: outcome,
                    acousticTimelineCoverage: coverage,
                    acousticCandidates: candidates,
                    cause: .modelDeclined,
                    topRankedCandidate: topRanked,
                    modelAnswer: SpeakerProposalDecision(
                        segmentIndex: item.index,
                        proposedSpeaker: "",
                        disposition: .decline,
                        reason: "The model would not say which of the two was speaking."
                    )
                ))
            } else if let topRanked {
                let other = topRanked == "0" ? "1" : "0"
                declined.append(SpeakerProposalDecline(
                    segmentIndex: item.index,
                    reason: "The model named speaker \(other) where the acoustics ranked speaker \(topRanked) first, so nothing was proposed.",
                    acousticOutcome: outcome,
                    acousticTimelineCoverage: coverage,
                    acousticCandidates: candidates,
                    cause: .modelDisagreedWithTopRankedCandidate,
                    topRankedCandidate: topRanked,
                    modelAnswer: SpeakerProposalDecision(
                        segmentIndex: item.index,
                        proposedSpeaker: other,
                        disposition: .propose,
                        reason: "The question in the previous line was answered by the other speaker."
                    )
                ))
            }
        }
        return SpeakerProposalDocument(
            sourceSegmentsSHA256: String(repeating: "c", count: 64),
            sourceCoverage: DerivedSourceCoverage(
                complete: false,
                inputDurationS: TranscriptFixtures.recordingDurationS,
                processedDurationS: 1_212.52,
                message: "promoted 1212.520 s of 1243.080 s; 1 range(s) produced no transcript: [871.552, 902.112) s"
            ),
            constraint: .confirmOrDecline,
            proposals: proposals,
            declined: declined,
            batches: [
                TranslationBatchRecord(
                    batchIndex: 0,
                    segmentIndices: unnamed.map(\.index),
                    promptUTF8Bytes: 4_285,
                    inputTextUTF8Bytes: 1_541,
                    estimatedOutputTokens: 3_690,
                    outputTextUTF8Bytes: 270,
                    responseUTF8Bytes: 527,
                    acceptedOutputTokenUpperBound: 847
                ),
            ]
        )
    }

    /// A run directory holding only a failed manifest, so the progress screen
    /// has a cause to name. Nothing else in the run is read for that.
    @MainActor
    static func failedRunDirectory(in root: URL) throws -> URL {
        let runURL = root.appendingPathComponent("failed-run", isDirectory: true)
        try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
        var manifest = TranscriptFixtures.meetingShaped().run.manifest
        manifest.status = .failed
        manifest.coverage.processedDurationS = 0
        manifest.coverage.truncated = true
        manifest.failure = Failure(
            code: "ASR_REPETITION_LOOPING",
            message: "promoted 0.000 s of 1243.080 s; 1 range(s) produced no transcript after repetition looping exhausted recovery: [0.000, 1243.080) s"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: runURL.appendingPathComponent("manifest.json"))
        return runURL
    }

    // MARK: Composed transcript screens

    /// The transcript screen composed from the same shipped header and column
    /// views `TranscriptView` builds, without the scroll view around the
    /// column, so every row is laid out and the proposal layer can be shown:
    /// `TranscriptView` chooses its layer in private state and never opens on
    /// `.proposed` (D46).
    @MainActor
    static func composedTranscript(
        meeting: MeetingRun,
        proposal: SpeakerProposalDocument?,
        layer: TranscriptDisplayLayer,
        focused: Int?,
        selected: Set<Int>,
        rows: Int = 40
    ) -> some View {
        let run = meeting.run
        let record = meeting.record
        let roster = SpeakerRoster(segments: run.transcript.segments)
        let proposalLayer = proposal.map(TranscriptProposalLayer.init(document:))
        let options = TranscriptLayerCatalog.options(run: run, record: record, proposal: proposal)
        func name(_ raw: String) -> String {
            if let n = record.speakerNames[raw], !n.isEmpty { return n }
            return SpeakerRoster.fallbackName(for: raw, locale: AccessibilityAudit.english)
        }
        func needsReview(_ item: TranscriptSegment) -> Bool {
            item.conflict != nil || TranscriptFlagVocabulary.marksUncertainty(item.segment.flags ?? [])
        }
        let queue = run.segments.filter(needsReview).map(\.index)
        let unnamed = run.segments.filter { !SpeakerRoster.isAttributed($0.segment.speaker) }
        let gapLayer = layer == .proposed ? proposalLayer : nil
        let missingEvidence: TranscriptMissingEvidence? = unnamed.contains {
            $0.conflict?.speakerAttribution == nil && gapLayer?.inlineEvidence(at: $0.index) == nil
        } ? .someSegmentsHaveNoRecord : nil
        let unattributed = run.transcript.segments.count { !SpeakerRoster.isAttributed($0.speaker) }
        let summary = "\(run.transcript.segments.count) segments · \(run.transcript.numSpeakers) speakers · \(unattributed) without a speaker · \(queue.count) to review"
        let playback = TranscriptPlaybackController()
        let visible = Array(run.segments.prefix(rows))
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
                    playback: playback,
                    totalDurationS: run.manifest.coverage.inputDurationS,
                    togglePlayback: {},
                    seek: { _ in }
                )
                if layer == .proposed, let proposalLayer {
                    ProposalLayerNotice(layer: proposalLayer)
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
                play: { _ in },
                select: { _ in },
                rename: { _ in },
                review: { _ in }
            )
            Spacer(minLength: 0)
        }
    }

    /// A handful of rows on their own, for the decline-cause sentences.
    @MainActor
    static func composedRows(
        meeting: MeetingRun,
        proposal: SpeakerProposalDocument?,
        indices: [Int],
        focused: Int?
    ) -> some View {
        let run = meeting.run
        let record = meeting.record
        let roster = SpeakerRoster(segments: run.transcript.segments)
        let proposalLayer = proposal.map(TranscriptProposalLayer.init(document:))
        func name(_ raw: String) -> String {
            if let n = record.speakerNames[raw], !n.isEmpty { return n }
            return SpeakerRoster.fallbackName(for: raw, locale: AccessibilityAudit.english)
        }
        func needsReview(_ item: TranscriptSegment) -> Bool {
            item.conflict != nil || TranscriptFlagVocabulary.marksUncertainty(item.segment.flags ?? [])
        }
        let picked = indices.compactMap { index in run.segments.first { $0.index == index } }
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
}

// MARK: - Stubs

final class AuditRunner: TranscriptionRunning {
    enum Failure: Error { case unused }
    func run(
        _: TranscriptionRequest,
        progress _: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL {
        throw Failure.unused
    }

    func cancel() {}
}

final class AuditRecorder: RecordingControlling {
    enum Failure: Error { case unused }
    var meters = CaptureMeters.silent
    func setMeterHandler(_: (@MainActor (CaptureMeters) -> Void)?) {}
    func start(in _: URL) async throws -> RecordingSessionMetadata { throw Failure.unused }
    func stop() async throws -> RecordingArtifacts { throw Failure.unused }
    func cancel() async {}
}

actor AuditReadinessProbe: ProfileReadinessProbing {
    private let outcome: ProfileReadinessProbeOutcome
    init(outcome: ProfileReadinessProbeOutcome) { self.outcome = outcome }
    func probe(_: AppProfile) async -> ProfileReadinessProbeOutcome { outcome }
}
