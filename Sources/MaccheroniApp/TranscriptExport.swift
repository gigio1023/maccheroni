import Foundation
import MaccheroniCore
import MaccheroniPostprocess

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

enum TranscriptDisplayLayer: String, Equatable, Sendable, CaseIterable, Identifiable {
    /// The immutable merged transcript: what the speech model said, joined to
    /// the acoustic speaker timeline. The rest of the tree calls this raw.
    case speakerLabelled = "speaker-labelled"
    case corrected
    case translated
    /// D46's marked non-acoustic speaker proposal, carried by a derived run.
    /// The case exists ahead of its producer so adding the producer changes
    /// only `TranscriptLayerCatalog.options`, not the switching around it.
    case proposed

    var id: String { rawValue }

    /// Which layer a loaded result is showing.
    ///
    /// `kind` decides this, never `mode`. A speaker-proposal derived run keeps
    /// `mode == .correction` for a structural reason in the manifest contract,
    /// so reading `mode` would report a proposal run as a corrected transcript
    /// and show text that was never corrected.
    static func displayed(in run: LoadedRun) -> TranscriptDisplayLayer {
        if run.resultOperation?.kind == .speakerProposal {
            // Deliberately not `.proposed`: a non-acoustic proposal is never
            // what a reader is shown first. D46 leaves whether it may ever be
            // the default open, and this is not the place to close it.
            return .speakerLabelled
        }
        let operation = run.resultOperation?.mode ?? run.effectivePostprocess?.mode
        return switch operation {
        case .correction: .corrected
        case .translation: .translated
        case nil: .speakerLabelled
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .speakerLabelled: appLocalized("Speaker-labelled")
        case .corrected: appLocalized("Corrected")
        case .translated: appLocalized("Translated")
        case .proposed: appLocalized("Proposed")
        }
    }

    func copyHeader(locale: Locale? = nil) -> String {
        switch self {
        case .speakerLabelled: appString("Transcript layer: Speaker-labelled", locale: locale)
        case .corrected: appString("Transcript layer: Corrected", locale: locale)
        case .translated: appString("Transcript layer: Translated", locale: locale)
        case .proposed: appString("Transcript layer: Proposed", locale: locale)
        }
    }
}

/// Why a layer this product can produce is not selectable for this run. Kept as
/// data rather than as an absence, because the layer bar states the reason
/// instead of hiding the layer.
enum TranscriptLayerUnavailability: Equatable, Sendable {
    /// This run produced no such result.
    case notProduced
    /// A translation result replaces the source text in the loaded run, so the
    /// source-language transcript is not in memory beside it. This is a
    /// property of how the run is loaded, not of the run on disk: the source
    /// `merged/segments.json` is intact and is re-read whenever the reader
    /// selects a different result.
    case sourceTextNotLoadedWithTranslation
    /// This run has no speaker-proposal derived result.
    case proposalNotYetProduced

    func sentence(locale: Locale? = nil) -> String {
        switch self {
        case .notProduced:
            appString("This run has not produced this layer.", locale: locale)
        case .sourceTextNotLoadedWithTranslation:
            appString(
                "The source-language transcript is not loaded beside a translation. It is unchanged on disk.",
                locale: locale
            )
        case .proposalNotYetProduced:
            appString(
                "A proposed speaker layer would come from a derived run. None has been produced.",
                locale: locale
            )
        }
    }
}

struct TranscriptLayerOption: Equatable, Identifiable, Sendable {
    var layer: TranscriptDisplayLayer
    var unavailability: TranscriptLayerUnavailability?

    var isAvailable: Bool { unavailability == nil }
    var id: String { layer.id }
}

/// Which layers this run can show, and what each layer's text is. Every layer
/// reads from what is already loaded; none of them writes anything.
enum TranscriptLayerCatalog {
    static func options(
        run: LoadedRun,
        record: LibraryRecord,
        proposal: SpeakerProposalDocument? = nil
    ) -> [TranscriptLayerOption] {
        let isTranslation = run.isTranslation
        return TranscriptDisplayLayer.allCases.map { layer in
            TranscriptLayerOption(
                layer: layer,
                unavailability: unavailability(
                    of: layer,
                    run: run,
                    record: record,
                    isTranslation: isTranslation,
                    proposal: proposal
                )
            )
        }
    }

    /// Never `.proposed`. A marked non-acoustic proposal is something a reader
    /// asks to see, not something they are handed, and this plan's scope
    /// leaves whether that can ever change to the maintainer.
    static func defaultLayer(
        run: LoadedRun,
        record: LibraryRecord,
        proposal: SpeakerProposalDocument? = nil
    ) -> TranscriptDisplayLayer {
        let options = options(run: run, record: record, proposal: proposal)
            .filter { $0.layer != .proposed }
        let preferred = TranscriptDisplayLayer.displayed(in: run)
        if options.contains(where: { $0.layer == preferred && $0.isAvailable }) {
            return preferred
        }
        return options.first(where: \.isAvailable)?.layer ?? .speakerLabelled
    }

    /// The text one segment carries in one layer. `speakerLabelled` is the
    /// immutable text and never picks up a correction; that is the whole point
    /// of being able to switch back to it.
    static func text(
        _ layer: TranscriptDisplayLayer,
        for item: TranscriptSegment,
        run: LoadedRun,
        record: LibraryRecord
    ) -> String {
        switch layer {
        case .speakerLabelled, .translated, .proposed:
            item.segment.text
        case .corrected:
            run.correctionResolution(at: item.index, record: record)
                ?? item.segment.text
        }
    }

    private static func unavailability(
        of layer: TranscriptDisplayLayer,
        run: LoadedRun,
        record: LibraryRecord,
        isTranslation: Bool,
        proposal: SpeakerProposalDocument?
    ) -> TranscriptLayerUnavailability? {
        // A speaker proposal changes no text, so `mode` says nothing here and
        // must not be read; see `TranscriptDisplayLayer.displayed(in:)`.
        let isTextResult = run.resultOperation.map {
            $0.kind == .textPostprocess
        } ?? true
        switch layer {
        case .speakerLabelled:
            return isTranslation ? .sourceTextNotLoadedWithTranslation : nil
        case .corrected:
            guard !isTranslation else { return .notProduced }
            let hasCorrectionResult = isTextResult
                && (run.resultOperation?.mode == .correction
                    || run.effectivePostprocess?.mode == .correction)
            let hasAcceptedCorrection = run.transcript.segments.indices.contains {
                run.correctionResolution(at: $0, record: record) != nil
            }
            return hasCorrectionResult || hasAcceptedCorrection ? nil : .notProduced
        case .translated:
            return isTranslation ? nil : .notProduced
        case .proposed:
            return proposal == nil ? .proposalNotYetProduced : nil
        }
    }
}

enum TranscriptExporter {
    static func correctedSegmentsDocument(
        run: LoadedRun,
        record: LibraryRecord
    ) throws -> SegmentsDocument {
        try segmentsDocument(layer: nil, run: run, record: record)
    }

    /// The document a given layer would show. `speakerLabelled` deliberately
    /// leaves accepted corrections out, so copying while the raw layer is
    /// displayed copies the raw text. `nil` keeps the export behaviour that
    /// predates layer switching: apply accepted corrections.
    static func segmentsDocument(
        layer: TranscriptDisplayLayer?,
        run: LoadedRun,
        record: LibraryRecord
    ) throws -> SegmentsDocument {
        let allowsConflictResolution = !run.isTranslation
            && layer != .speakerLabelled
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
        return markdown(
            document: document,
            run: run,
            record: record,
            selectedSegmentIndices: nil
        )
    }

    static func copyText(
        run: LoadedRun,
        record: LibraryRecord,
        selectedSegmentIndices: Set<Int>,
        locale: Locale? = nil,
        layer: TranscriptDisplayLayer? = nil
    ) throws -> String {
        let document = try segmentsDocument(layer: layer, run: run, record: record)
        let selectedIndices = selectedSegmentIndices.isEmpty
            ? nil
            : selectedSegmentIndices
        let body = markdown(
            document: document,
            run: run,
            record: record,
            selectedSegmentIndices: selectedIndices
        )
        let header = (layer ?? TranscriptDisplayLayer.displayed(in: run))
            .copyHeader(locale: locale)
        return body.isEmpty ? header + "\n" : header + "\n\n" + body
    }

    private static func markdown(
        document: SegmentsDocument,
        run: LoadedRun,
        record: LibraryRecord,
        selectedSegmentIndices: Set<Int>?
    ) -> String {
        let body = document.segments.enumerated().compactMap { index, segment in
            guard selectedSegmentIndices?.contains(index) ?? true else { return nil }
            return "[\(markdownTimestamp(segment.startS) ?? "Unknown time") – \(markdownTimestamp(segment.endS) ?? "Unknown time")] **\(segment.speaker):** \(segment.text)\(unresolvedMarkers(for: index, run: run, record: record))"
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
