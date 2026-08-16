import Foundation
import MaccheroniASR
import MaccheroniCore
import MaccheroniDiarize
import MaccheroniPostprocess
import MaccheroniPreprocess

public enum StoragePreferenceKeys {
    public static let recordingsDirectory = "maccheroni.storage.recordingsDirectory"
    public static let runsDirectory = "maccheroni.storage.runsDirectory"
    public static let recordingsBookmark = "maccheroni.storage.recordingsBookmark"
    public static let runsBookmark = "maccheroni.storage.runsBookmark"
    public static let libraryRootEnvironment = "MACCHERONI_LIBRARY_ROOT"
    public static let appBundleIdentifier = "com.gigio.maccheroni"
}

public struct LibraryStoragePreferences: Equatable, Sendable {
    public var recordingsPath: String?
    public var runsPath: String?
    public var recordingsBookmark: Data?
    public var runsBookmark: Data?

    public init(
        recordingsPath: String? = nil,
        runsPath: String? = nil,
        recordingsBookmark: Data? = nil,
        runsBookmark: Data? = nil
    ) {
        self.recordingsPath = recordingsPath
        self.runsPath = runsPath
        self.recordingsBookmark = recordingsBookmark
        self.runsBookmark = runsBookmark
    }

    public init(defaults: UserDefaults) {
        self.init(
            recordingsPath: defaults.string(forKey: StoragePreferenceKeys.recordingsDirectory),
            runsPath: defaults.string(forKey: StoragePreferenceKeys.runsDirectory),
            recordingsBookmark: defaults.data(forKey: StoragePreferenceKeys.recordingsBookmark),
            runsBookmark: defaults.data(forKey: StoragePreferenceKeys.runsBookmark)
        )
    }

    public static func appDomain() -> LibraryStoragePreferences {
        let defaults = UserDefaults(suiteName: StoragePreferenceKeys.appBundleIdentifier)
            ?? .standard
        return LibraryStoragePreferences(defaults: defaults)
    }
}

public struct LibraryStorageConfiguration: Equatable, Sendable {
    public var root: URL
    public var recordingsURL: URL
    public var runsURL: URL
    public var recordingsBookmark: Data?
    public var runsBookmark: Data?
    public var invalidRootIDs: Set<String>

    public init(
        root: URL,
        recordingsURL: URL,
        runsURL: URL,
        recordingsBookmark: Data? = nil,
        runsBookmark: Data? = nil,
        invalidRootIDs: Set<String> = []
    ) {
        self.root = root.standardizedFileURL
        self.recordingsURL = recordingsURL.standardizedFileURL
        self.runsURL = runsURL.standardizedFileURL
        self.recordingsBookmark = recordingsBookmark
        self.runsBookmark = runsBookmark
        self.invalidRootIDs = invalidRootIDs
    }

    public init(
        applicationSupportDirectory: URL,
        environment: [String: String],
        preferences: LibraryStoragePreferences
    ) {
        let defaultRoot = Self.defaultLibraryRoot(
            applicationSupportDirectory: applicationSupportDirectory
        )
        invalidRootIDs = []
        if let storedRoot = environment[StoragePreferenceKeys.libraryRootEnvironment] {
            switch Self.directoryResolution(storedPath: storedRoot) {
            case .valid(let override):
                root = override
                recordingsURL = override.appendingPathComponent("Recordings", isDirectory: true)
                runsURL = override.appendingPathComponent("Runs", isDirectory: true)
            case .absent, .invalid:
                root = defaultRoot
                recordingsURL = defaultRoot.appendingPathComponent("Recordings", isDirectory: true)
                runsURL = defaultRoot.appendingPathComponent("Runs", isDirectory: true)
                invalidRootIDs = Set(Self.libraryRootIDs)
            }
            recordingsBookmark = nil
            runsBookmark = nil
        } else {
            root = defaultRoot
            switch Self.directoryResolution(storedPath: preferences.recordingsPath) {
            case .valid(let url):
                recordingsURL = url
                recordingsBookmark = preferences.recordingsBookmark
            case .absent:
                recordingsURL = defaultRoot.appendingPathComponent("Recordings", isDirectory: true)
                recordingsBookmark = preferences.recordingsBookmark
            case .invalid:
                recordingsURL = defaultRoot.appendingPathComponent("Recordings", isDirectory: true)
                recordingsBookmark = nil
                invalidRootIDs.insert("library.recordings")
            }
            switch Self.directoryResolution(storedPath: preferences.runsPath) {
            case .valid(let url):
                runsURL = url
                runsBookmark = preferences.runsBookmark
            case .absent:
                runsURL = defaultRoot.appendingPathComponent("Runs", isDirectory: true)
                runsBookmark = preferences.runsBookmark
            case .invalid:
                runsURL = defaultRoot.appendingPathComponent("Runs", isDirectory: true)
                runsBookmark = nil
                invalidRootIDs.insert("library.runs")
            }
        }
    }

    public static func defaultLibraryRoot(
        applicationSupportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Maccheroni", isDirectory: true)
            .standardizedFileURL
    }

    public static func normalizedDirectoryURL(storedPath: String?) -> URL? {
        guard case .valid(let url) = directoryResolution(storedPath: storedPath)
        else { return nil }
        return url
    }

    public func isRootConfigurationValid(_ id: String) -> Bool {
        !invalidRootIDs.contains(id)
    }

    public var roots: [StorageRoot] {
        [
            configuredRoot(id: "library.metadata", role: .libraryMetadata, url: root),
            configuredRoot(
                id: "library.requests",
                role: .requestLogs,
                url: root.appendingPathComponent("Requests", isDirectory: true)
            ),
            configuredRoot(
                id: "library.glossaries",
                role: .glossaries,
                url: root.appendingPathComponent("Glossaries", isDirectory: true)
            ),
            configuredRoot(
                id: "library.recordings",
                role: .recordings,
                url: recordingsURL,
                bookmark: recordingsBookmark
            ),
            configuredRoot(
                id: "library.runs",
                role: .runs,
                url: runsURL,
                bookmark: runsBookmark
            ),
        ]
    }

    private static let libraryRootIDs = [
        "library.metadata",
        "library.requests",
        "library.glossaries",
        "library.recordings",
        "library.runs",
    ]

    private enum DirectoryResolution {
        case absent
        case valid(URL)
        case invalid
    }

    private static func directoryResolution(storedPath: String?) -> DirectoryResolution {
        guard let storedPath else { return .absent }
        guard !storedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (storedPath as NSString).isAbsolutePath
        else { return .invalid }
        return .valid(
            URL(fileURLWithPath: storedPath, isDirectory: true).standardizedFileURL
        )
    }

    private func configuredRoot(
        id: String,
        role: StorageRole,
        url: URL,
        bookmark: Data? = nil
    ) -> StorageRoot {
        StorageRoot(
            id: id,
            role: role,
            url: url,
            bookmark: bookmark,
            preflightStatus: invalidRootIDs.contains(id) ? .unreadable : nil
        )
    }
}

public struct ConfiguredStorageProfile: Equatable, Sendable {
    public var diarizationBackend: String?
    public var postprocessBackend: String?
    public var models: [ModelDescriptor]

    public init(
        diarizationBackend: String?,
        postprocessBackend: String?,
        models: [ModelDescriptor] = []
    ) {
        self.diarizationBackend = diarizationBackend
        self.postprocessBackend = postprocessBackend
        self.models = models
    }
}

public enum StorageModelRoot {
    public static func id(for descriptor: ModelDescriptor) -> String {
        "app.model.\(descriptor.hfModelID)@\(descriptor.revision)@\(descriptor.quantization)"
    }

    public static func role(for descriptor: ModelDescriptor) -> StorageRole? {
        switch descriptor.role {
        case .asr: .asrModelCache
        case .vad: .vadModelCache
        case .diarization: .diarizationModelCache
        case .postprocess: .postprocessModelCache
        case .alignment, .enhancement: nil
        }
    }

    public static func location(
        for descriptor: ModelDescriptor,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        if descriptor == LocalPostprocessBackend.pinnedModel {
            return LocalPostprocessRuntime.resolveModelSnapshotURL(
                environment: environment,
                home: homeDirectory
            )
        }
        if descriptor.hfModelID == Community1Diarizer.modelID {
            return Community1DiarizerConfiguration.resolveHFHomeURL(
                environment: environment,
                homeDirectory: homeDirectory
            )
            .appendingPathComponent(
                "hub/models--aufklarer--Pyannote-Community-1-CoreML/snapshots/\(descriptor.revision)",
                isDirectory: true
            )
        }
        if descriptor.hfModelID == FluidAudioDiarizer.modelID {
            return FluidAudioDiarizerConfiguration.defaultModelsRootURL
        }
        if descriptor == SileroVADProvenance().model {
            return SpeechSileroVADAdapter.defaultModelCacheURL()
        }
        guard descriptor.role == .asr else { return nil }
        let cacheRoot = ASRRuntime.resolveCacheRoot(
            environment: environment,
            home: homeDirectory
        )
        if descriptor.hfModelID == SelectedASRBackend.moss.model.hfModelID {
            return cacheRoot.appendingPathComponent(
                "models/moss-transcribe-diarize-0.9b-mlx-int8-\(descriptor.revision)",
                isDirectory: true
            )
        }
        return cacheRoot.appendingPathComponent(
            "models/huggingface/hub/models--\(descriptor.hfModelID.replacingOccurrences(of: "/", with: "--"))/snapshots/\(descriptor.revision)",
            isDirectory: true
        )
    }
}

public enum StorageRootInventory {
    public static func current(
        library: LibraryStorageConfiguration,
        profile: ConfiguredStorageProfile,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [StorageRoot] {
        current(
            library: library,
            profiles: [profile],
            temporaryDirectory: temporaryDirectory
        )
    }

    public static func current(
        library: LibraryStorageConfiguration,
        profiles: [ConfiguredStorageProfile],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> [StorageRoot] {
        var roots = library.roots
        roots.append(StorageRoot(
            id: "models.asr",
            role: .asrModelCache,
            url: ASRRuntime.local.cacheRoot
        ))
        roots += [
            StorageRoot(
                id: "models.vad.data",
                role: .vadModelCache,
                url: SpeechSileroVADAdapter.defaultModelCacheURL()
            ),
            StorageRoot(
                id: "models.vad.revision",
                role: .vadModelCache,
                url: SpeechSileroVADAdapter.defaultRevisionMarkerURL(),
                kind: .file
            ),
        ]
        let diarizationBackends = Set(profiles.compactMap(\.diarizationBackend)).sorted()
        for backend in diarizationBackends {
            switch backend {
            case "community1":
                roots += [
                    StorageRoot(
                        id: "models.diarization.community1",
                        role: .diarizationModelCache,
                        url: Community1DiarizerConfiguration.defaultHFHomeURL
                    ),
                    StorageRoot(
                        id: "work.diarization.community1",
                        role: .temporaryWork,
                        url: DiarizationWorkspace.processCaptureRootURL(
                            temporaryDirectory: temporaryDirectory
                        )
                    ),
                ]
            case "fluid":
                roots += [
                    StorageRoot(
                        id: "models.diarization.fluid",
                        role: .diarizationModelCache,
                        url: FluidAudioDiarizerConfiguration.defaultModelsRootURL
                    ),
                    StorageRoot(
                        id: "work.diarization.fluid",
                        role: .temporaryWork,
                        url: FluidAudioDiarizerConfiguration.defaultOutputRootURL
                    ),
                ]
            default:
                break
            }
        }
        if profiles.contains(where: { $0.postprocessBackend == "local" }) {
            roots.append(StorageRoot(
                id: "models.postprocess.local",
                role: .postprocessModelCache,
                url: LocalPostprocessRuntime.local.modelSnapshotURL
            ))
        }
        let postprocessBackends = Set(profiles.compactMap(\.postprocessBackend))
        if postprocessBackends.contains("codex") {
            roots.append(StorageRoot(
                id: "work.postprocess.codex",
                role: .temporaryWork,
                url: temporaryDirectory
            ))
        }
        if postprocessBackends.contains("local") {
            roots.append(StorageRoot(
                id: "work.postprocess.local",
                role: .temporaryWork,
                url: temporaryDirectory
            ))
        }
        var modelsByID: [String: ModelDescriptor] = [:]
        for descriptor in profiles.flatMap(\.models) {
            modelsByID[StorageModelRoot.id(for: descriptor)] = descriptor
        }
        for (id, descriptor) in modelsByID.sorted(by: { $0.key < $1.key }) {
            guard let role = StorageModelRoot.role(for: descriptor),
                  let url = StorageModelRoot.location(for: descriptor)
            else { continue }
            roots.append(StorageRoot(id: id, role: role, url: url))
        }
        return roots
    }
}
