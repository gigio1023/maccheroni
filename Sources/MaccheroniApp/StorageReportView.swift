import MaccheroniStorage
import SwiftUI

extension StorageRole {
    static let modelCacheRoles: Set<Self> = [
        .asrModelCache,
        .vadModelCache,
        .diarizationModelCache,
        .postprocessModelCache,
    ]
}

struct StorageVolumePresentation: Equatable, Identifiable {
    var id: String
    var name: String
    var roles: [StorageRole]
    var availableBytes: Int64?
}

struct StorageIssuePresentation: Equatable, Identifiable {
    var id: String
    var role: StorageRole
    var status: StorageRootStatus
    var bookmarkStatus: StorageBookmarkStatus
}

struct StorageReportPresentation: Equatable {
    var volumes: [StorageVolumePresentation]
    var issues: [StorageIssuePresentation]

    init(report: StorageReport, roles allowedRoles: Set<StorageRole>? = nil) {
        volumes = report.volumes.compactMap { volume in
            let roles = volume.roles.filter { allowedRoles?.contains($0) ?? true }
            guard !roles.isEmpty else { return nil }
            return StorageVolumePresentation(
                id: volume.id,
                name: volume.name,
                roles: roles,
                availableBytes: volume.availableBytes
            )
        }
        issues = report.roots.compactMap { root in
            guard allowedRoles?.contains(root.role) ?? true,
                  root.status != .available || root.bookmarkStatus == .stale
                    || root.bookmarkStatus == .unavailable
            else { return nil }
            return StorageIssuePresentation(
                id: root.id,
                role: root.role,
                status: root.status,
                bookmarkStatus: root.bookmarkStatus
            )
        }
    }
}

func storageVolumeName(volumeID: String, in report: StorageReport) -> String? {
    report.volumes.first(where: { $0.id == volumeID })?.name
}

struct StorageVolumeReportView: View {
    let presentation: StorageReportPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(presentation.volumes) { volume in
                StorageVolumeRow(volume: volume)
            }
            ForEach(presentation.issues) { issue in
                StorageIssueRow(issue: issue)
            }
        }
    }
}

private struct StorageVolumeRow: View {
    let volume: StorageVolumePresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume.name)
                    .font(.headline)
                    .textSelection(.enabled)
                Spacer()
                LabeledContent(appLocalized("Free Space")) {
                    if let bytes = volume.availableBytes {
                        Text(ByteCountFormatStyle(style: .file).format(bytes))
                    } else {
                        Text(appLocalized("Unavailable"))
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
            }
            Text(localizedRoles(volume.roles))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct StorageIssueRow: View {
    let issue: StorageIssuePresentation

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(storageRoleTitle(issue.role))
                Text(issue.id)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(storageIssueTitle(issue.status))
                .foregroundStyle(.secondary)
            if issue.bookmarkStatus == .stale {
                Text(appLocalized("Stale Bookmark"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

func storageRoleTitle(_ role: StorageRole) -> String {
    switch role {
    case .recordings: appString("Recordings")
    case .runs: appString("Run Output")
    case .libraryMetadata: appString("Library Metadata")
    case .requestLogs: appString("Request Logs")
    case .glossaries: appString("Glossaries")
    case .asrModelCache: appString("ASR Model Cache")
    case .vadModelCache: appString("VAD Model Cache")
    case .diarizationModelCache: appString("Diarization Model Cache")
    case .postprocessModelCache: appString("Post-processing Model Cache")
    case .temporaryWork: appString("Temporary Work")
    }
}

private func storageIssueTitle(_ status: StorageRootStatus) -> String {
    switch status {
    case .available: appString("Available")
    case .notCreated: appString("Not Created")
    case .unmounted: appString("Unmounted")
    case .unreadable: appString("Unreadable")
    case .bookmarkUnavailable: appString("Bookmark Unavailable")
    }
}

private func localizedRoles(_ roles: [StorageRole]) -> String {
    roles.map(storageRoleTitle).joined(separator: ", ")
}
