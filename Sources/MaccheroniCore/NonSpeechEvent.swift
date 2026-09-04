import Foundation

/// A non-speech event: a segment whose text is not words a speaker said but
/// the speech model's marker for what the audio held instead.
///
/// VibeVoice writes these as bracketed labels in the `Content` field of its
/// transcript objects, `[Silence]`, `[Human Sounds]` and the like. They are
/// ordinary text to the tokenizer, not special tokens, and neither the model
/// card nor `mlx-audio` publishes the list, so the vocabulary here is the one
/// observed in run artifacts on 2026-09-04; a label outside it is still an
/// event, of kind `other`, carrying its own marker.
///
/// The marker is never rewritten. The ASR artifact keeps what the engine
/// emitted (judgment rule 3), and this type sits beside the text so a reading
/// surface can show an event as an event rather than as speech, and so a later
/// stage can tell the two apart without knowing the vocabulary.
public struct NonSpeechEvent: Equatable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case silence
        case humanSounds = "human_sounds"
        case environmentalSounds = "environmental_sounds"
        case music
        case noise
        /// The model heard speech and transcribed no words: `[Speech]`.
        case untranscribedSpeech = "untranscribed_speech"
        /// A bracketed label outside the observed vocabulary. `marker` is the
        /// only record of what it was.
        case other
    }

    public var kind: Kind
    /// The marker exactly as the engine emitted it, brackets included.
    public var marker: String

    public init(kind: Kind, marker: String) {
        self.kind = kind
        self.marker = marker
    }

    /// The flag the ASR adapter writes beside a segment whose whole text is one
    /// non-speech marker. It travels through merge into `merged/segments.json`
    /// and through correction, which preserves every non-review flag.
    public static let flag = "non_speech_event"

    /// A whole-text marker: one bracketed label of letters and single spaces,
    /// nothing else. A marker inside speech, `hello [Buzzer] there`, does not
    /// match, and that segment stays speech: the words are the record and the
    /// marker reads inline as the engine placed it.
    private static let markerPattern = "^\\[[A-Za-z]+( [A-Za-z]+)*\\]$"

    /// Classify text on its own: the text is one non-speech marker, or it is
    /// speech.
    public static func classify(text: String) -> NonSpeechEvent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: markerPattern, options: .regularExpression)
            == trimmed.startIndex ..< trimmed.endIndex
        else { return nil }
        return NonSpeechEvent(kind: kind(ofMarker: trimmed), marker: trimmed)
    }

    /// Classify a stored segment. The flag decides when the run wrote one; the
    /// text decides for a run sealed before the flag existed, which is every
    /// run written before 2026-09-04 and which judgment rule 3 leaves as it is.
    /// A flagged segment whose text no longer matches the pattern, because a
    /// later layer rewrote it, is still an event; its text is then the marker.
    public static func of(text: String, flags: [String]?) -> NonSpeechEvent? {
        if flags?.contains(flag) == true {
            return classify(text: text)
                ?? NonSpeechEvent(
                    kind: .other,
                    marker: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
        }
        return classify(text: text)
    }

    private static func kind(ofMarker marker: String) -> Kind {
        let label = marker
            .dropFirst()
            .dropLast()
            .lowercased()
        switch label {
        case "silence": return .silence
        case "human sounds": return .humanSounds
        case "environmental sounds": return .environmentalSounds
        case "music": return .music
        case "noise": return .noise
        case "speech": return .untranscribedSpeech
        default: return .other
        }
    }
}
