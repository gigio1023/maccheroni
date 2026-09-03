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

Designed against a real transcript rather than a clean synthetic one: one
20.7-minute Korean meeting, 248 merged segments averaging 4.9 seconds, 2
speakers, 43.4 % overlap share. In that transcript **110 of 248 segments carry no
speaker (44.4 %) and 192 are flagged `conflict` or `uncertain` (77.4 %)**; 204 of
the 248 are one line of text at the reading measure, and the median segment is
18 characters. Every rule below is chosen for those proportions. A design that
only reads well when a handful of segments are marked is the wrong design for
this product, because the marked case is the ordinary case.

Revised 2026-09-02 a second time, after the first rework was rendered and
measured against the owner's own design lock. The first rework fixed the
content of the screen — evidence disclosed, layers, a review navigator, no raw
tokens — and got the **genre** wrong: it applied product-UI grammar (pills,
filled cards, coloured edge strips, status colour on three rows in four) to a
job that is reading evidence and deciding the next action. Colour and radius
were consistent; the document genre was not. This revision changes the genre.

#### Two grammars, one boundary

The screen has two jobs and they get two grammars, separated by one rule.

- **Above the rule, product UI.** The header carries every control that changes
  what the list shows: transport, layer switch, search, review navigator. These
  are controls and look like controls.
- **Below the rule, an editorial table.** The row list shows what was said, by
  whom, with what evidence. It is a data table in the owner's sense — dense,
  first-class content — and follows the table rules below. Nothing in it is a
  card, a chip-shaped pill, a filled surface, or a coloured strip.

The rule is: **do not mix the two grammars in one surface**. The header may use
a bordered field and a filled selection; the list may not. The rule under the
header is where one grammar stops.

The two sides share one left edge and one 860-point reading measure, so a
control and the rows it acts on line up. Full-bleed chrome over a centred column
put 261 points between the layer bar and the first segment it switched.

#### The header

- The recording name (22 pt) with, on the same line where it fits, the
  **transport**: play/pause, elapsed time, a scrubbable playhead over the whole
  recording, total time. No box around it.
- One line of counts: segments, speakers, without a speaker, to review.
- The **layer switch**: four text tabs, always all four. The displayed layer is
  set in the primary ink at semibold with a 2-point accent underline; an
  available layer is primary ink at regular weight; a layer this run cannot show
  stays visible in the secondary ink, is not selectable, and says in one sentence
  why. The same control switches layers and shows which layers this product can
  produce at all. No fill, no pill.
- The **review navigator**: the unresolved count is a control, not a label. It
  reads `n of m to review` beside a flag glyph in the open colour — the one
  place on the screen where status colour marks the reader's open work — and two
  square hairline-bordered buttons step to the previous and next unresolved
  segment, scrolling it into view and wrapping at both ends.
- The **search field**: a hairline-bordered field at the control radius, with the
  match count while a query is active. It sits to the right of the tabs where the
  measure allows and drops under them where it does not.
- A **proposal notice** under the tabs when the Proposed layer is displayed
  (below).
- A **hairline rule** closes the header. It is the boundary.

#### Layers

The reader switches the displayed layer between **Speaker-labelled**,
**Corrected**, **Translated** and **Proposed** without ever losing the original.

- **Speaker-labelled** is the immutable merged transcript: what the speech model
  said, joined to the acoustic speaker timeline. It is available whenever the
  source text is loaded, and it is the layer the rest of the tree calls raw.
- **Corrected** is Speaker-labelled plus the corrections the reader accepted.
  Post-processing never rewrites text on its own; it proposes, and the
  difference between the two is exactly the set of proposals a human accepted.
  Copying while Speaker-labelled is displayed copies the raw text.
- **Translated** is a separate create-only artifact and replaces the text.
- **Proposed** is the D46 layer: a marked non-acoustic speaker proposal from a
  derived run. Until that derived run exists the layer is listed as not yet
  produced. It is **never the default**; a reader asks for it. Which layer a
  loaded result is showing is decided by the derived operation's **kind**, never
  its mode: a speaker-proposal manifest keeps `mode` at `correction` for a
  structural reason, and reading `mode` would show a proposal run as a corrected
  transcript.

Switching a layer changes what is displayed and nothing else. No layer writes to
a source run (judgment rule 3), and the acoustic evidence is shown under every
layer that carries it.

#### The row list

Rules, each of which the previous screen violated:

1. Hierarchy comes from type, spacing and neutral hairlines. No cards, no row
   fills, no coloured left or top strips on routine components.
2. One accent hue, used for the current thing: the focused row, the displayed
   tab, a checked selection box, the playing segment.
3. Status colour only for an open state, sparse, and always beside a
   text label.
4. Square geometry: 4 points on controls, 2 on chips, 0 elsewhere. No pills, no
   repeated rounded surfaces.
5. No motion beyond native scrolling and the navigator's scroll-to.
6. Rows are separated by a bottom hairline only. No vertical rules, no zebra,
   and the last row carries no rule.
7. Numbers are set in tabular figures so they align down a column.

**The structural change that pays for everything else.** The meta — selection
box, time, speaker, share, review chip — leaves the stacked line above the text
and moves into a **fixed-width left gutter beside it**, so a one-line segment is
one line tall and every column aligns across rows. The eye reads down one
column: down the times to find a moment, down the speakers to follow one voice,
down the chips to find open work, down the text to read. The gutter is also
where the type hierarchy comes from: roles are separated by axis, not by adding
sizes.

Columns, left to right, in points, with an 8-point gap between them and 12
before the text:

| column | width | content |
|---|---|---|
| select | 14 | checkbox glyph: include this segment in a copy selection |
| time | 48 | segment start, tabular, secondary ink; the playback control for that segment. Wide enough for `59:59` beside the playing glyph |
| speaker | 132 | the speaker's name in its colour at 13 pt semibold, or *Speaker not named* in the secondary ink; the share of speech right-aligned in the same cell when a second speaker held part of the segment |
| review | 76 | the review chip, or nothing |
| text | the rest | transcript, 15 pt, selectable |

A pinned column-header row names the columns once — TIME, SPEAKER, SHARE,
REVIEW, TEXT — in the 11-point label face, so a share of `64%` under SHARE
cannot be misread as "64 % sure this is Jina": the header carries the label that
the previous surface printed as *of speech* 82 times.

Row states, none of which is a box:

- **Focused** (the review navigator's target, exactly one at a time): the row's
  bottom hairline becomes a 2-point accent rule, the time is set in the accent
  at semibold, and the row prints the sentences that other rows do not (below).
  Accent, underline and weight; no fill, no ring, no bar.
- **Playing**: the time carries a waveform glyph in the accent.
- **Selected for copying**: the checkbox is filled in the accent.
- **Flagged**: the review chip is present. 192 of 248 rows are in this state and
  it must not change the row's colour, weight or geometry.

#### Speaker treatment

Speaker identity is carried by the **name** — the speaker's given name or
*Speaker n* from the global speaker ID — set in the speaker's colour at 13 pt
semibold. The name is the primary carrier; the colour is paired with it and
never appears without it, so the treatment survives a reader who cannot
distinguish the colours. Colours are assigned by the speaker's position in the
run's sorted speaker roster, not by a hash of the name, so two speakers in a
two-speaker recording can never collide onto the same colour.

The palette is **resolved per appearance**. The previous seven system colours
were chosen against the dark render and inherited into light, where the teal
speaker name measured 2.16:1. Each roster position now has a light value and a
dark value, chosen so the name reads at 4.5:1 or better on the page ground in
both appearances (values under *Tokens*). The name keeps the same hue in both,
so a speaker does not change identity when the appearance does.

An **attributed segment that had a competing candidate** shows its winning
share right-aligned in the speaker cell and nothing else; a segment only one
speaker overlapped shows no number, so the number never implies doubt where the
acoustics had none. Showing the full evidence on all 82 contested rows would
bury the 110 that need it.

#### Evidence for a segment nobody was named for

An unattributed segment does not print `UNKNOWN`. Its speaker cell reads
*Speaker not named* in the secondary ink, and a second gutter line, aligned to
the speaker column and spanning the speaker and review columns, prints the
acoustic evidence the merger recorded:

- **the figures**: each candidate's name in its colour and its share of the
  segment's clipped overlap as a percentage, in tabular figures, always printed;
- **the band**: a 100 % stacked bar, 3 points tall, directly beneath the
  figures, split by share, one part per candidate in that candidate's colour,
  with a 2-point gap of page ground between the parts. "Band" is its name
  everywhere in this document and in the code.

The band is a chart, and the owner's rule is that a chart must answer a
question the numbers beside it do not. It stays because it answers a question
the figures do not: **how close was it, and who led**. It makes a 51/49 split
and a 56/44 split distinguishable at a glance where the figures need a
subtraction. It is subordinate — under the figures, never alone — and it
carries nothing the figures do not: the figures are the record, the band is the
reading aid. It sits *beneath* the figures rather than behind them because a
band strong enough to meet the 3:1 floor for a meaning-carrying mark would
destroy the contrast of text printed over it, and a band faint enough to sit
behind text would fail the floor. Beneath, both pass.

The overlapped seconds per candidate are no longer printed on the row. They
restate the shares against the segment's duration, and the row has the
duration's start beside it; they stay in the review sheet, where the full
evidence block is shown with the wide band and the timeline coverage.

The **reason sentence** — one sentence per outcome the merger distinguishes, in
the reader's language — prints under the text column on the focused row, and
always for the two rarer outcomes (no overlapping turn at all; timeline coverage
below the bar), which say something the shares do not. On the measured run 100
of the 110 unnamed segments collapse for the common reason, and printing it 100
times printed one fact 100 times. A translation result drops the evidence, and
no outcome at all is its own case: it never prints per row and is stated once
under the header instead.

#### Review at 77 % flagged: the chip

The marker is a **status chip**: 11-point heavy label with a glyph, 2-point
radius, one-point border, **neutral by default**. That is the mechanism that
lets 192 of 248 rows carry a marker without the page shouting: a neutral chip in
the secondary ink is part of the table's texture, and colour is saved for the
rare row whose state is open.

| variant | when | appearance |
|---|---|---|
| neutral, pending | the segment carries a speaker conflict or an uncertainty flag and has not been marked reviewed | flag glyph, *Review*, secondary ink |
| neutral, resolved | the reader marked it reviewed or accepted a wording | check glyph, *Reviewed*, secondary ink |
| open | the segment has alternative wordings the reader must choose between — a text disagreement, or a post-processing candidate merged onto the segment | flag glyph, *Wording*, the open colour |

No urgent variant is defined: nothing on this surface is urgent, and a variant
without a state would be decoration. The chip opens the review sheet. Review
state is carried by the glyph shape and the label, not by colour: a pending and
a resolved chip differ in both.

Raw flag tokens never appear in the reading surface. `conflict` and
`uncertain` are represented by the chip; `backend_speaker_evidence` is
provenance on 245 of 248 segments and belongs in the segment's detail; any flag
the app has no word for is shown only there, under *Other markers*.

#### The proposal layer on a row

When the Proposed layer is displayed, every segment the source left
unattributed gains a third gutter line and, under its text, a sentence:

- A **proposed** segment reads a dashed label *Proposed, not measured* followed
  by the proposed speaker in the **candidate treatment** — a 7-point dot and a
  plain name in the primary ink — never in the speaker treatment. The label
  never wraps; a name too long to sit beside it drops under it. The dashed
  border and the plain name are what stop a proposal from being mistaken for
  the segment's speaker; that is judgment rule 4 and the condition D46 allows
  this layer to exist under. The proposer's reason prints under the text.
- A **declined** segment reads a dashed label *No speaker proposed*, with the
  reason under the text. Every unattributed segment appears either as proposed
  or as declined, so the layer cannot look like it skipped one. The reason names
  the cause in the reader's own language
  wherever the constraint, rather than the model, decided; where the model
  decided, its own words stand and the app adds nothing.
- A segment declined because **the top candidates hold the same overlap to within
  the proposer's tolerance** says so in its own sentence: *The top speakers held
  the same time in this segment, to within a nanosecond.* The sentence states the
  comparison the artifact's `cause` actually made, so the row and the artifact
  cannot disagree. Nothing else on the row can say it. The shares are printed rounded to
  whole percentages, and on the measured run a model decline at 0.5015 / 0.4985
  and a true tie at 0.5000 / 0.5000 both print 50 % / 50 %; the band splits the
  same way for both. The tie is read off the overlapped seconds by the proposer's
  own rule, never off the printed percentages, so the row can never call a tie
  the artifact did not. This is the one cause sentence that does not stand down
  for the acoustic reason on a focused row: that reason names the run's
  dominant-share bar, which is true of every unattributed segment and says
  nothing about two candidates being level.
- A segment D50 declined **because the model disagreed with the top-ranked
  candidate** reads as a decline. The disagreement is preserved evidence and the
  reason sentence names both the model's answer and the top-ranked candidate,
  but the model's answer is never printed as a name with a dot: rendering a
  non-acoustic contradiction in the candidate treatment would put it beside the
  acoustic candidates as if it were one of them. It stays in the sentence.

The acoustic figures and band stay on the row above the proposal line, so a
reader always sees what the acoustics said and what the proposal added.

The header notice states how many were proposed and how many declined, that
this is neither acoustic evidence nor a measurement, and — when the source
transcript is incomplete — how much of the recording produced no transcript at
all, in the open colour beside a glyph, so a proposal layer over a 97.5 %
transcript cannot present as covering the meeting.

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

Offering a speaker ID as replacement transcript text is a data defect, and an
earlier sheet did exactly that for all 293 conflicts on the measured run.

#### Text, selection and playback

- Transcript text is selectable. Selection is the reader's primary tool for
  moving text out of the app, so it outranks making the paragraph a click
  target. Playback is an explicit control: the time in the gutter plays from
  that segment, and the transport plays from the playhead.
- Playing a segment seeks the source file and keeps playing past the segment
  end, following the reader down the list and marking the segment the playhead
  is inside. Correction work is listening work; stopping after 4.9 seconds
  forces a click per segment.
- Playback offers pause and resume, and the playhead is visible in the header at
  all times, both as a time and as a position in the recording.
- Audio comes only from the source file. No screen writes to it.

#### Inspector

The inspector is **collapsed by default**. Opening it shows provenance as a
readable summary — status, duration, coverage in words, speakers, segments,
unattributed count, profile, models by role and model ID, glossary — and no run
ID, no SHA-256, and no format strings. Fingerprints sit behind one disclosure
labelled for what they are, and are selectable when opened.

**Derived sets** are listed under their own heading, one row each, and a row is
two lines when it has a second thing to say. The first line names the family —
*Speaker Proposal*, *Correct*, *Translate*, read from the operation's kind and
never from its mode — beside the month, day and time that set was made, and
marks the current set of its family with an accent check. The year is dropped:
it never tells two derived sets of one run apart, and at the inspector's
300-point minimum it pushed the time onto a second line, where two rows stopped
being comparable by eye. A speaker-proposal set carries a second line in the
secondary ink: how many segments it proposed a speaker for, how many it
declined, and the same *not acoustic evidence, and not measured* disclosure the
transcript surface prints over the proposed layer. Two proposal sets made
minutes apart carry distinct times, but what each one did is what a reader
chooses on.

#### Tokens

One token set, defined once in `AppTheme` and used by every view in this
surface, replacing per-view inline numbers. A stylesheet patched on top of an
older one is a defect in its own right; these are the base.

**Colour, resolved per appearance.** Every colour below has a light value and a
dark value. Text meets 4.5:1 and meaning-carrying marks meet 3:1 against the
page ground in both appearances, verified on rendered pixels rather than by
reading the values (results under *Judged from renders*). The grounds measure
white and `#1E1E1E`.

| token | light | dark | used for |
|---|---|---|---|
| ink | system primary label | system primary label | transcript text, names, figures |
| ink, secondary | `#5F5F5F` | `#A3A3A3` | times, counts, reasons, neutral chips, *Speaker not named*, unavailable tabs |
| hairline | `#DADADA` | `#3A3A3A` | row separators and the header rule, and nothing a reader has to see |
| control border | `#8A8A8A` | `#7A7A7A` | the edge of the search field, a step button, the play button |
| accent | `#0B57D0` | `#7AB8FF` | the focused row, the displayed tab, a checked box, the playing glyph |
| open | `#9E4B08` | `#F5A05A` | the navigator's flag, the *Wording* chip, the missing-range notice |
| speaker 1 | `#227E91` | `#1F96AD` | roster position 0 |
| speaker 2 | `#7F2CBA` | `#B26CE5` | roster position 1 |
| speaker 3 | `#BA2C67` | `#E15690` | roster position 2 |
| speaker 4 | `#2C2CBA` | `#7D7DE8` | roster position 3 |
| speaker 5 | `#A95E28` | `#D46E25` | roster position 4 |
| speaker 6 | `#1F8438` | `#1FAD42` | roster position 5 |
| speaker 7 | `#2C73BA` | `#3C8CDD` | roster position 6 |

The system secondary label colour is not used on this surface: it measures
3.95:1 in the light appearance, which is the single cause of most of the eight
light-appearance failures the first rework shipped with. Blue is absent from
the speaker palette because the accent is blue.

**Type.** Screen title 22 semibold; section title 13 semibold (was 15, so a
heading stops competing with the body it heads); transcript body 15 with 3 pt
line spacing; speaker name 13 semibold; meta and figures 12; label 11 heavy,
used only for chips and column headers. Numbers that align down a column are
set in tabular figures. Nothing a reader reads is smaller than 11, and 11 is
reserved for the heavy-weight label face.

**Spacing.** 4 / 8 / 12 / 16 / 24. Row vertical padding 12, column gap 8, gap
before the text 12, no inter-row spacing (the hairline is the separation).

**Radius.** Controls 4, chips 2, everything else 0. No pill exists.

**Layout.** One 860-point measure for the header and the list; gutter columns
14 / 48 / 132 / 76 as above.

**Glyphs.** One glyph, one meaning: a flag is review pending, a check is review
resolved, a checkbox is inclusion in a copy selection, a waveform is playing.

#### Judged from renders

D48 governs: this surface is judged by rendering it offscreen from the real
248-segment run at 820 and 1400 points in both appearances and reading the
images back, not by the maintainer. The render path is an `NSHostingView` laid
out offscreen and drawn with `cacheDisplay(in:to:)`, which needs no window
server and no Screen Recording permission. What that path draws, and what it
cannot, decides what an image is trusted to show:

- **Scroll views, grouped forms and typed-in controls draw.** `ScrollView`
  content, `Form(.grouped)`, `TextField`, `Slider` and a spinner all render, so
  the inspector is read as the grouped form the app builds, at 300 and 450
  points, and the search field and the transport slider are judged from pixels
  like everything else on this surface.
- **`List`, menus, sheets and hover are what an image cannot judge.** `List` is
  `NSTableView`-backed and comes back blank without a real window, so the
  library sidebar and the glossary list are rendered a row at a time; a context
  menu, a sheet and a confirmation dialog are presented by AppKit and never
  enter a render, so what they say is rendered as a plain view instead; and a
  hover-revealed affordance such as a tab or chip tooltip has no hover to
  reveal it. Those wait for the running app.

The shipped `TranscriptView` renders as itself, but its own `ScrollView`
settles at a non-zero offset offscreen and its `.navigationTitle` wrapper lays
the screen out taller than the frame, so that image starts part-way down the
list and carries no header. The images this section measures are composed from
the same shipped header and segment-column views the screen builds. SwiftUI's
own `ImageRenderer`, the path D48 first recorded, returns nothing at all for a
scroll container, a `List` or a grouped form and draws `TextField`, `Slider`
and AppKit-backed button styles as placeholder blocks; this surface's `.plain`
button styles were chosen under it, and one probe render of the same sample
down both paths is kept so the difference stays legible.

Measured on the real 248-segment run by rendering every row at the measure and
reading the heights back, header included, in a window 1000 points tall
(1400 points wide unless stated):

| measure | before (first rework) | after (this revision) |
|---|---|---|
| row pitch, attributed one-line segment | 79 pt | 43–44 pt |
| row pitch, unattributed segment (median) | 113 pt | 69 pt |
| row pitch, all rows (mean) | 100 pt | 62 pt (64 at 820) |
| transcript share of row pitch (median) | 24 % | 43 % |
| header height at 1400 / 820 pt | 166 / 212 pt | 111 / 145 pt |
| segments fully visible, 1000-pt window | 6 (82 s) | 9 (135 s) |
| segments fully visible, 820 pt wide | 6 (82 s) | 8 (120 s) |
| segments fully visible, 780-pt window | 5 (68 s) | 7 (108 s) |

The attributed one-line row is the 12 + 18 + 12 + 1 the tokens imply. The
unattributed row is the speaker line, the figures line and the band beside a
text that is usually one line, so the gutter sets its height. The mean sits
above the one-line pitch because 57 of the 248 segments wrap to two lines or
more at the 554-point text column; the measure is 860 and does not move, so
the density comes from the gutter, not from width. A 1400-point window shows no
more segments than a 908-point one.

Contrast, measured on the rendered pixels of the 1400-point source render and
the 820-point proposal render by finding every pixel painted in a token's
colour and comparing its median against the page ground:

| element | light | dark |
|---|---|---|
| ink: transcript, figures, available tab | 14.9:1 | 12.3:1 |
| secondary ink: times, counts, chips, *Speaker not named*, column headers, unavailable tabs, dashed proposal label | 6.4:1 | 6.6:1 |
| accent: focused time, focused rule, tab underline, checked box | 6.4:1 | 8.0:1 |
| open: navigator flag, missing-range notice | 6.1:1 | 8.0:1 |
| speaker 1 name and band | 4.7:1 | 4.8:1 |
| speaker 2 name and band | 7.1:1 | 4.9:1 |
| hairline (decorative, no floor) | 1.4:1 | 1.5:1 |

Every text element clears 4.5:1 and every band clears 3:1 in both appearances.
The same measurement on the first rework's renders: light teal name and band
1.9:1, purple name 3.0:1, secondary text 4.0:1, review flag 2.3:1, white on
the layer pill 3.5:1; dark purple name 3.1:1 and white on the pill 3.2:1.

What the renders could not show: the tab and chip tooltips, which need a
hover, and the pinned column header while scrolling, which the harness puts
back to the top before it draws. Those wait for the running app.

#### Decisions the renders forced

Recorded because the reasons are not visible in the result.

From the first rework's renders (2026-09-02):

- The reason sentence left the ordinary unnamed rows and stayed on the focused
  row and the two rare outcomes; a translation's rows never print it and the
  header states it once. An earlier predicate compared `nil` against one
  outcome, which is true, and put the sentence back under all 110 rows of the
  layer with the least to say — a regression test pins both halves.
- A contested share says what it measures; a bare `64%` beside a name reads as
  a confidence this product does not compute. The column header now carries
  that label once.
- Rows lost their card background: `controlBackgroundColor` resolves to the
  window colour in both appearances, so the card was invisible anyway.
- The speaker palette dropped blue, because blue is the accent.
- One glyph meant three things; the copy-selection control became a checkbox.
- An unnamed segment under a translation read "carries no recorded speaker
  evidence", which is false — the evidence is in the source run and the
  translation load path drops it. Absent evidence and unloaded evidence read
  differently.
- The header and the segment column sat on different axes; they now share one
  measure and one centring.

From the genre revision's renders (2026-09-02, this revision):

- The coloured left rule, the focused row's filled rounded surface, the layer
  bar's filled pill, the quaternary boxes around the transport, navigator and
  search field, and the orange flag on 192 rows are gone, each for the rule it
  broke above.
- The overlapped seconds moved from the row to the review sheet; the row
  prints the shares and the band.
- The `?` glyph beside *Speaker not named* was dropped: the words are the
  mark, and the glyph doubled a label that already says it.
- The first render of the table wrapped the focused row's time onto two lines
  and wrapped *Proposed, not measured* beside a longer name. The time column
  grew from 36 to 48 and the focused row lost its play glyph, keeping the
  accent and the weight; the proposal label never wraps and the name drops
  under it instead.

#### Reach of the token set

**Done, 2026-09-02.** The tokens are used by the transcript view, the review
sheet, the run inspector, the library sidebar, the capture view and the run
progress view. Settings is the one surface left on its own inline numbers, and
it is the one surface a reader never reads a transcript on.

What the last three surfaces were carrying, found by rendering them for the
first time rather than by reading their code:

- The system secondary label colour, on the inspector's values, on the failure
  screen's reason sentence and detail labels, and on the capture screen's
  progress line. It measures 2.5–3.0:1 on those grounds in the light
  appearance, which is the failure this document already named and banned from
  the transcript surface. All of it is now the secondary ink.
- The system orange, on the *Partial Transcript* title and the warning glyph
  beside an incomplete stage, at 2.3:1 — below even the 3:1 floor that applies
  to 34-point text. Both are now the open token, which is what the open state
  means everywhere else.
- The system red, on a failed run's title and stage glyph, at 3.6:1. Now the
  error token.

**A border that is the only thing marking a control is not decorative.** The
search field, the review navigator's two step buttons and the play button were
each drawn with the hairline at 1.4:1 light and 1.5:1 dark, and in each case
that border was the entire visual claim that the thing is operable. WCAG 1.4.11
asks 3:1 of exactly that, and the surface already contained the answer: the
review chip's outline is drawn in the secondary ink and measures 6.4:1. The
ruling is to keep the two apart rather than to raise one to the other:

- **hairline** stays decorative and keeps its 1.4:1. It separates rows and
  draws the header rule, where nothing depends on seeing it and a darker line
  would turn 248 rows into a grid.
- **control border** is a new token at 3.45:1 light and 3.88:1 dark, used
  wherever a stroke is the boundary of something a reader can type in, click
  or drag. It is deliberately below the secondary ink: a control's edge should
  be findable, not as loud as the text inside it.

The playhead is the one control this ruling could not reach by colouring a
border. The system `Slider` draws a near-white knob — 1.04:1 against the page
and 1.14:1 against its own track in the light appearance, at the position the
screen opens on — and its knob takes no tint. It is now drawn from the tokens:
a hairline track, an accent fill from the start to the current position, and an
accent knob with a page-coloured ring so it stays visible where it sits on top
of its own fill. Dragging it seeks, and it is one adjustable accessibility
element that steps by a twentieth of the recording.

**What is deliberately still not on the tokens, on those two screens.** Each of
these is a geometry or a control the token set does not reach, and each is
recorded rather than quietly left:

- The benchmark capsules and the two segmented pickers on the capture screen.
  Section 3 bans a pill and the capsule breaks it, but the pickers are AppKit's
  own control and cannot be restyled without replacing them, so changing only
  the chips would leave the clash half-fixed. Both wait for whoever reopens
  that screen's grammar.
- The prominent record button keeps the *system* tint. `.borderedProminent`
  paints a white label over its tint, and the accent token is a foreground
  colour chosen against the page: as a fill under that label its dark value
  measured 2.08:1 on the render. The system tint is the one thing there that
  adapts its own label.
- The outer 28-point screen padding, the 18-point card padding, the
  12-point card radius and the stage row's 11-point vertical padding. The
  radius is invisible in both appearances — `controlBackgroundColor` and
  `.background.secondary` resolve close enough to the window colour that the
  card has no visible edge — so moving them buys nothing a reader can see and
  moves every element on two screens.

#### Library maintenance, on the sidebar

Three gaps this document listed as promised-and-absent are built. They are
described here rather than specified, and the wording each was specified in was
followed exactly.

- **Rename** edits only `displayName` in the library index. It never renames the
  source file, the run directory, or any artifact. The new name is written to the
  index before it is adopted, so a save that fails leaves the old name.
- **Move to Trash** is two steps, and never a first-order action: a menu item
  opens a confirmation naming the recording and what will be moved, then one
  `NSWorkspace.recycle` call moves the run directory and the source audio
  together, so the Finder Trash and its Put Back remain the recovery path. A
  partial move is put back, and any failure leaves the library entry in place.
- **The Speaker-labelled layer beside a translation** is selectable. The loaded
  run carries the decoded source document, so the raw text is still in memory
  once a translation result is applied over it, and the layer needs no second
  read from disk.

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
