# Maccheroni UI Design

This is the input document for T15. Preserve the premise that this is a
personal tool: do not build onboarding, accounts, usage metrics, or KPI
instrumentation. Follow native macOS conventions and the applicable platform
and SwiftUI guidance during implementation.

## Design principles

1. **One decision per screen.** During recording, show only the recording state
   and profile. When viewing results, show only the transcript and uncertain
   spans.
2. **Privacy is an always-visible control.** Expose the post-processing backend
   (Codex cloud or local model) at the point of execution rather than burying
   it in settings. Show alongside it that audio never leaves the device under
   either choice.
3. **Uncertainty is a visual language.** Show conflict and uncertain flags as
   highlights in the transcript. A click records the resolution: keep the
   source or accept the alternative. Do not make this look like automatic
   replacement.
4. **The source is immutable in the UI too.** No screen offers a 1st-order action
   that deletes or overwrites source audio or a raw transcript. Moving to the
   Trash is an explicit 2-step action.

## Structure

One window using `NavigationSplitView`: sidebar plus detail.

- **Sidebar: Library.** A list of recordings and runs. Each item shows a status
  badge (recorded / transcribing / done / has-conflicts), date, duration, and
  profile. Search and folders are non-goals outside v1.
- The **detail area** shows one of three views based on item state.

### 1. Capture view (new recording)

- One large record button. Once recording starts, show elapsed time and two
  level meters: microphone and system audio. D18 requires simultaneous capture
  of microphone and system sound with the channels preserved separately. In a
  Zoom meeting, tap system audio itself instead of recapturing speaker output
  through the microphone.
- Before recording, the default selections are a profile (ko-it meeting / it
  dialogue / en meeting / auto) and a post-processing backend (Codex / local /
  none). Under D29, selecting post-processing also reveals the task (correction
  / translation), and only translation reveals the target language. Persist
  these selections for the next recording.
- When recording starts, hide selection controls, file drop, and the privacy
  explanation. Leave only the selected profile summary, recording status, two
  level meters, and stop control.
- A file can be dropped either on the drop zone in this view or anywhere in the
  Library.
- Before a run starts, state whether the selected profile is ready. A failed
  `doctor` check or a denied microphone disables the record button, the drop
  zone, and file selection, names the missing dependency in user language rather
  than a check key, and shows the provisioning command only where that command
  installs it. A ready profile shows nothing.

### 2. Run progress view

- Stage indicator: preprocessing → diarization → ASR chunk n/m → merge →
  (post-processing). Show elapsed time per stage and the current model name
  (model ID). The run can be canceled, and cancellation preserves intermediate
  artifacts.

### 3. Transcript view (primary screen)

Revised 2026-09-02 against a real transcript rather than a clean synthetic one:
one 20.7-minute Korean meeting, 248 merged segments averaging 4.9 seconds, 2
speakers, 43.4 % overlap share. In that transcript **110 of 248 segments carry no
speaker (44.4 %) and 192 are flagged `conflict` or `uncertain` (77.4 %)**. Every
rule below is chosen for those proportions. A design that only reads well when a
handful of segments are marked is the wrong design for this product, because the
marked case is the ordinary case.

#### The reading surface

A fixed header bar sits above a scrolling segment list. The header carries every
control that changes what the list shows, so a reader never hunts in a menu for
the state the page is in:

- the recording name, the segment and speaker counts, and how many segments have
  no speaker;
- the **layer bar** (below);
- a **search field** that filters the list by text and by speaker name, showing
  the match count;
- the **review stepper**: the unresolved count is a control, not a label. It
  reads `n of m` and its two buttons move the focus to the previous and next
  unresolved segment and scroll it into view, wrapping at both ends;
- the **transport**: elapsed and total time, a play/pause control, and a
  scrubbable playhead over the whole recording.

The search field lives in the header rather than in the window toolbar. Both are
native; the header is the one an offscreen render can show, and under D48 the
screen is judged from rendered images.

#### Layers

The reader switches the displayed layer between **Speaker-labelled**,
**Corrected**, **Translated** and **Proposed** without ever losing the original. The layer bar
lists all four at all times. A layer this run cannot show stays visible, is not
selectable, and says in one sentence why — a reader learns what the product can
produce from the same control that switches between what it did produce.

- **Speaker-labelled** is the immutable merged transcript: what the speech model
  said, joined to the acoustic speaker timeline. It is available whenever the
  source text is loaded, and it is the layer the rest of the tree calls raw.
- **Corrected** is Speaker-labelled plus the corrections the reader accepted. Post-processing
  never rewrites text on its own; it proposes, and the difference between Raw and
  Corrected is exactly the set of proposals a human accepted. Copying while
  Speaker-labelled is displayed copies the raw text, not the corrected text.
- **Translated** is a separate create-only artifact and replaces the text.
- **Proposed** is the D46 layer: a marked non-acoustic speaker proposal from a
  derived run. Until that derived run exists the layer is listed as not yet
  produced. When it exists:
  - The proposal is drawn **under** the acoustic evidence, never in place of
    it, and never in the speaker chip's treatment. It takes the candidate
    treatment — a colour dot and a plain name — behind a dashed label reading
    *Proposed, not measured*. A reader must not be able to mistake it for the
    segment's speaker; that is judgment rule 4 and the condition D46 allows
    this layer to exist under.
  - A segment the proposer **declined** is a state, not an absence. It reads
    *No speaker proposed* with the reason underneath, in the same place a
    proposal would have been. Every segment the source run left unattributed
    appears in one of those two states, so the layer can never look like it
    quietly skipped something. Roughly one unattributed segment in nine comes
    back declined, and the reason is the payload of that row.
  - The layer is **never the default**. It is something a reader asks to see.
  - A header notice states how many were proposed and how many declined, that
    this is neither acoustic evidence nor a measurement, and — when the source
    transcript is incomplete — how much of the recording produced no transcript
    at all, so a proposal layer over a 97.5 % transcript cannot present as
    covering the meeting.
  - Which layer a loaded result is showing is decided by the derived
    operation's **kind**, never its mode: a speaker-proposal manifest keeps
    `mode` at `correction` for a structural reason, and reading `mode` would
    show a proposal run as a corrected transcript and offer a Corrected layer
    over text nothing corrected.

Switching a layer changes what is displayed and nothing else. No layer writes to
a source run (judgment rule 3), and the acoustic evidence is shown under every
layer.

#### Speaker treatment

Speaker identity is carried by a **name chip** — the speaker's name or its
global speaker ID — plus a colour and a left rule. The name is the primary
carrier, so the treatment survives a reader who cannot distinguish the colours.
Colours are assigned by the speaker's position in the run's sorted speaker
roster, not by a hash of the name, so two speakers in a two-speaker recording
can never collide onto the same colour.

An **unattributed** segment does not print `UNKNOWN`. It reads
`Speaker not named`, carries a dashed rather than solid left rule and a `?`
glyph, and shows the acoustic evidence the merger recorded:

- a share meter, one band per candidate speaker, proportional to that speaker's
  share of the segment's clipped overlap, up to 320 points wide so a near-even
  split is still readable as one;
- one line per candidate: name, share as a percentage, and overlapped seconds;
- one sentence naming why no speaker was chosen, in the reader's language, one
  sentence per outcome the merger distinguishes — no overlapping turn at all,
  timeline coverage below the bar, or no speaker dominant.

This is the evidence P1 disclosed and P3 examined. It is the reason a reader can
resolve a segment without going back to the audio: on the measured run the
typical unattributed segment is a 0.54 / 0.46 split just under the 0.60 bar, and
seeing that split is usually enough to decide.

An **attributed** segment that had a competing candidate shows its winning share
next to the name and nothing else. Showing the full meter on all 183 such
segments would bury the 110 that need it.

#### Conflicts at 77 % flagged

The pre-2026-09-02 treatment tinted the row background, drew an orange border,
and printed the raw flag tokens as chips. At 77.4 % flagged that turns the page
into an orange field with three monospace tokens under every paragraph, and the
marking stops meaning anything.

The rule now: **the page is calm, and only the segment the reader is working on
is loud.**

- No per-row tint and no per-row border for being flagged.
- A flagged segment carries one small review marker at the end of its meta row:
  outline when unresolved, filled check when resolved.
- The review stepper's current target — exactly one segment at a time — gets an
  accent-tinted background and a visible focus ring.
- Raw flag tokens never appear in the reading surface. `conflict` and
  `uncertain` are represented by the review marker itself.
  `backend_speaker_evidence` is provenance, appears on 245 of 248 segments, and
  belongs in the segment's detail, not under every paragraph. Any flag the app
  does not have a word for is shown only in the segment detail, under
  `Other markers`.

#### Reviewing a segment

The review sheet is chosen by what the conflict actually is, because the three
conflict kinds carry different things in the same `candidates` array:

- `asr_disagreement` carries **texts**. The sheet offers them as alternatives and
  records the reader's choice as a correction beside the immutable raw
  transcript.
- `ambiguous_speaker` and `overlapping_speech` carry **speaker IDs**. The sheet
  shows the acoustic evidence — candidates, shares, overlapped seconds, timeline
  coverage, the bar that was applied — and offers no text replacement at all. It
  offers renaming the speaker and marking the segment reviewed.

Offering a speaker ID as replacement transcript text is a data defect, not a
choice, and the previous sheet did exactly that for all 293 conflicts on the
measured run.

#### Text, selection and playback

- Transcript text is selectable. Selection is the reader's primary tool for
  moving text out of the app, so it outranks making the paragraph a click
  target. Playback is an explicit control on the meta row and on the transport.
- Playing a segment seeks the source file and keeps playing past the segment
  end, following the reader down the list and highlighting the segment that the
  playhead is inside. Correction work is listening work; stopping after 4.9
  seconds forces a click per segment.
- Playback offers pause and resume, and the playhead is visible in the header at
  all times, both as a time and as a position in the recording.
- Audio comes only from the source file. No screen writes to it.

#### Inspector

The inspector is **collapsed by default**. Opening it shows provenance as a
readable summary — status, duration, coverage in words, speakers, segments,
unattributed count, profile, models by role and model ID, glossary — and no run
ID, no SHA-256, and no format strings. Fingerprints sit behind one disclosure
labelled for what they are, and are selectable when opened. Exact identity stays
one click away instead of being the first thing on the panel.

#### What the rendered images changed

The design above was not written and shipped; it was rendered offscreen at 820
and 1400 points, in light and dark, and read back. Five things changed because
of what the images showed, and they are recorded here because the reasons are
not visible in the result:

- **The reason sentence left 108 rows.** Printing "no speaker held 60 % …"
  under every unnamed segment printed one fact 108 times. It now appears on the
  segment the reader is on, and always for the two rarer outcomes, which say
  something the shares do not.
- **Both row controls moved off the right edge.** The review marker sat across
  an empty 500-point gap from the text, and the copy-selection circle sat at the
  right edge of the 860-point reading measure. With 192 of 248 segments carrying
  a marker, that scan runs the width of the page for a marker and again for a
  secondary affordance. Both now sit with the speaker and the time. They do
  different things — the flag opens the review, the circle adds the segment to a
  copy selection — and the glyphs, the help text and the accessibility labels
  say which is which.
- **A contested share says what it measures.** An attributed speaker with a
  competing candidate showed a bare `64%` next to its name, which reads as
  "64 % sure this is Jina" — a confidence this product does not compute. It now
  reads `64% of speech`, falling back to the bare percent only where the label
  does not fit. The number appears only when a second speaker actually held part
  of the segment; a segment only one speaker overlapped shows none, so the
  number never implies doubt where the acoustics had none.
- **The share meter widened to 320 points.** At 220 a 51/49 split and a 56/44
  split were hard to tell apart, and the reading measure has the room.
- **Rows lost their card background.** `controlBackgroundColor` resolves to the
  window colour in both appearances, so the card was invisible anyway. Only a
  focused, playing or selected row is tinted, which is what the design wanted.
- **The speaker palette dropped blue.** Blue is the accent that marks the
  segment the reader is on, and speaker 0 was blue, so a speaker colour and a
  state colour were the same colour.
- **A wrong sentence was found.** Under a translation, an unnamed segment read
  "This segment carries no recorded speaker evidence", which is false: the
  evidence is in the source run and the translation load path drops it. Absent
  evidence and unloaded evidence now read differently.

Two limits of the offscreen harness are worth writing down, because they decide
what a rendered image can be trusted to show:

- **Nothing inside a scrolling container renders.** `ScrollView`, `List` and
  `Form(.grouped)` all come back empty. The transcript header, the segment
  column, the inspector's sections and the review sheet's body are therefore
  separate views that a harness can render on their own.
- **AppKit-backed controls render as a placeholder glyph.** Button styles
  `.borderless` and `.link` do, so this surface uses `.plain` throughout. Text
  fields and sliders do too, and cannot be avoided: the search field and the
  playhead scrubber appear as yellow blocks in every rendered image, and their
  appearance is the one thing offscreen rendering cannot judge.

#### Three defects a second reading of the images caught

A critique pass over the same renders found three more. They are recorded here
because two of them are the kind that a design document can claim fixed while
the code says otherwise.

- **The reason sentence came back on the translation layer.** The predicate was
  `isFocused || outcome != .noDominantSpeaker`. On a translation the evidence is
  not loaded, so `outcome` is `nil`, and `nil != .noDominantSpeaker` is true —
  the sentence printed under all 110 unnamed rows, on the one layer with the
  least to say. **No outcome at all is now its own case**: it never prints per
  row, and the reason is stated once under the layer bar instead. A regression
  test pins both halves.
- **The header and the segment column sat on different axes.** The column is
  capped at 860 points and centred; the header was full-bleed. At 1400 points
  that put 261 points between the layer bar and the first segment it switches,
  and the eye path before reading one segment crossed four axes. The header now
  takes the same measure and centring, so every control shares a left edge with
  the rows it acts on. The measure itself is right and did not change.
- **One glyph meant three things.** `checkmark.circle.fill` was *review
  resolved* on the marker, *selected for copying* on the control beside it, and
  *run finished* in the library sidebar — two of those on the same row, eight
  points apart, separated only by grey against accent. The copy-selection
  control is now a **checkbox**, which is what macOS uses for "include this in a
  bulk action" and which leaves the check-in-a-circle to mean one thing.

#### Type and layout tokens

One token set, defined once and used by every view in this surface, replacing
per-view inline numbers:

- **Type.** Screen title 22, section title 15 semibold, transcript body 15 with
  3 pt line spacing, speaker name 13 semibold, meta and evidence 12. Nothing in
  the reading surface is smaller than 12, and `caption2` is not used there at
  all. The old surface set flags, evidence and provenance at `caption2`, which
  is 10 pt, and made the reading surface the smallest text on screen.
- **Spacing.** 4 / 8 / 12 / 16 / 24. Row padding 14, list spacing 8.
- **Radius.** 6 for chips and markers, 10 for rows, 14 for sheets.
- **Axis.** The header and the segment column share one 860-point measure and
  one centring, so a control and the rows it acts on line up.
- **Glyphs.** One glyph, one meaning, per surface: a flag is review pending, a
  check in a circle is review resolved, a checkbox is included in a copy
  selection.
- **Colour.** A seven-entry speaker palette indexed by roster position; one
  neutral for unattributed; one accent for the current review target; one
  surface and one hairline. Colour never carries meaning alone: every colour in
  this surface accompanies a word, a glyph, or a rule style.

#### Reach of the token set

The tokens are defined once and used by the transcript view, the run inspector
and the library sidebar. The capture view, the run progress view and settings
still carry their own inline numbers; they were settled in the predecessor plan
and are not reopened here. Bringing them onto the same tokens is the next step
for whoever owns those files.

#### Not yet built here

Recording rename and the two-step move to Trash are still promised by this
document and still absent. They need library mutation the transcript surface does
not own: a rename and a trash operation on the app model and the library
repository. They are specified here so the task that owns those files can build
them:

- **Rename** edits only `displayName` in the library index. It never renames the
  source file, the run directory, or any artifact.
- **Move to Trash** is two steps, and never a first-order action: a menu item
  that opens a confirmation naming the recording and what will be moved, then the
  move itself through `NSWorkspace.recycle`, so the Finder Trash and its Put Back
  remain the recovery path. The run directory and the source audio go to the
  Trash together or not at all, and a failure leaves the library entry in place.

The Speaker-labelled layer beside a translation is the third gap. The library
decodes the source transcript, applies the translated text over it, and drops
the source document, so the raw text is not in memory once a translation result
is loaded — the same shape of loss P1 found in the merger. Carrying the source
document on the loaded run would make the layer selectable without re-reading
anything from disk. The layer bar states this rather than hiding the layer.

### 4. Glossary editor (sheet or settings tab)

- A simple per-profile list with category comments (people / terms / places).
- Adding an entry must take no more than 3 seconds: keyboard shortcut plus
  inline add.

### 5. Settings

- Model registry: installed-model list, language coverage, own benchmark values
  when available, disk usage, download, and delete.
- Choose the storage locations for recordings and run output with a native
  folder picker. A new location applies from the next app launch. Do not move or
  delete existing files. `Use Default` restores the default location under
  Application Support.
- Select the default post-processing backend and local post-processing model.
  The v1 local picker shows only the verified and revision-pinned
  `mlx-community/gemma-4-12B-it-qat-4bit`. Do not present unverified future
  options.
- Language: follow the system or choose manually (D16, English by default).

## Not in v1

Menu-bar residency, live captions, meeting-note or summary UI, search,
calendar, speaker-voice enrollment UI (CLI only), and theme customization.

## Implementation notes

- Capture system audio with a CoreAudio process tap or ScreenCaptureKit audio
  capture (macOS 14.4+). Do not copy code from other apps such as Muesli before
  checking the license. The screen-recording permission text must clearly say
  "Required to record system audio."
- Preserve microphone and system channels separately until the merge stage.
  Channel source can serve as a secondary diarization hint (self versus remote
  participants), but it does not replace acoustic diarization.
