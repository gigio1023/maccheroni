import Foundation
import SwiftUI

enum GlossaryCategory: String, CaseIterable, Identifiable {
    case people
    case terms
    case places

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .people: appLocalized("People")
        case .terms: appLocalized("Terms")
        case .places: appLocalized("Places")
        }
    }
}

struct GlossaryDraftEntry: Identifiable, Equatable {
    let id: UUID
    var term: String
    var category: GlossaryCategory
}

enum GlossaryDraftError: Error, Equatable {
    case emptyTerm
    case commentLikeTerm
    case multilineTerm
    case containsControlCharacter
    case termTooLong
    case duplicateTerm
}

struct GlossaryDraftRemoval {
    fileprivate struct Item {
        let index: Int
        let line: GlossaryDraftLine
    }

    fileprivate let items: [Item]
    var isEmpty: Bool { items.isEmpty }
}

private struct GlossaryDraftLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case preserved
        case entry(GlossaryDraftEntry)
    }

    let id: UUID
    var contents: String
    var lineEnding: String
    var kind: Kind
}

struct GlossaryDraftDocument {
    private var lines: [GlossaryDraftLine]

    init(text: String) {
        lines = []
        guard !text.isEmpty else { return }

        var category = GlossaryCategory.terms
        let components = text.components(separatedBy: "\n")
        for (index, component) in components.enumerated() {
            let isTrailingSentinel = index == components.count - 1
                && component.isEmpty
                && text.hasSuffix("\n")
            guard !isTrailingSentinel else { continue }

            let hasLineEnding = index < components.count - 1
            let usesCRLF = hasLineEnding && component.hasSuffix("\r")
            let contents = usesCRLF ? String(component.dropLast()) : component
            let lineEnding = hasLineEnding ? (usesCRLF ? "\r\n" : "\n") : ""
            var parsedContents = contents
            if lines.isEmpty, parsedContents.unicodeScalars.first == "\u{FEFF}" {
                parsedContents.removeFirst()
            }
            let trimmed = parsedContents.trimmingCharacters(in: .whitespacesAndNewlines)

            if let parsedCategory = Self.categoryMarker(in: trimmed) {
                category = parsedCategory
                lines.append(
                    GlossaryDraftLine(
                        id: UUID(),
                        contents: contents,
                        lineEnding: lineEnding,
                        kind: .preserved
                    )
                )
            } else if !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                let entry = GlossaryDraftEntry(id: UUID(), term: trimmed, category: category)
                lines.append(
                    GlossaryDraftLine(
                        id: entry.id,
                        contents: contents,
                        lineEnding: lineEnding,
                        kind: .entry(entry)
                    )
                )
            } else {
                lines.append(
                    GlossaryDraftLine(
                        id: UUID(),
                        contents: contents,
                        lineEnding: lineEnding,
                        kind: .preserved
                    )
                )
            }
        }
    }

    var entries: [GlossaryDraftEntry] {
        lines.compactMap { line in
            guard case let .entry(entry) = line.kind else { return nil }
            return entry
        }
    }

    func serialized() -> String {
        lines.map { $0.contents + $0.lineEnding }.joined()
    }

    static func validationError(for candidate: String) -> GlossaryDraftError? {
        if candidate.contains(where: \.isNewline) {
            return .multilineTerm
        }
        let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !term.isEmpty else { return .emptyTerm }
        guard !term.hasPrefix("#") else { return .commentLikeTerm }
        guard term.unicodeScalars.count <= 256 else { return .termTooLong }
        guard !term.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .containsControlCharacter
        }
        return nil
    }

    @discardableResult
    mutating func add(term candidate: String, category: GlossaryCategory) throws -> GlossaryDraftEntry {
        if let error = Self.validationError(for: candidate) {
            throw error
        }
        let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !entries.contains(where: {
            $0.term.precomposedStringWithCanonicalMapping == term
        }) else {
            throw GlossaryDraftError.duplicateTerm
        }

        let lineEnding = preferredLineEnding
        if let lastIndex = lines.indices.last, lines[lastIndex].lineEnding.isEmpty {
            lines[lastIndex].lineEnding = lineEnding
        }
        let marker = GlossaryDraftLine(
            id: UUID(),
            contents: "# category: \(category.rawValue)",
            lineEnding: lineEnding,
            kind: .preserved
        )
        let entry = GlossaryDraftEntry(id: UUID(), term: term, category: category)
        let entryLine = GlossaryDraftLine(
            id: entry.id,
            contents: term,
            lineEnding: lineEnding,
            kind: .entry(entry)
        )
        lines.append(marker)
        lines.append(entryLine)
        return entry
    }

    mutating func removeEntries(at offsets: IndexSet) -> GlossaryDraftRemoval {
        let entryIDs = entries.enumerated().compactMap { offset, entry in
            offsets.contains(offset) ? entry.id : nil
        }
        let idSet = Set(entryIDs)
        let items = lines.enumerated().compactMap { index, line -> GlossaryDraftRemoval.Item? in
            guard idSet.contains(line.id) else { return nil }
            return GlossaryDraftRemoval.Item(index: index, line: line)
        }
        for item in items.reversed() {
            lines.remove(at: item.index)
        }
        return GlossaryDraftRemoval(items: items)
    }

    mutating func restore(_ removal: GlossaryDraftRemoval) {
        for item in removal.items.sorted(by: { $0.index < $1.index }) {
            lines.insert(item.line, at: min(item.index, lines.endIndex))
        }
    }

    private var preferredLineEnding: String {
        lines.lazy.map(\.lineEnding).first(where: { !$0.isEmpty }) ?? "\n"
    }

    private static func categoryMarker(in line: String) -> GlossaryCategory? {
        let prefix = "# category: "
        guard line.hasPrefix(prefix) else { return nil }
        return GlossaryCategory(rawValue: String(line.dropFirst(prefix.count)))
    }
}

struct GlossaryEditorState {
    var document: GlossaryDraftDocument
    var presentedErrorMessage: String?
    let savingAllowed: Bool

    init(load: () throws -> String) {
        do {
            document = GlossaryDraftDocument(text: try load())
            presentedErrorMessage = nil
            savingAllowed = true
        } catch {
            document = GlossaryDraftDocument(text: "")
            presentedErrorMessage = error.localizedDescription
            savingAllowed = false
        }
    }
}

struct GlossaryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    let model: MaccheroniAppModel
    let profileID: AppProfileID
    @State private var editorState: GlossaryEditorState
    @State private var newTerm = ""
    @State private var newCategory = GlossaryCategory.terms
    @FocusState private var focusedOnNewTerm: Bool

    init(model: MaccheroniAppModel, profileID: AppProfileID) {
        self.model = model
        self.profileID = profileID
        _editorState = State(initialValue: GlossaryEditorState {
            try model.loadGlossary(for: profileID)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(appLocalized("Glossary"))
                        .font(.title2)
                    Text(profileID.title)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(appLocalized("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(appLocalized("Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!editorState.savingAllowed)
            }
            .padding(20)

            Divider()

            List {
                ForEach(editorState.document.entries) { entry in
                    GlossaryEntryRow(entry: entry) {
                        remove(entry)
                    }
                }
                .onDelete(perform: remove)
            }
            .frame(minHeight: 260)
            .disabled(!editorState.savingAllowed)

            Divider()

            HStack(spacing: 10) {
                TextField(appLocalized("Add a name, term, or place"), text: $newTerm)
                    .focused($focusedOnNewTerm)
                    .onSubmit(add)
                Picker(appLocalized("Category"), selection: $newCategory) {
                    ForEach(GlossaryCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Button(appLocalized("Add"), action: add)
                    .disabled(!canAddTerm)
            }
            .padding(20)
            .disabled(!editorState.savingAllowed)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420)
        .task { focusedOnNewTerm = editorState.savingAllowed }
        .alert(appLocalized("Glossary"), isPresented: Binding(
            get: { editorState.presentedErrorMessage != nil },
            set: { if !$0 { editorState.presentedErrorMessage = nil } }
        )) {
            Button(appLocalized("OK"), role: .cancel) {
                editorState.presentedErrorMessage = nil
            }
        } message: {
            Text(editorState.presentedErrorMessage ?? "")
        }
    }

    private var canAddTerm: Bool {
        editorState.savingAllowed
            && GlossaryDraftDocument.validationError(for: newTerm) == nil
            && !editorState.document.entries.contains(where: {
                $0.term.precomposedStringWithCanonicalMapping
                    == newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                        .precomposedStringWithCanonicalMapping
            })
    }

    private func add() {
        guard canAddTerm else { return }
        do {
            let previousDocument = editorState.document
            try editorState.document.add(term: newTerm, category: newCategory)
            undoManager?.registerUndo(withTarget: UndoTarget {
                editorState.document = previousDocument
            }) {
                $0.action()
            }
            newTerm = ""
            focusedOnNewTerm = true
        } catch {
            return
        }
    }

    private func remove(_ offsets: IndexSet) {
        let removal = editorState.document.removeEntries(at: offsets)
        guard !removal.isEmpty else { return }
        undoManager?.registerUndo(withTarget: UndoTarget {
            editorState.document.restore(removal)
        }) {
            $0.action()
        }
    }

    private func remove(_ entry: GlossaryDraftEntry) {
        guard let index = editorState.document.entries.firstIndex(of: entry) else { return }
        remove(IndexSet(integer: index))
    }

    private func save() {
        guard editorState.savingAllowed else { return }
        do {
            try model.saveGlossary(editorState.document.serialized(), for: profileID)
            dismiss()
        } catch {
            editorState.presentedErrorMessage = error.localizedDescription
        }
    }
}

private struct GlossaryEntryRow: View {
    let entry: GlossaryDraftEntry
    let remove: () -> Void

    var body: some View {
        HStack {
            Text(entry.term)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.category.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(appLocalized("Remove"), systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityLabel(appLocalized("Remove \(entry.term)"))
        }
        .contextMenu {
            Button(appLocalized("Remove"), role: .destructive, action: remove)
        }
    }
}

private final class UndoTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}
