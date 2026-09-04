import Foundation
import MaccheroniCore

/// A stretch of the recording that produced no transcript: one entry of the
/// run's own `primary/partial-coverage.json`, read as a place in the reading
/// order rather than as a number in the inspector.
struct TranscriptGap: Equatable, Hashable, Identifiable, Sendable {
    var startS: Double
    var endS: Double

    var durationS: Double { endS - startS }

    var id: String { "gap:\(startS):\(endS)" }

    /// What the row at the gap's place says.
    func sentence(locale: Locale? = nil) -> String {
        appString(
            "No transcript from \(TranscriptPlaybackTimeline.clock(startS)) to \(TranscriptPlaybackTimeline.clock(endS)) (\(SegmentAttributionSummary.overlap(durationS, locale: locale))).",
            locale: locale
        )
    }

    /// The same fact where a line already carries the precise timestamps.
    func exportSentence(locale: Locale? = nil) -> String {
        appString(
            "No transcript for \(SegmentAttributionSummary.overlap(durationS, locale: locale)) of the recording.",
            locale: locale
        )
    }

    /// Where each gap falls among segments listed in time order: the index of
    /// the first segment that starts at or after the gap, or `count` for a gap
    /// after the last segment. Both the row list and the export walk the
    /// segments with this, so a hole appears at the same place on screen and
    /// on the clipboard.
    static func positions(
        of gaps: [TranscriptGap],
        amongSegmentsStartingAt starts: [Double]
    ) -> [Int: [TranscriptGap]] {
        var positions: [Int: [TranscriptGap]] = [:]
        for gap in gaps.sorted(by: { $0.startS < $1.startS }) {
            let index = starts.firstIndex { $0 >= gap.startS } ?? starts.count
            positions[index, default: []].append(gap)
        }
        return positions
    }
}

/// What a run did not transcribe, stated for the reading surface: the missing
/// duration, the covered and total durations, and each missing range as a
/// place in time. Present only for a run that is short of its input.
///
/// The ranges come from `primary/partial-coverage.json`, which the run writes
/// beside its manifest under D51; the durations come from the manifest's
/// coverage. A run short of its input whose record is missing still gets a
/// notice, without ranges, so the hole is never silent (judgment rule 2).
struct TranscriptMissingCoverage: Equatable, Sendable {
    var inputDurationS: Double
    var processedDurationS: Double
    var missingDurationS: Double
    var gaps: [TranscriptGap]

    static func load(run: LoadedRun, record: LibraryRecord) -> TranscriptMissingCoverage? {
        let partial = record.runURL.flatMap { LibraryRepository.readPartialCoverage(at: $0) }
        return TranscriptMissingCoverage(coverage: run.manifest.coverage, status: run.manifest.status, partial: partial)
    }

    init?(coverage: Coverage, status: RunStatus, partial: RunPartialCoverage?) {
        let shortOfInput = coverage.truncated
            || status == .partial
            || coverage.processedDurationS < coverage.inputDurationS - RunArtifactContract.timeToleranceS
        guard shortOfInput else { return nil }
        inputDurationS = coverage.inputDurationS
        processedDurationS = coverage.processedDurationS
        missingDurationS = partial?.missingDurationS
            ?? max(0, coverage.inputDurationS - coverage.processedDurationS)
        gaps = (partial?.missing ?? [])
            .map { TranscriptGap(startS: $0.startS, endS: $0.endS) }
            .sorted { $0.startS < $1.startS }
    }

    init(inputDurationS: Double, processedDurationS: Double, missingDurationS: Double, gaps: [TranscriptGap]) {
        self.inputDurationS = inputDurationS
        self.processedDurationS = processedDurationS
        self.missingDurationS = missingDurationS
        self.gaps = gaps
    }

    /// The header's sentence: how much is missing, where, and what the
    /// transcript covers. Printed once above the rows, on every layer, and as
    /// the first line under the layer header on the clipboard.
    func sentence(locale: Locale? = nil) -> String {
        let missing = SegmentAttributionSummary.overlap(missingDurationS, locale: locale)
        let covered = TranscriptPlaybackTimeline.clock(processedDurationS)
        let total = TranscriptPlaybackTimeline.clock(inputDurationS)
        guard !gaps.isEmpty else {
            return appString(
                "\(missing) of this recording produced no transcript. The transcript covers \(covered) of \(total).",
                locale: locale
            )
        }
        let ranges = gaps.map { gap in
            appString(
                "\(TranscriptPlaybackTimeline.clock(gap.startS)) to \(TranscriptPlaybackTimeline.clock(gap.endS))",
                locale: locale
            )
        }.joined(separator: ", ")
        return appString(
            "\(missing) of this recording produced no transcript, from \(ranges). The transcript covers \(covered) of \(total).",
            locale: locale
        )
    }
}
