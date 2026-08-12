import CryptoKit
import Foundation

public enum StorageRole: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case recordings
    case runs
    case libraryMetadata = "library_metadata"
    case requestLogs = "request_logs"
    case glossaries
    case asrModelCache = "asr_model_cache"
    case vadModelCache = "vad_model_cache"
    case diarizationModelCache = "diarization_model_cache"
    case postprocessModelCache = "postprocess_model_cache"
    case temporaryWork = "temporary_work"

    fileprivate var order: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

public struct StorageRoot: Equatable, Sendable {
    public var id: String
    public var role: StorageRole
    public var url: URL
    public var bookmark: Data?
    public var kind: StorageRootKind

    public init(
        id: String,
        role: StorageRole,
        url: URL,
        bookmark: Data? = nil,
        kind: StorageRootKind = .directory
    ) {
        self.id = id
        self.role = role
        self.url = url.standardizedFileURL
        self.bookmark = bookmark
        self.kind = kind
    }
}

public enum StorageRootKind: Equatable, Sendable {
    case directory
    case file
}

public enum StorageRootStatus: String, Codable, Equatable, Error, Sendable {
    case available
    case notCreated = "not_created"
    case unmounted
    case unreadable
    case bookmarkUnavailable = "bookmark_unavailable"
}

public enum StorageBookmarkStatus: String, Codable, Equatable, Sendable {
    case none
    case current
    case stale
    case unavailable
}

public struct StorageRootObservation: Codable, Equatable, Sendable {
    public var id: String
    public var role: StorageRole
    public var status: StorageRootStatus
    public var bookmarkStatus: StorageBookmarkStatus
    public var volumeID: String?

    public init(
        id: String,
        role: StorageRole,
        status: StorageRootStatus,
        bookmarkStatus: StorageBookmarkStatus,
        volumeID: String?
    ) {
        self.id = id
        self.role = role
        self.status = status
        self.bookmarkStatus = bookmarkStatus
        self.volumeID = volumeID
    }

    enum CodingKeys: String, CodingKey {
        case id, role, status
        case bookmarkStatus = "bookmark_status"
        case volumeID = "volume_id"
    }
}

public enum StorageCapacityStatus: String, Codable, Equatable, Sendable {
    case available
    case unavailable
}

public struct StorageVolume: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var roles: [StorageRole]
    public var availableBytes: Int64?

    public var capacityStatus: StorageCapacityStatus {
        availableBytes == nil ? .unavailable : .available
    }

    public init(
        id: String,
        name: String,
        roles: [StorageRole],
        availableBytes: Int64?
    ) {
        self.id = id
        self.name = name
        self.roles = roles.sorted { $0.order < $1.order }
        self.availableBytes = availableBytes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, roles
        case availableBytes = "available_bytes"
        case capacityStatus = "capacity_status"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(roles, forKey: .roles)
        if let availableBytes {
            try container.encode(availableBytes, forKey: .availableBytes)
        } else {
            try container.encodeNil(forKey: .availableBytes)
        }
        try container.encode(capacityStatus, forKey: .capacityStatus)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        roles = try container.decode([StorageRole].self, forKey: .roles)
        availableBytes = try container.decodeIfPresent(Int64.self, forKey: .availableBytes)
    }
}

public struct StorageReport: Codable, Equatable, Sendable {
    public var volumes: [StorageVolume]
    public var roots: [StorageRootObservation]
    public var isObservable: Bool

    public init(volumes: [StorageVolume], roots: [StorageRootObservation]) {
        self.volumes = volumes
        self.roots = roots
        isObservable = roots.allSatisfy {
            $0.status == .available || $0.status == .notCreated
        } && volumes.allSatisfy { $0.availableBytes != nil }
    }

    public static let empty = StorageReport(volumes: [], roots: [])

    enum CodingKeys: String, CodingKey {
        case volumes, roots
        case isObservable = "observable"
    }

    public func textLines() -> [String] {
        var lines = [
            "storage.observable=\(isObservable)",
            "storage.volume_count=\(volumes.count)",
        ]
        for (index, volume) in volumes.enumerated() {
            let prefix = "storage.volume.\(index)"
            lines += [
                "\(prefix).id=\(textValue(volume.id))",
                "\(prefix).name=\(textValue(volume.name))",
                "\(prefix).roles=\(volume.roles.map(\.rawValue).joined(separator: ","))",
                "\(prefix).available_bytes=\(volume.availableBytes.map(String.init) ?? "unavailable")",
                "\(prefix).capacity_status=\(volume.capacityStatus.rawValue)",
            ]
        }
        lines.append("storage.root_count=\(roots.count)")
        for (index, root) in roots.enumerated() {
            let prefix = "storage.root.\(index)"
            lines += [
                "\(prefix).id=\(textValue(root.id))",
                "\(prefix).role=\(root.role.rawValue)",
                "\(prefix).status=\(root.status.rawValue)",
                "\(prefix).bookmark_status=\(root.bookmarkStatus.rawValue)",
                "\(prefix).volume_id=\(root.volumeID.map(textValue) ?? "unavailable")",
            ]
        }
        return lines
    }
}

public struct StorageVolumeProperties: Equatable, Sendable {
    public var groupingIdentifier: String
    public var id: String
    public var name: String
    public var availableBytes: Int64?
    public var isDirectory: Bool
    public var isReadable: Bool
    fileprivate var groupKey: StorageVolumeGroupKey

    public init(
        groupingIdentifier: String,
        id: String,
        name: String,
        availableBytes: Int64?,
        isDirectory: Bool = true,
        isReadable: Bool = true
    ) {
        self.groupingIdentifier = groupingIdentifier
        self.id = id
        self.name = name
        self.availableBytes = availableBytes
        self.isDirectory = isDirectory
        self.isReadable = isReadable
        groupKey = StorageVolumeGroupKey(text: groupingIdentifier)
    }

    fileprivate init(
        volumeIdentifier: NSObject,
        id: String,
        name: String,
        availableBytes: Int64?,
        isDirectory: Bool,
        isReadable: Bool
    ) {
        groupingIdentifier = String(describing: volumeIdentifier)
        self.id = id
        self.name = name
        self.availableBytes = availableBytes
        self.isDirectory = isDirectory
        self.isReadable = isReadable
        groupKey = StorageVolumeGroupKey(object: volumeIdentifier)
    }
}

private struct StorageVolumeGroupKey: Hashable, @unchecked Sendable {
    private var text: String?
    private var object: NSObject?

    init(text: String) {
        self.text = text
        object = nil
    }

    init(object: NSObject) {
        text = nil
        self.object = object
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.object, rhs.object) {
        case (let left?, let right?): left.isEqual(right)
        case (nil, nil): lhs.text == rhs.text
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        if let object {
            hasher.combine(0)
            hasher.combine(object.hash)
        } else {
            hasher.combine(1)
            hasher.combine(text)
        }
    }
}

public enum StorageInspectionFailure: Error, Equatable, Sendable {
    case notFound
    case unreadable
}

public struct StorageVolumeInspector: Sendable {
    public var inspect: @Sendable (URL) throws -> StorageVolumeProperties

    public init(_ inspect: @escaping @Sendable (URL) throws -> StorageVolumeProperties) {
        self.inspect = inspect
    }

    public static let system = StorageVolumeInspector { url in
        do {
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey,
                .isReadableKey,
                .volumeIdentifierKey,
                .volumeUUIDStringKey,
                .volumeLocalizedNameKey,
                .volumeNameKey,
                .volumeURLKey,
                .volumeAvailableCapacityKey,
            ]
            let values = try url.resourceValues(forKeys: keys)
            guard let identifier = values.volumeIdentifier as? NSObject else {
                throw StorageInspectionFailure.unreadable
            }
            let groupingIdentifier = String(describing: identifier)
            let id = values.volumeUUIDString.map { "volume-\($0.lowercased())" }
                ?? opaqueVolumeID(groupingIdentifier)
            let volumeURL = values.volume
            let name = values.volumeLocalizedName
                ?? values.volumeName
                ?? volumeURL.flatMap(humanVolumeFallback)
                ?? id
            return StorageVolumeProperties(
                volumeIdentifier: identifier,
                id: id,
                name: name,
                availableBytes: values.volumeAvailableCapacity.map(Int64.init),
                isDirectory: values.isDirectory == true,
                isReadable: values.isReadable == true
            )
        } catch let failure as StorageInspectionFailure {
            throw failure
        } catch {
            throw classifyInspectionError(error)
        }
    }
}

public struct StorageBookmarkResolution: Equatable, Sendable {
    public var url: URL
    public var isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }
}

public enum StorageBookmarkError: Error, Equatable, Sendable {
    case unavailable
}

public struct StorageBookmarkAccess: Sendable {
    public var resolve: @Sendable (Data) throws -> StorageBookmarkResolution
    public var startAccessing: @Sendable (URL) -> Bool
    public var stopAccessing: @Sendable (URL) -> Void

    public init(
        resolve: @escaping @Sendable (Data) throws -> StorageBookmarkResolution,
        startAccessing: @escaping @Sendable (URL) -> Bool,
        stopAccessing: @escaping @Sendable (URL) -> Void
    ) {
        self.resolve = resolve
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }

    public static let system = StorageBookmarkAccess(
        resolve: { data in
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope, .withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                return StorageBookmarkResolution(url: url, isStale: isStale)
            } catch {
                throw StorageBookmarkError.unavailable
            }
        },
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

public struct StorageReadinessReporter: Sendable {
    public var inspector: StorageVolumeInspector
    public var bookmarks: StorageBookmarkAccess

    public init(
        inspector: StorageVolumeInspector = .system,
        bookmarks: StorageBookmarkAccess = .system
    ) {
        self.inspector = inspector
        self.bookmarks = bookmarks
    }

    public func report(roots: [StorageRoot]) -> StorageReport {
        var volumesByGroup: [StorageVolumeGroupKey: StorageVolume] = [:]
        var observations: [StorageRootObservation] = []
        var usedVolumeIDs: Set<String> = []

        for root in roots.sorted(by: { $0.id < $1.id }) {
            let resolved: URL
            let bookmarkStatus: StorageBookmarkStatus
            if let bookmark = root.bookmark {
                do {
                    let resolution = try bookmarks.resolve(bookmark)
                    resolved = resolution.url.standardizedFileURL
                    bookmarkStatus = resolution.isStale ? .stale : .current
                } catch {
                    observations.append(StorageRootObservation(
                        id: root.id,
                        role: root.role,
                        status: .bookmarkUnavailable,
                        bookmarkStatus: .unavailable,
                        volumeID: nil
                    ))
                    continue
                }
            } else {
                resolved = root.url
                bookmarkStatus = .none
            }

            let isAccessing = root.bookmark.map { _ in
                bookmarks.startAccessing(resolved)
            } ?? false
            defer {
                if isAccessing { bookmarks.stopAccessing(resolved) }
            }

            let result = inspectRoot(resolved, kind: root.kind)
            switch result {
            case .success((let properties, let status)):
                var volume: StorageVolume
                if let existing = volumesByGroup[properties.groupKey] {
                    volume = existing
                    if volume.availableBytes == nil {
                        volume.availableBytes = properties.availableBytes
                    }
                } else {
                    let id = disambiguatedVolumeID(
                        properties.id,
                        usedIDs: &usedVolumeIDs
                    )
                    volume = StorageVolume(
                        id: id,
                        name: properties.name,
                        roles: [],
                        availableBytes: properties.availableBytes
                    )
                }
                if !volume.roles.contains(root.role) {
                    volume.roles.append(root.role)
                    volume.roles.sort { $0.order < $1.order }
                }
                volumesByGroup[properties.groupKey] = volume
                observations.append(StorageRootObservation(
                    id: root.id,
                    role: root.role,
                    status: status,
                    bookmarkStatus: bookmarkStatus,
                    volumeID: volume.id
                ))
            case .failure(let status):
                observations.append(StorageRootObservation(
                    id: root.id,
                    role: root.role,
                    status: status,
                    bookmarkStatus: bookmarkStatus,
                    volumeID: nil
                ))
            }
        }

        let volumes = volumesByGroup.values.sorted {
            let leftRole = $0.roles.first?.order ?? StorageRole.allCases.count
            let rightRole = $1.roles.first?.order ?? StorageRole.allCases.count
            if leftRole != rightRole { return leftRole < rightRole }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
        return StorageReport(volumes: volumes, roots: observations)
    }

    private func inspectRoot(
        _ url: URL,
        kind: StorageRootKind
    ) -> Result<(StorageVolumeProperties, StorageRootStatus), StorageRootStatus> {
        do {
            let properties = try inspector.inspect(url)
            guard properties.isReadable,
                  kind == .file || properties.isDirectory
            else { return .failure(.unreadable) }
            return .success((properties, .available))
        } catch StorageInspectionFailure.unreadable {
            return .failure(.unreadable)
        } catch StorageInspectionFailure.notFound {
            return inspectMissingRoot(url)
        } catch {
            return .failure(.unreadable)
        }
    }

    private func inspectMissingRoot(
        _ url: URL
    ) -> Result<(StorageVolumeProperties, StorageRootStatus), StorageRootStatus> {
        let externalMount = externalMountRoot(for: url)
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if let externalMount, candidate.path == externalMount.path {
                do {
                    let properties = try inspector.inspect(candidate)
                    guard properties.isDirectory, properties.isReadable else {
                        return .failure(.unreadable)
                    }
                    return .success((properties, .notCreated))
                } catch StorageInspectionFailure.notFound {
                    return .failure(.unmounted)
                } catch {
                    return .failure(.unreadable)
                }
            }
            candidate.deleteLastPathComponent()
            do {
                let properties = try inspector.inspect(candidate)
                guard properties.isDirectory, properties.isReadable else {
                    return .failure(.unreadable)
                }
                return .success((properties, .notCreated))
            } catch StorageInspectionFailure.notFound {
                continue
            } catch {
                return .failure(.unreadable)
            }
        }
        do {
            let properties = try inspector.inspect(candidate)
            guard properties.isDirectory, properties.isReadable else {
                return .failure(.unreadable)
            }
            return .success((properties, .notCreated))
        } catch {
            return .failure(.unreadable)
        }
    }
}

private func externalMountRoot(for url: URL) -> URL? {
    let components = url.standardizedFileURL.pathComponents
    guard components.count >= 3,
          components[0] == "/",
          components[1] == "Volumes"
    else { return nil }
    return URL(fileURLWithPath: "/Volumes", isDirectory: true)
        .appendingPathComponent(components[2], isDirectory: true)
}

private func classifyInspectionError(_ error: Error) -> StorageInspectionFailure {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
        switch CocoaError.Code(rawValue: nsError.code) {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return .notFound
        case .fileReadNoPermission, .fileWriteNoPermission:
            return .unreadable
        default:
            break
        }
    }
    if nsError.domain == NSPOSIXErrorDomain {
        switch POSIXErrorCode(rawValue: Int32(nsError.code)) {
        case .ENOENT:
            return .notFound
        case .EACCES, .EPERM:
            return .unreadable
        default:
            break
        }
    }
    return .unreadable
}

private func opaqueVolumeID(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return "volume-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

private func disambiguatedVolumeID(
    _ proposedID: String,
    usedIDs: inout Set<String>
) -> String {
    var candidate = proposedID
    var suffix = 2
    while usedIDs.contains(candidate) {
        candidate = "\(proposedID)-\(suffix)"
        suffix += 1
    }
    usedIDs.insert(candidate)
    return candidate
}

private func humanVolumeFallback(_ url: URL) -> String? {
    if url.path == "/" { return nil }
    return url.lastPathComponent.isEmpty ? nil : url.lastPathComponent
}

private func textValue(_ value: String) -> String {
    value.replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}
