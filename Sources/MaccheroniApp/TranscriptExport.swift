import Foundation
import MaccheroniCore

enum TranscriptExportError: Error, Equatable, LocalizedError {
    case emptySpeakerName(segmentIndex: Int)
    case emptyText(segmentIndex: Int)
    case invalidSRTTimestamp(segmentIndex: Int)

    var errorDescription: String? {
        switch self {
        case let .emptySpeakerName(segmentIndex):
            appString("The exported speaker name is empty for segment \(segmentIndex + 1).")
        case let .emptyText(segmentIndex):
            appString("The exported text is empty for segment \(segmentIndex + 1).")
        case let .invalidSRTTimestamp(segmentIndex):
            appString("Segment \(segmentIndex + 1) does not have a valid SRT time range.")
        }
    }
}

enum TranscriptExporter {
    static func correctedSegmentsDocument(
        run: LoadedRun,
        record: LibraryRecord
    ) throws -> SegmentsDocument {
        let allowsConflictResolution = !run.isTranslation
        let correctedSegments = try run.transcript.segments.enumerated().map { index, segment in
            let speaker = record.speakerNames[segment.speaker] ?? segment.speaker
            let text = allowsConflictResolution
                ? run.correctionResolution(at: index, record: record) ?? segment.text
                : segment.text
            guard !speaker.isEmpty else {
                throw TranscriptExportError.emptySpeakerName(segmentIndex: index)
            }
            guard !text.isEmpty else {
                throw TranscriptExportError.emptyText(segmentIndex: index)
            }
            return Segment(
                speaker: speaker,
                startS: segment.startS,
                endS: segment.endS,
                text: text,
                language: segment.language,
                confidence: segment.confidence,
                flags: segment.flags
            )
        }
        return SegmentsDocument(
            schemaVersion: run.transcript.schemaVersion,
            segments: correctedSegments,
            numSpeakers: run.transcript.numSpeakers,
            source: run.transcript.source
        )
    }

    static func data(
        format: TranscriptExportFormat,
        run: LoadedRun,
        record: LibraryRecord
    ) throws -> Data {
        switch format {
        case .segmentsJSON:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(correctedSegmentsDocument(run: run, record: record))
        case .markdown:
            return try Data(markdown(run: run, record: record).utf8)
        case .srt:
            return try Data(srt(run: run, record: record).utf8)
        }
    }

    static func markdown(run: LoadedRun, record: LibraryRecord) throws -> String {
        let document = try correctedSegmentsDocument(run: run, record: record)
        let body = document.segments.enumerated().map { index, segment in
            "[\(markdownTimestamp(segment.startS) ?? "Unknown time") – \(markdownTimestamp(segment.endS) ?? "Unknown time")] **\(segment.speaker):** \(segment.text)\(unresolvedMarkers(for: index, run: run, record: record))"
        }.joined(separator: "\n\n")
        return body.isEmpty ? "" : body + "\n"
    }

    static func srt(run: LoadedRun, record: LibraryRecord) throws -> String {
        let document = try correctedSegmentsDocument(run: run, record: record)
        let entries = try document.segments.enumerated().map { index, segment in
            guard let start = timestampMilliseconds(segment.startS),
                  let end = timestampMilliseconds(segment.endS),
                  end > start
            else {
                throw TranscriptExportError.invalidSRTTimestamp(segmentIndex: index)
            }
            return "\(index + 1)\n\(srtTimestamp(start)) --> \(srtTimestamp(end))\n\(segment.speaker): \(segment.text)\(unresolvedMarkers(for: index, run: run, record: record))"
        }
        return entries.isEmpty ? "" : entries.joined(separator: "\n\n") + "\n"
    }

    static func suggestedFilename(
        format: TranscriptExportFormat,
        record: LibraryRecord
    ) -> String {
        let stem = safeFilenameStem(record.displayName)
        return switch format {
        case .segmentsJSON: "\(stem).segments.json"
        case .markdown: "\(stem).md"
        case .srt: "\(stem).srt"
        }
    }
}

private extension TranscriptExporter {
    static func unresolvedMarkers(for segmentIndex: Int, run: LoadedRun, record: LibraryRecord) -> String {
        let allowsConflictResolution = !run.isTranslation
        let hasResolution: Bool
        if allowsConflictResolution {
            hasResolution = run.correctionResolution(
                at: segmentIndex,
                record: record
            ) != nil
        } else {
            hasResolution = run.transcript.segments.indices.contains(segmentIndex)
                && run.isTranslationAcknowledged(
                    at: segmentIndex,
                    text: run.transcript.segments[segmentIndex].text,
                    record: record
                )
        }
        let hasUnresolvedConflict = run.conflicts.contains { conflict in
            conflict.segmentIndex == segmentIndex
        } && !hasResolution
        let hasUnresolvedUncertainty = run.transcript.segments[segmentIndex].flags?.contains { flag in
            flag.localizedCaseInsensitiveContains("uncertain")
        } == true && !hasResolution

        var markers: [String] = []
        if hasUnresolvedConflict {
            markers.append("[CONFLICT]")
        }
        if hasUnresolvedUncertainty {
            markers.append("[UNCERTAIN]")
        }
        return markers.isEmpty ? "" : " " + markers.joined(separator: " ")
    }

    static func markdownTimestamp(_ seconds: Double) -> String? {
        guard let milliseconds = timestampMilliseconds(seconds) else { return nil }
        return timestamp(milliseconds, separator: ".")
    }

    static func timestampMilliseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0,
              seconds <= Double(Int64.max) / 1_000
        else { return nil }
        return Int64((seconds * 1_000).rounded())
    }

    static func srtTimestamp(_ milliseconds: Int64) -> String {
        timestamp(milliseconds, separator: ",")
    }

    static func timestamp(_ milliseconds: Int64, separator: String) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let secondsPart = (milliseconds % 60_000) / 1_000
        let millisecondsPart = milliseconds % 1_000
        return String(format: "%02lld:%02lld:%02lld.%03lld", hours, minutes, secondsPart, millisecondsPart)
            .replacingOccurrences(of: ".", with: separator)
    }

    static func safeFilenameStem(_ displayName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\u{0}")
        let replaced = displayName.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
        let trimmed = replaced.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Transcript" : trimmed
    }
}
