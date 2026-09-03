import Foundation
import MaccheroniCore

public struct ASRHypothesis: Codable, Equatable, Sendable {
    public var source: String
    public var segments: [Segment]

    public init(source: String, segments: [Segment]) {
        self.source = source
        self.segments = segments
    }

    public init(source: String, result: ASRResult) {
        self.init(source: source, segments: result.segments)
    }
}

public struct ChunkTranscript: Codable, Equatable, Sendable {
    public var index: Int
    public var startS: Double
    public var endS: Double
    public var primary: ASRHypothesis
    public var comparisons: [ASRHypothesis]

    public init(
        index: Int,
        startS: Double,
        endS: Double,
        primary: ASRHypothesis,
        comparisons: [ASRHypothesis] = []
    ) {
        self.index = index
        self.startS = startS
        self.endS = endS
        self.primary = primary
        self.comparisons = comparisons
    }

    enum CodingKeys: String, CodingKey {
        case index, primary, comparisons
        case startS = "start_s"
        case endS = "end_s"
    }
}

public enum MergeConflictKind: String, Codable, Equatable, Sendable {
    case ambiguousSpeaker = "ambiguous_speaker"
    case overlappingSpeech = "overlapping_speech"
    case asrDisagreement = "asr_disagreement"
}

/// Why speaker attribution reached the speaker it reached, one case per return
/// site of `TimelineMerger.speakerAssignment(for:timeline:)`.
public enum SpeakerAttributionOutcome: String, Codable, Equatable, Sendable {
    /// One speaker held a dominant share of the segment's clipped overlap.
    case attributed
    /// No diarization turn overlapped the ASR interval at all.
    case noOverlappingTurn = "no_overlapping_turn"
    /// Turns overlapped, but they covered less of the interval than
    /// `minimumTimelineCoverage` requires.
    case coverageBelowThreshold = "coverage_below_threshold"
    /// Coverage was sufficient, but no speaker reached
    /// `dominantSpeakerShare` with a margin over the runner-up.
    case noDominantSpeaker = "no_dominant_speaker"
}

/// One global speaker that overlapped an ASR segment, with how much of the
/// segment it held. `share` is that speaker's fraction of the segment's total
/// clipped speaker-overlap time, the quantity compared against
/// `dominantSpeakerShare`; shares over all candidates sum to 1.
public struct SpeakerCandidate: Codable, Equatable, Sendable {
    public var speaker: String
    public var overlapS: Double
    public var share: Double

    public init(speaker: String, overlapS: Double, share: Double) {
        self.speaker = speaker
        self.overlapS = overlapS
        self.share = share
    }

    enum CodingKeys: String, CodingKey {
        case speaker, share
        case overlapS = "overlap_s"
    }
}

/// The thresholds that were applied to this segment, recorded per conflict
/// because no other run artifact carries the merge configuration.
public struct SpeakerAttributionThresholds: Codable, Equatable, Sendable {
    public var dominantSpeakerShare: Double
    public var minimumTimelineCoverage: Double
    /// The smallest overlap the merger counts, and the smallest winner margin
    /// it accepts. It is a threshold, not a rounding constant: with overlaps of
    /// 6 s and 5 s, which clear a 0.50 dominant share either way, a tiny value
    /// names the leader while a value above the one-second margin returns
    /// `no_dominant_speaker`. Recorded so a sealed conflict file reproduces the
    /// assignment rather than only two of the three numbers that decided it.
    /// Optional because conflict files written before 2026-09-02 do not carry
    /// it, and a reader must be able to tell an unrecorded value from a
    /// recorded one.
    public var overlapEpsilonS: Double?

    public init(
        dominantSpeakerShare: Double,
        minimumTimelineCoverage: Double,
        overlapEpsilonS: Double? = nil
    ) {
        self.dominantSpeakerShare = dominantSpeakerShare
        self.minimumTimelineCoverage = minimumTimelineCoverage
        self.overlapEpsilonS = overlapEpsilonS
    }

    enum CodingKeys: String, CodingKey {
        case dominantSpeakerShare = "dominant_speaker_share"
        case minimumTimelineCoverage = "minimum_timeline_coverage"
        case overlapEpsilonS = "overlap_epsilon_s"
    }
}

/// The acoustic evidence speaker attribution read for one ASR segment: which
/// speakers were candidates, for how long each, how much of the interval the
/// timeline covered, what bar was applied, and how it came out. It discloses
/// numbers the merger already computes; it adds no inference.
public struct SpeakerAttribution: Codable, Equatable, Sendable {
    public var outcome: SpeakerAttributionOutcome
    /// Ordered by descending overlap, ties broken by ascending speaker ID. The
    /// same order, and the same speakers, as `MergeConflict.candidates`.
    public var candidates: [SpeakerCandidate]
    /// Union of every clipped turn over the segment's duration, in `0...1`.
    public var timelineCoverage: Double
    public var thresholds: SpeakerAttributionThresholds

    public init(
        outcome: SpeakerAttributionOutcome,
        candidates: [SpeakerCandidate],
        timelineCoverage: Double,
        thresholds: SpeakerAttributionThresholds
    ) {
        self.outcome = outcome
        self.candidates = candidates
        self.timelineCoverage = timelineCoverage
        self.thresholds = thresholds
    }

    enum CodingKeys: String, CodingKey {
        case outcome, candidates, thresholds
        case timelineCoverage = "timeline_coverage"
    }
}

public struct MergeConflict: Codable, Equatable, Sendable {
    public var segmentIndex: Int
    public var kind: MergeConflictKind
    public var candidates: [String]
    public var reason: String
    /// Present on `ambiguousSpeaker` and `overlappingSpeech` conflicts, absent
    /// on `asrDisagreement`, whose candidates are texts rather than speakers.
    /// Optional so conflict files written before this field decode unchanged.
    public var speakerAttribution: SpeakerAttribution?

    public init(
        segmentIndex: Int,
        kind: MergeConflictKind,
        candidates: [String],
        reason: String,
        speakerAttribution: SpeakerAttribution? = nil
    ) {
        self.segmentIndex = segmentIndex
        self.kind = kind
        self.candidates = candidates
        self.reason = reason
        self.speakerAttribution = speakerAttribution
    }

    enum CodingKeys: String, CodingKey {
        case kind, candidates, reason
        case segmentIndex = "segment_index"
        case speakerAttribution = "speaker_attribution"
    }
}

public struct TimelineMergeResult: Equatable, Sendable {
    public var segmentsDocument: SegmentsDocument
    public var conflicts: [MergeConflict]

    public init(segmentsDocument: SegmentsDocument, conflicts: [MergeConflict]) {
        self.segmentsDocument = segmentsDocument
        self.conflicts = conflicts
    }
}

/// How much acoustic agreement speaker attribution demands before it names a
/// speaker. `dominantSpeakerShare` 0.60 and `minimumTimelineCoverage` 0.50 are
/// examined values, not incidental defaults: they were measured against a
/// 43.4 % overlap recording on 2026-09-02 and kept. The measurement, the error
/// estimate that decided it, the part of it that stayed unmeasurable, and what
/// would falsify it are in `docs/engineering-constraint-policy.md`, section
/// "2026-09-02 Merge Speaker-Assignment Thresholds". Changing either value
/// changes what the product will and will not claim about a speaker, so it goes
/// through that section rather than through this initializer.
public struct TimelineMergeConfiguration: Equatable, Sendable {
    public var dominantSpeakerShare: Double
    public var minimumTimelineCoverage: Double
    public var timeToleranceS: Double
    public var overlapEpsilonS: Double

    public init(
        dominantSpeakerShare: Double = 0.60,
        minimumTimelineCoverage: Double = 0.50,
        timeToleranceS: Double = 0.01,
        overlapEpsilonS: Double = 1e-9
    ) {
        self.dominantSpeakerShare = dominantSpeakerShare
        self.minimumTimelineCoverage = minimumTimelineCoverage
        self.timeToleranceS = timeToleranceS
        self.overlapEpsilonS = overlapEpsilonS
    }

    public static let `default` = TimelineMergeConfiguration()
}

public enum TimelineMergeError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidSource
    case noChunks
    case nonContiguousChunkIndex(expected: Int, actual: Int)
    case invalidChunk(index: Int)
    case overlappingChunks(previous: Int, current: Int)
    case invalidTimelineSegment(index: Int)
    case unsortedTimeline(index: Int)
    case invalidPrimarySegment(chunk: Int, segment: Int)
    case invalidComparisonSegment(chunk: Int, source: String, segment: Int)
    case duplicateComparisonSource(chunk: Int, source: String)
}

public struct TimelineMerger: Sendable {
    public var configuration: TimelineMergeConfiguration

    public init(configuration: TimelineMergeConfiguration = .default) {
        self.configuration = configuration
    }

    public func merge(
        chunks: [ChunkTranscript],
        timeline: Timeline,
        source: SourceAudio
    ) throws -> TimelineMergeResult {
        try validateConfiguration()
        try validate(source: source)
        try validate(timeline: timeline, source: source)
        let orderedChunks = try validateAndOrder(chunks: chunks, source: source)
        let pending = orderedChunks.flatMap { chunk in
            chunk.primary.segments.enumerated().map { offset, segment in
                PendingSegment(chunk: chunk, sourceOffset: offset, segment: segment)
            }
        }.sorted(by: pendingSegmentOrder)

        var mergedSegments: [Segment] = []
        var conflicts: [MergeConflict] = []
        mergedSegments.reserveCapacity(pending.count)

        for (outputIndex, item) in pending.enumerated() {
            let assignment = speakerAssignment(for: item.segment, timeline: timeline)
            var flags = orderedUnique(item.segment.flags ?? [])
            let hadFlagsField = item.segment.flags != nil

            if let reason = assignment.ambiguousReason {
                append("conflict", to: &flags)
                append("uncertain", to: &flags)
                conflicts.append(MergeConflict(
                    segmentIndex: outputIndex,
                    kind: .ambiguousSpeaker,
                    candidates: assignment.candidates,
                    reason: reason,
                    speakerAttribution: assignment.attribution
                ))
            }
            if assignment.hasOverlappingSpeech {
                append("conflict", to: &flags)
                append("uncertain", to: &flags)
                conflicts.append(MergeConflict(
                    segmentIndex: outputIndex,
                    kind: .overlappingSpeech,
                    candidates: assignment.candidates,
                    reason: "Distinct diarization speakers overlap this ASR interval.",
                    speakerAttribution: assignment.attribution
                ))
            }
            if let disagreement = asrDisagreement(for: item) {
                append("conflict", to: &flags)
                conflicts.append(MergeConflict(
                    segmentIndex: outputIndex,
                    kind: .asrDisagreement,
                    candidates: disagreement.candidates,
                    reason: disagreement.reason
                ))
            }

            mergedSegments.append(Segment(
                speaker: assignment.speaker,
                startS: item.segment.startS,
                endS: item.segment.endS,
                text: item.segment.text,
                language: item.segment.language,
                confidence: item.segment.confidence,
                flags: flags.isEmpty && !hadFlagsField ? nil : flags
            ))
        }

        let attributedSpeakers = Set<String>(mergedSegments.compactMap { segment -> String? in
            switch segment.speaker {
            case "UNASSIGNED", "UNKNOWN": nil
            default: segment.speaker
            }
        })
        return TimelineMergeResult(
            segmentsDocument: SegmentsDocument(
                segments: mergedSegments,
                numSpeakers: attributedSpeakers.count,
                source: source
            ),
            conflicts: conflicts
        )
    }
}

private extension TimelineMerger {
    struct PendingSegment: Sendable {
        var chunk: ChunkTranscript
        var sourceOffset: Int
        var segment: Segment
    }

    struct ClippedSpeakerInterval: Sendable {
        var speaker: String
        var startS: Double
        var endS: Double
    }

    struct SpeakerAssignment: Sendable {
        var speaker: String
        /// `nil` only when diarization produced no timeline at all, where the
        /// segment stays `UNASSIGNED` and raises no conflict.
        var attribution: SpeakerAttribution?
        var ambiguousReason: String?
        var hasOverlappingSpeech: Bool

        /// Kept as the speaker-name projection of `attribution` so the two can
        /// never disagree; existing readers of `MergeConflict.candidates` see
        /// the same names in the same order as before.
        var candidates: [String] { attribution?.candidates.map(\.speaker) ?? [] }
    }

    struct Disagreement: Sendable {
        var candidates: [String]
        var reason: String
    }

    func validateConfiguration() throws {
        guard configuration.dominantSpeakerShare.isFinite,
              (0.5...1).contains(configuration.dominantSpeakerShare),
              configuration.minimumTimelineCoverage.isFinite,
              (0...1).contains(configuration.minimumTimelineCoverage),
              configuration.timeToleranceS.isFinite,
              configuration.timeToleranceS >= 0,
              configuration.overlapEpsilonS.isFinite,
              configuration.overlapEpsilonS >= 0
        else { throw TimelineMergeError.invalidConfiguration }
    }

    func validate(source: SourceAudio) throws {
        let hasPathSeparator = source.fileName.contains("/") || source.fileName.contains("\\")
        guard !source.fileName.isEmpty,
              !hasPathSeparator,
              source.sha256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil,
              source.durationS.isFinite,
              source.durationS > 0
        else { throw TimelineMergeError.invalidSource }
    }

    func validate(timeline: Timeline, source: SourceAudio) throws {
        var previous: TimelineSegment?
        for (index, segment) in timeline.segments.enumerated() {
            guard segment.startS.isFinite,
                  segment.endS.isFinite,
                  segment.startS >= 0,
                  segment.endS > segment.startS,
                  segment.endS <= source.durationS + configuration.timeToleranceS,
                  !segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  segment.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true
            else { throw TimelineMergeError.invalidTimelineSegment(index: index) }
            if let previous,
               segment.startS < previous.startS
                    || (segment.startS == previous.startS && segment.endS < previous.endS)
            {
                throw TimelineMergeError.unsortedTimeline(index: index)
            }
            previous = segment
        }
    }

    func validateAndOrder(chunks: [ChunkTranscript], source: SourceAudio) throws -> [ChunkTranscript] {
        guard !chunks.isEmpty else { throw TimelineMergeError.noChunks }
        let ordered = chunks.sorted { left, right in
            if left.index != right.index { return left.index < right.index }
            if left.startS != right.startS { return left.startS < right.startS }
            return left.endS < right.endS
        }
        var previous: ChunkTranscript?
        for (expectedIndex, chunk) in ordered.enumerated() {
            guard chunk.index == expectedIndex else {
                throw TimelineMergeError.nonContiguousChunkIndex(
                    expected: expectedIndex,
                    actual: chunk.index
                )
            }
            guard chunk.startS.isFinite,
                  chunk.endS.isFinite,
                  chunk.startS >= 0,
                  chunk.endS > chunk.startS,
                  chunk.endS <= source.durationS + configuration.timeToleranceS,
                  !chunk.primary.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw TimelineMergeError.invalidChunk(index: chunk.index) }
            if let previous,
               chunk.startS < previous.endS - configuration.timeToleranceS
            {
                throw TimelineMergeError.overlappingChunks(
                    previous: previous.index,
                    current: chunk.index
                )
            }
            try validate(
                segments: chunk.primary.segments,
                chunk: chunk,
                source: source,
                comparisonSource: nil
            )
            var sources = Set([chunk.primary.source])
            for comparison in chunk.comparisons {
                guard !comparison.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      sources.insert(comparison.source).inserted
                else {
                    throw TimelineMergeError.duplicateComparisonSource(
                        chunk: chunk.index,
                        source: comparison.source
                    )
                }
                try validate(
                    segments: comparison.segments,
                    chunk: chunk,
                    source: source,
                    comparisonSource: comparison.source
                )
            }
            previous = chunk
        }
        return ordered
    }

    func validate(
        segments: [Segment],
        chunk: ChunkTranscript,
        source: SourceAudio,
        comparisonSource: String?
    ) throws {
        for (index, segment) in segments.enumerated() {
            let validLanguage = segment.language.map {
                $0.range(
                    of: "^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$",
                    options: .regularExpression
                ) != nil
            } ?? true
            let validFlags = segment.flags?.allSatisfy {
                $0.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil
            } ?? true
            let valid = segment.startS.isFinite
                && segment.endS.isFinite
                && segment.startS >= 0
                && segment.endS > segment.startS
                && segment.startS >= chunk.startS - configuration.timeToleranceS
                && segment.endS <= chunk.endS + configuration.timeToleranceS
                && segment.endS <= source.durationS + configuration.timeToleranceS
                && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && validLanguage
                && validFlags
                && (segment.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true)
            guard valid else {
                if let comparisonSource {
                    throw TimelineMergeError.invalidComparisonSegment(
                        chunk: chunk.index,
                        source: comparisonSource,
                        segment: index
                    )
                }
                throw TimelineMergeError.invalidPrimarySegment(
                    chunk: chunk.index,
                    segment: index
                )
            }
        }
    }

    func pendingSegmentOrder(_ left: PendingSegment, _ right: PendingSegment) -> Bool {
        if left.segment.startS != right.segment.startS {
            return left.segment.startS < right.segment.startS
        }
        if left.segment.endS != right.segment.endS {
            return left.segment.endS < right.segment.endS
        }
        if left.chunk.index != right.chunk.index {
            return left.chunk.index < right.chunk.index
        }
        return left.sourceOffset < right.sourceOffset
    }

    func speakerAssignment(for segment: Segment, timeline: Timeline) -> SpeakerAssignment {
        guard !timeline.segments.isEmpty else {
            return SpeakerAssignment(
                speaker: "UNASSIGNED",
                attribution: nil,
                ambiguousReason: nil,
                hasOverlappingSpeech: false
            )
        }
        let clipped = timeline.segments.compactMap { turn -> ClippedSpeakerInterval? in
            let start = max(segment.startS, turn.startS)
            let end = min(segment.endS, turn.endS)
            guard end - start > configuration.overlapEpsilonS,
                  turn.speaker != "UNASSIGNED",
                  turn.speaker != "UNKNOWN"
            else { return nil }
            return ClippedSpeakerInterval(speaker: turn.speaker, startS: start, endS: end)
        }
        let grouped = Dictionary(grouping: clipped, by: \.speaker)
        let overlapBySpeaker = grouped.mapValues { intervals in
            unionDuration(intervals.map { ($0.startS, $0.endS) })
        }
        let ranked = overlapBySpeaker.sorted { left, right in
            if left.value != right.value { return left.value > right.value }
            return left.key < right.key
        }
        let totalSpeakerOverlap = ranked.reduce(0) { $0 + $1.value }
        let candidates = ranked.map { entry in
            SpeakerCandidate(
                speaker: entry.key,
                overlapS: entry.value,
                share: totalSpeakerOverlap > 0 ? entry.value / totalSpeakerOverlap : 0
            )
        }
        let intervalDuration = segment.endS - segment.startS
        let coverage = unionDuration(clipped.map { ($0.startS, $0.endS) }) / intervalDuration
        let thresholds = SpeakerAttributionThresholds(
            dominantSpeakerShare: configuration.dominantSpeakerShare,
            minimumTimelineCoverage: configuration.minimumTimelineCoverage,
            overlapEpsilonS: configuration.overlapEpsilonS
        )
        func attribution(_ outcome: SpeakerAttributionOutcome) -> SpeakerAttribution {
            SpeakerAttribution(
                outcome: outcome,
                candidates: candidates,
                timelineCoverage: coverage,
                thresholds: thresholds
            )
        }
        let overlappingSpeech = hasConcurrentDistinctSpeakers(clipped)
        guard let best = ranked.first else {
            return SpeakerAssignment(
                speaker: "UNKNOWN",
                attribution: attribution(.noOverlappingTurn),
                ambiguousReason: "No diarization speaker overlaps this ASR interval.",
                hasOverlappingSpeech: false
            )
        }
        guard coverage + Double.ulpOfOne >= configuration.minimumTimelineCoverage else {
            return SpeakerAssignment(
                speaker: "UNKNOWN",
                attribution: attribution(.coverageBelowThreshold),
                ambiguousReason: "Diarization coverage is below the configured assignment threshold.",
                hasOverlappingSpeech: overlappingSpeech
            )
        }
        let share = best.value / totalSpeakerOverlap
        let runnerUp = ranked.dropFirst().first?.value ?? 0
        guard share + Double.ulpOfOne >= configuration.dominantSpeakerShare,
              best.value - runnerUp > configuration.overlapEpsilonS || ranked.count == 1
        else {
            return SpeakerAssignment(
                speaker: "UNKNOWN",
                attribution: attribution(.noDominantSpeaker),
                ambiguousReason: "No diarization speaker has a dominant overlap with this ASR interval.",
                hasOverlappingSpeech: overlappingSpeech
            )
        }
        return SpeakerAssignment(
            speaker: best.key,
            attribution: attribution(.attributed),
            ambiguousReason: nil,
            hasOverlappingSpeech: overlappingSpeech
        )
    }

    func unionDuration(_ intervals: [(Double, Double)]) -> Double {
        let ordered = intervals.sorted { left, right in
            if left.0 != right.0 { return left.0 < right.0 }
            return left.1 < right.1
        }
        guard var current = ordered.first else { return 0 }
        var total = 0.0
        for interval in ordered.dropFirst() {
            if interval.0 <= current.1 {
                current.1 = max(current.1, interval.1)
            } else {
                total += current.1 - current.0
                current = interval
            }
        }
        return total + current.1 - current.0
    }

    func hasConcurrentDistinctSpeakers(_ intervals: [ClippedSpeakerInterval]) -> Bool {
        for leftIndex in intervals.indices {
            for rightIndex in intervals.indices where rightIndex > leftIndex {
                let left = intervals[leftIndex]
                let right = intervals[rightIndex]
                guard left.speaker != right.speaker else { continue }
                if min(left.endS, right.endS) - max(left.startS, right.startS)
                    > configuration.overlapEpsilonS
                {
                    return true
                }
            }
        }
        return false
    }

    func asrDisagreement(for item: PendingSegment) -> Disagreement? {
        var candidates = ["\(item.chunk.primary.source): \(item.segment.text)"]
        var disagreeingSources: [String] = []
        let primaryNormalized = normalizedText(item.segment.text)
        for comparison in item.chunk.comparisons.sorted(by: { $0.source < $1.source }) {
            let aligned = comparison.segments.filter {
                min(item.segment.endS, $0.endS) - max(item.segment.startS, $0.startS)
                    > configuration.overlapEpsilonS
            }.sorted {
                if $0.startS != $1.startS { return $0.startS < $1.startS }
                return $0.endS < $1.endS
            }
            let comparisonText = aligned.map(\.text).joined(separator: " ")
            if aligned.isEmpty || normalizedText(comparisonText) != primaryNormalized {
                candidates.append(
                    "\(comparison.source): \(aligned.isEmpty ? "<no aligned text>" : comparisonText)"
                )
                disagreeingSources.append(comparison.source)
            }
        }
        guard !disagreeingSources.isEmpty else { return nil }
        return Disagreement(
            candidates: candidates,
            reason: "Primary ASR text disagrees with: \(disagreeingSources.joined(separator: ", "))."
        )
    }

    func normalizedText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .lowercased()
            .unicodeScalars
            .split(whereSeparator: { !CharacterSet.alphanumerics.contains($0) })
            .map { String($0) }
            .joined(separator: " ")
    }

    func orderedUnique(_ flags: [String]) -> [String] {
        var seen: Set<String> = []
        return flags.filter { seen.insert($0).inserted }
    }

    func append(_ flag: String, to flags: inout [String]) {
        guard !flags.contains(flag) else { return }
        flags.append(flag)
    }
}
