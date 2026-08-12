import Foundation
import MaccheroniASR
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

    public init(
        root: URL,
        recordingsURL: URL,
        runsURL: URL,
        recordingsBookmark: Data? = nil,
        runsBookmark: Data? = nil
    ) {
        self.root = root.standardizedFileURL
        self.recordingsURL = recordingsURL.standardizedFileURL
        self.runsURL = runsURL.standardizedFileURL
        self.recordingsBookmark = recordingsBookmark
        self.runsBookmark = runsBookmark
    }

    public init(
        applicationSupportDirectory: URL,
        environment: [String: String],
        preferences: LibraryStoragePreferences
    ) {
        let defaultRoot = Self.defaultLibraryRoot(
            applicationSupportDirectory: applicationSupportDirectory
        )
        if let override = Self.normalizedDirectoryURL(
            storedPath: environment[StoragePreferenceKeys.libraryRootEnvironment]
        ) {
            root = override
            recordingsURL = override.appendingPathComponent("Recordings", isDirectory: true)
            runsURL = override.appendingPathComponent("Runs", isDirectory: true)
            recordingsBookmark = nil
            runsBookmark = nil
        } else {
            root = defaultRoot
            recordingsURL = Self.normalizedDirectoryURL(storedPath: preferences.recordingsPath)
                ?? defaultRoot.appendingPathComponent("Recordings", isDirectory: true)
            runsURL = Self.normalizedDirectoryURL(storedPath: preferences.runsPath)
                ?? defaultRoot.appendingPathComponent("Runs", isDirectory: true)
            recordingsBookmark = preferences.recordingsBookmark
            runsBookmark = preferences.runsBookmark
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
        guard let storedPath,
              !storedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (storedPath as NSString).isAbsolutePath
        else { return nil }
        return URL(fileURLWithPath: storedPath, isDirectory: true).standardizedFileURL
    }

    public var roots: [StorageRoot] {
        [
            StorageRoot(id: "library.metadata", role: .libraryMetadata, url: root),
            StorageRoot(
                id: "library.requests",
                role: .requestLogs,
                url: root.appendingPathComponent("Requests", isDirectory: true)
            ),
            StorageRoot(
                id: "library.glossaries",
                role: .glossaries,
                url: root.appendingPathComponent("Glossaries", isDirectory: true)
            ),
            StorageRoot(
                id: "library.recordings",
                role: .recordings,
                url: recordingsURL,
                bookmark: recordingsBookmark
            ),
            StorageRoot(
                id: "library.runs",
                role: .runs,
                url: runsURL,
                bookmark: runsBookmark
            ),
        ]
    }
}

public struct ConfiguredStorageProfile: Equatable, Sendable {
    public var diarizationBackend: String?
    public var postprocessBackend: String?

    public init(diarizationBackend: String?, postprocessBackend: String?) {
        self.diarizationBackend = diarizationBackend
        self.postprocessBackend = postprocessBackend
    }
}

public enum StorageRootInventory {
    public static func current(
        library: LibraryStorageConfiguration,
        profile: ConfiguredStorageProfile
    ) -> [StorageRoot] {
        current(library: library, profiles: [profile])
    }

    public static func current(
        library: LibraryStorageConfiguration,
        profiles: [ConfiguredStorageProfile]
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
                roots.append(StorageRoot(
                    id: "models.diarization.community1",
                    role: .diarizationModelCache,
                    url: Community1DiarizerConfiguration.defaultHFHomeURL
                ))
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
        return roots
    }
}
