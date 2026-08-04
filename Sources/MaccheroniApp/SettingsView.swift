import AppKit
import MaccheroniCore
import MaccheroniPostprocess
import SwiftUI

struct SettingsView: View {
    @Environment(AppLanguageStore.self) private var languageStore
    @AppStorage("selectedPostprocess") private var postprocessRaw = PostprocessChoice.local.rawValue
    @AppStorage(LibraryStorageSettings.localPostprocessModelKey) private var localPostprocessModel =
        ModelRegistry.localPostprocessModelSelection
    @AppStorage("selectedPostprocessMode") private var postprocessModeRaw =
        PostprocessOperationChoice.correction.rawValue
    @AppStorage("selectedTranslationTarget") private var translationTargetRaw =
        AppLanguage.english.rawValue
    @State private var codexAvailability: CodexAvailability?
    @State private var profiles: [AppProfile] = []
    @State private var cacheStatuses: [String: ModelCacheStatus] = [:]
    @State private var downloadingModelKeys: Set<String> = []
    @State private var loadError: String?
    @State private var recordingsDirectoryPath: String?
    @State private var runsDirectoryPath: String?

    private let repository = LibraryRepository.local
    private let modelDownloadService = ModelDownloadService()

    init() {
        _recordingsDirectoryPath = State(initialValue: UserDefaults.standard.string(
            forKey: LibraryStorageSettings.recordingsDirectoryKey
        ))
        _runsDirectoryPath = State(initialValue: UserDefaults.standard.string(
            forKey: LibraryStorageSettings.runsDirectoryKey
        ))
    }

    var body: some View {
        @Bindable var languageStore = languageStore
        TabView {
            general
                .tabItem { Label(appLocalized("General"), systemImage: "gearshape") }
            models
                .tabItem { Label(appLocalized("Models"), systemImage: "shippingbox") }
            storage
                .tabItem { Label(appLocalized("Storage"), systemImage: "internaldrive") }
        }
        .frame(minWidth: 680, minHeight: 500)
        .id(languageStore.rawValue)
        .environment(\.locale, languageStore.language.locale)
        .task {
            do {
                profiles = try AppProfileRegistry.load()
                cacheStatuses = ModelCacheInspector.statuses(for: uniqueModels)
            } catch {
                loadError = error.localizedDescription
            }
        }
        .task {
            codexAvailability = await Task.detached(priority: .utility) {
                await CodexPostprocessBackend.detectAvailability()
            }.value
        }
        .alert(appLocalized("Maccheroni Needs Attention"), isPresented: Binding(
            get: { loadError != nil },
            set: { if !$0 { loadError = nil } }
        )) {
            Button(appLocalized("OK"), role: .cancel) { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }

    private var general: some View {
        @Bindable var languageStore = languageStore
        return Form {
            Section(appLocalized("Language")) {
                Picker(appLocalized("App Language"), selection: $languageStore.rawValue) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                Text(appLocalized("English is the default. A manual choice applies to Maccheroni without changing the Mac system language."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(appLocalized("Default Post-processing")) {
                Picker(appLocalized("Backend"), selection: $postprocessRaw) {
                    ForEach(PostprocessChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                if postprocessRaw == PostprocessChoice.local.rawValue {
                    Picker(appLocalized("Current Model"), selection: $localPostprocessModel) {
                        Text(verbatim: LocalPostprocessBackend.pinnedModel.hfModelID)
                            .tag(ModelRegistry.localPostprocessModelSelection)
                    }
                    Text(verbatim: "\(LocalPostprocessBackend.pinnedModel.revision) · \(LocalPostprocessBackend.pinnedModel.quantization)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(appLocalized("A new setup selects Codex only when its CLI is signed in; otherwise it selects Local. Codex receives bounded transcript text, the active profile's full glossary and its hash, post-processing instructions, and the target language when translating. Audio never leaves this Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(appLocalized("Operation"), selection: $postprocessModeRaw) {
                    ForEach(PostprocessOperationChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if postprocessModeRaw == PostprocessOperationChoice.translation.rawValue {
                    Picker(appLocalized("Translate Into"), selection: $translationTargetRaw) {
                        ForEach(AppLanguage.translationTargets) { language in
                            Text(language.title).tag(language.rawValue)
                        }
                    }
                    .accessibilityHint(appLocalized("Chooses the language the transcript is translated into."))
                }

                LabeledContent(appLocalized("Codex CLI")) {
                    CodexStatusLabel(availability: codexAvailability)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var models: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(uniqueModels, id: \.key) { model in
                    ModelRegistryCard(
                        model: model.descriptor,
                        languages: model.languages,
                        metrics: model.metrics,
                        status: cacheStatuses[model.key] ?? .missing,
                        isDownloading: downloadingModelKeys.contains(model.key),
                        reveal: { revealModel(model.descriptor) },
                        download: { downloadModel(model.descriptor, key: model.key) },
                        moveToTrash: { moveModelToTrash(model.descriptor) }
                    )
                }
            }
            .padding(20)
        }
    }

    private var storage: some View {
        Form {
            Section(appLocalized("Local Library")) {
                StorageDirectoryControl(
                    title: appLocalized("Recordings"),
                    selectedURL: storageEnvironmentOverrideIsActive
                        ? repository.recordingsRoot
                        : selectedDirectory(
                            storedPath: recordingsDirectoryPath,
                            defaultURL: LibraryStorageSettings.defaultLibraryRoot()
                                .appendingPathComponent("Recordings", isDirectory: true)
                        ),
                    isEditable: !storageEnvironmentOverrideIsActive,
                    choose: chooseRecordingsDirectory,
                    useDefault: useDefaultRecordingsDirectory
                )
                StorageDirectoryControl(
                    title: appLocalized("Run Output"),
                    selectedURL: storageEnvironmentOverrideIsActive
                        ? repository.runsRoot
                        : selectedDirectory(
                            storedPath: runsDirectoryPath,
                            defaultURL: LibraryStorageSettings.defaultLibraryRoot()
                                .appendingPathComponent("Runs", isDirectory: true)
                        ),
                    isEditable: !storageEnvironmentOverrideIsActive,
                    choose: chooseRunsDirectory,
                    useDefault: useDefaultRunsDirectory
                )
                StoragePathRow(title: appLocalized("Glossaries"), url: repository.glossariesRoot)
            }
            Section {
                if storageEnvironmentOverrideIsActive {
                    Text(appLocalized("MACCHERONI_LIBRARY_ROOT controls the recording and run paths for this launch."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(appLocalized("Directory choices apply the next time Maccheroni launches. Existing recordings and run artifacts stay where they are."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appLocalized("Maccheroni never deletes or overwrites recordings, raw transcripts, or completed run artifacts. Model removal uses the macOS Trash."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var uniqueModels: [ConfiguredModel] {
        var values: [String: ConfiguredModel] = [:]
        for profile in profiles {
            for descriptor in profile.models {
                let key = ModelRegistry.key(for: descriptor)
                var configured = values[key] ?? ConfiguredModel(
                    key: key,
                    descriptor: descriptor,
                    languages: [],
                    metrics: []
                )
                configured.languages.formUnion(profile.languageCoverage)
                if descriptor.role == .asr {
                    for metric in profile.metrics where !configured.metrics.contains(metric) {
                        configured.metrics.append(metric)
                    }
                }
                values[key] = configured
            }
        }
        for descriptor in ModelRegistry.descriptors(in: profiles) {
            let key = ModelRegistry.key(for: descriptor)
            if values[key] == nil {
                values[key] = ConfiguredModel(
                    key: key,
                    descriptor: descriptor,
                    languages: [],
                    metrics: []
                )
            }
        }
        return values.values.sorted { $0.descriptor.hfModelID < $1.descriptor.hfModelID }
    }

    private var storageEnvironmentOverrideIsActive: Bool {
        LibraryStorageSettings.environmentLibraryRoot() != nil
    }

    private func selectedDirectory(storedPath: String?, defaultURL: URL) -> URL {
        LibraryStorageSettings.normalizedDirectoryURL(storedPath: storedPath) ?? defaultURL
    }

    private func chooseRecordingsDirectory() {
        chooseDirectory { url in
            persistDirectory(url, key: LibraryStorageSettings.recordingsDirectoryKey)
            recordingsDirectoryPath = url.path(percentEncoded: false)
        }
    }

    private func chooseRunsDirectory() {
        chooseDirectory { url in
            persistDirectory(url, key: LibraryStorageSettings.runsDirectoryKey)
            runsDirectoryPath = url.path(percentEncoded: false)
        }
    }

    private func useDefaultRecordingsDirectory() {
        UserDefaults.standard.removeObject(forKey: LibraryStorageSettings.recordingsDirectoryKey)
        recordingsDirectoryPath = nil
    }

    private func useDefaultRunsDirectory() {
        UserDefaults.standard.removeObject(forKey: LibraryStorageSettings.runsDirectoryKey)
        runsDirectoryPath = nil
    }

    private func chooseDirectory(_ save: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = appString("Choose Folder…")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(url.standardizedFileURL)
    }

    private func persistDirectory(_ url: URL, key: String) {
        UserDefaults.standard.set(url.standardizedFileURL.path(percentEncoded: false), forKey: key)
    }

    private func revealModel(_ descriptor: ModelDescriptor) {
        guard let url = ModelCacheInspector.location(for: descriptor),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func downloadModel(_ descriptor: ModelDescriptor, key: String) {
        guard !downloadingModelKeys.contains(key) else { return }
        downloadingModelKeys.insert(key)
        Task {
            defer { downloadingModelKeys.remove(key) }
            do {
                try await modelDownloadService.download(descriptor)
                cacheStatuses = ModelCacheInspector.statuses(for: uniqueModels)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    private func moveModelToTrash(_ descriptor: ModelDescriptor) {
        guard let url = ModelCacheInspector.location(for: descriptor),
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        NSWorkspace.shared.recycle([url]) { _, error in
            Task { @MainActor in
                if let error {
                    loadError = error.localizedDescription
                } else {
                    cacheStatuses = ModelCacheInspector.statuses(for: uniqueModels)
                }
            }
        }
    }
}

enum ModelRegistry {
    static let localPostprocessModelSelection = [
        LocalPostprocessBackend.pinnedModel.hfModelID,
        LocalPostprocessBackend.pinnedModel.revision,
        LocalPostprocessBackend.pinnedModel.quantization,
    ].joined(separator: "@")

    static func descriptors(in profiles: [AppProfile]) -> [ModelDescriptor] {
        var descriptors: [String: ModelDescriptor] = [:]
        for profile in profiles {
            for descriptor in profile.models {
                descriptors[key(for: descriptor)] = descriptor
            }
        }
        descriptors[key(for: LocalPostprocessBackend.pinnedModel)] = LocalPostprocessBackend.pinnedModel
        return descriptors.values.sorted { key(for: $0) < key(for: $1) }
    }

    static func key(for descriptor: ModelDescriptor) -> String {
        "\(descriptor.hfModelID)@\(descriptor.revision)@\(descriptor.quantization)"
    }

    static func isLocalPostprocessModel(_ descriptor: ModelDescriptor) -> Bool {
        descriptor == LocalPostprocessBackend.pinnedModel
    }
}

private struct CodexStatusLabel: View {
    let availability: CodexAvailability?

    var body: some View {
        HStack(spacing: 6) {
            switch availability {
            case .none:
                ProgressView()
                    .controlSize(.small)
                Text(appLocalized("Checking availability…"))
                    .foregroundStyle(.secondary)
            case .some(let availability):
                Image(systemName: statusSymbol(availability))
                    .foregroundStyle(statusColor(availability))
                    .accessibilityHidden(true)
                if availability.isAuthenticated {
                    Text(appLocalized("Installed and signed in"))
                } else if availability.authenticationCheckFailed {
                    Text(appLocalized("Installed, but sign-in status could not be checked."))
                } else if availability.isInstalled {
                    Text(appLocalized("Installed, not signed in. Run codex login in Terminal."))
                } else {
                    Text(appLocalized("Not Installed"))
                }
                if availability.isInstalled {
                    Text(verbatim: availability.version)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func statusSymbol(_ availability: CodexAvailability) -> String {
        if availability.isAuthenticated { return "checkmark.circle.fill" }
        return availability.isInstalled ? "exclamationmark.triangle.fill" : "xmark.circle"
    }

    private func statusColor(_ availability: CodexAvailability) -> Color {
        if availability.isAuthenticated { return .green }
        return availability.isInstalled ? .orange : .secondary
    }
}

private struct ConfiguredModel {
    let key: String
    let descriptor: ModelDescriptor
    var languages: Set<String>
    var metrics: [BenchmarkMetric]
}

private struct ModelCacheStatus: Equatable {
    var installed: Bool
    var sizeBytes: Int64?

    static let missing = ModelCacheStatus(installed: false, sizeBytes: nil)
}

private enum ModelCacheInspector {
    static let cacheRoot = ModelDownloadPlan.defaultCacheRoot

    static func statuses(for models: [ConfiguredModel]) -> [String: ModelCacheStatus] {
        Dictionary(uniqueKeysWithValues: models.map { model in
            let location = location(for: model.descriptor)
            let installed = location.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            return (model.key, ModelCacheStatus(
                installed: installed,
                sizeBytes: installed ? location.flatMap(directorySize) : nil
            ))
        })
    }

    static func location(for descriptor: ModelDescriptor) -> URL? {
        if ModelRegistry.isLocalPostprocessModel(descriptor) {
            return LocalPostprocessRuntime.local.modelSnapshotURL
        }
        return ModelDownloadPlan(model: descriptor, cacheRoot: cacheRoot).pinnedLocation
    }

    private static func directorySize(_ url: URL) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

private struct ModelRegistryCard: View {
    let model: ModelDescriptor
    let languages: Set<String>
    let metrics: [BenchmarkMetric]
    let status: ModelCacheStatus
    let isDownloading: Bool
    let reveal: () -> Void
    let download: () -> Void
    let moveToTrash: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.hfModelID)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text(model.role.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    status.installed ? appLocalized("Installed") : appLocalized("Not Installed"),
                    systemImage: status.installed ? "checkmark.circle.fill" : "arrow.down.circle"
                )
                    .foregroundStyle(status.installed ? Color.green : Color.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    Text(appLocalized("Revision")).foregroundStyle(.secondary)
                    Text(model.revision).font(.caption.monospaced()).textSelection(.enabled)
                }
                GridRow {
                    Text(appLocalized("Quantization")).foregroundStyle(.secondary)
                    Text(model.quantization)
                }
                GridRow {
                    Text(appLocalized("Languages")).foregroundStyle(.secondary)
                    Text(languages.sorted().formatted())
                }
                if let bytes = status.sizeBytes {
                    GridRow {
                        Text(appLocalized("Disk Use")).foregroundStyle(.secondary)
                        Text(ByteCountFormatStyle(style: .file).format(bytes))
                    }
                }
            }
            .font(.caption)

            if !metrics.isEmpty {
                ViewThatFits {
                    HStack(spacing: 5) { metricChips }
                    VStack(alignment: .leading, spacing: 4) { metricChips }
                }
            }

            HStack {
                if status.installed {
                    Button(appLocalized("Reveal in Finder"), action: reveal)
                    Button(appLocalized("Move Model to Trash"), role: .destructive, action: moveToTrash)
                } else {
                    Button(appLocalized("Download Pinned Model"), action: download)
                    if isDownloading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Spacer()
            }
            .disabled(isDownloading)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder private var metricChips: some View {
        ForEach(metrics) { metric in
            BenchmarkChip(metric: metric)
        }
    }
}

private struct StoragePathRow: View {
    let title: LocalizedStringResource
    let url: URL

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(url.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button(appLocalized("Reveal"), systemImage: "folder") {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .labelStyle(.iconOnly)
            }
        }
    }
}

private struct StorageDirectoryControl: View {
    let title: LocalizedStringResource
    let selectedURL: URL
    let isEditable: Bool
    let choose: () -> Void
    let useDefault: () -> Void

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 6) {
                Text(selectedURL.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button(appLocalized("Choose Folder…"), action: choose)
                    Button(appLocalized("Use Default"), action: useDefault)
                }
                .disabled(!isEditable)
            }
        }
    }
}
