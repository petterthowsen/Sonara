# DAWproject Import and Export (core) — Requirements

## Problem

Sonara projects can't leave Sonara, and projects from other DAWs can't come in. DAWproject
(`.dawproject`, spec in `docs/dawproject/specification.md`) is the open exchange format that
Bitwig, Studio One, Cubase and others read and write. The prerequisites that blocked it are done:
the tempo map (spec 008), time signature changes (spec 009) and saved CLAP plugin state. This spec
covers the **core subset** from `docs/dawproject/sonara-gaps.md`: tracks, channels, routing, sends,
MIDI and audio clips, track automation, markers, tempo and signature maps, and devices with state.
Export and import both work on that subset, and each lists what it dropped or approximated.

## Scope

| | |
|---|---|
| Subsystem | Godot (engine only indirectly, through the existing plugin state save/load) |
| Touches real-time audio thread | no |
| Adds or changes an OSC message | no — expected; if design finds one is needed, it lists it |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | no change to `.sonara`. Adds a new file format (`.dawproject`) that Sonara reads and writes |

## Definitions

- **Core subset** — what this spec maps in both directions: see REQ-010 to REQ-024.
- **Transfer report** — the list of items an export or import dropped or approximated, each with
  the affected track/device/clip name and the reason. An empty report means nothing was lost.
- **Sonara built-in** — a device that isn't a CLAP plugin: `polysynth`, `delay`, `sfizz_device`,
  `sampler`, `drum_machine`, `layer`, `chain`, `spectrum_analyzer`.
- **Round trip** — export a `.sonara` project to `.dawproject`, import that file, and compare.
- **Beats** — quarter notes, as in DAWproject. 1 beat = 960 ticks.

## Requirements

### Export: entry and container

#### REQ-001 — Export menu entry

The File menu shall have *Export DAWproject…*, enabled only while a project is open. It opens a
save dialog filtered to `*.dawproject` and appends the extension when the user leaves it off.

- **Acceptance:** Godot test on the menu wiring (item exists, disabled with no project); live.

#### REQ-002 — Container

WHEN the user confirms the export dialog, the exporter shall write a ZIP file holding
`project.xml` (root `<Project version="1.0">`, `<Application name="Sonara" version="…">`) and
`metadata.xml` (root `<MetaData>`, `Title` = the project name), plus every embedded file the XML
references.

- **Acceptance:** Godot test — export a fixture project, reopen the ZIP, both entries parse, and
  every `File@path`/`State@path` with `external="false"` exists in the ZIP.

#### REQ-003 — Schema-valid output

The exported `project.xml` and `metadata.xml` shall validate against `Project.xsd` and
`MetaData.xsd` (appendix of `docs/dawproject/specification.md`), including element order.

- **Acceptance:** `xmllint --schema` on the exported files from every export test fixture passes.

#### REQ-004 — Export does not change the project

Exporting shall not modify the open project, mark it modified, or change its `.sonara` path.
Before writing, it shall refresh CLAP plugin states the same way *Save* does.

- **Acceptance:** Godot test — `is_modified` and `project.to_json()` are identical before and
  after export.

#### REQ-005 — Export failure

IF the target file can't be written, THEN the exporter shall show an error naming the path and
reason, and shall leave no partial file behind.

- **Acceptance:** Godot test — export to an unwritable directory returns an error and creates no
  file.

### Import: entry and container

#### REQ-006 — Import menu entry

The File menu shall have *Import DAWproject…*, always enabled. It opens a file dialog filtered to
`*.dawproject`.

- **Acceptance:** Godot test on menu wiring; live.

#### REQ-007 — Import opens a new unsaved project

WHEN an import succeeds, the editor shall close the current project (as *Open* does) and open the
imported one with no `.sonara` path, named after the file's `Title` (or the file name when
`Title` is empty). *Save* then behaves like *Save As*.

- **Acceptance:** Godot test — after import, `Sonara.editor.project_path == ""` and the project
  name matches the fixture's `Title`.

#### REQ-008 — Invalid file

IF the file isn't a ZIP, lacks `project.xml`, has malformed XML, or has an unresolvable IDREF,
THEN the importer shall show an error naming the problem and shall leave the current project
open and unchanged.

- **Acceptance:** Godot test with one broken fixture per case; the open project is untouched.

#### REQ-009 — Embedded audio extraction

WHEN an imported project contains embedded audio, the importer shall extract it to a folder named
`<file name> Audio` next to the `.dawproject` file, keeping the in-ZIP relative paths, and audio
clips shall reference the extracted files. External audio references (`external="true"`) shall
resolve relative to the `.dawproject` file, or as absolute paths. IF the folder can't be created
or written, THEN the importer shall ask the user for another folder; cancelling aborts the import
as in REQ-008.

- **Acceptance:** Godot test — importing `Song.dawproject` with `audio/a.wav` creates
  `Song Audio/audio/a.wav` and the clip's `audio_file_path` points at it.
- **Example:** `~/dl/Song.dawproject` → `~/dl/Song Audio/audio/Drumfunk3 170bpm.wav`.

### Core subset (both directions)

Each requirement below holds for export **and** import unless it says otherwise.

#### REQ-010 — Transport

Static tempo and time signature shall map to `Transport/Tempo` (unit `bpm`) and
`Transport/TimeSignature`.

- **Acceptance:** round-trip test — tempo 137.5 and 7/8 come back unchanged.

#### REQ-011 — Tempo map

The tempo map shall map to `Arrangement/TempoAutomation`: each point to a `RealPoint` at its beat
position. Sonara ramps between points are `linear`. On import, a step (a `hold` segment, or two
points at the same time, which is how Bitwig writes a jump) shall be kept as a jump within one
tick, and the first point sets the tempo at beat 0 if it lies later.

- **Acceptance:** round-trip test with a 3-point ramp. Import of the Bitwig fixture: 110 BPM up
  to beat 4, 79.02 BPM from beat 4, with the jump no more than one tick wide.

#### REQ-012 — Time signature map

Signature changes shall map to `Arrangement/TimeSignatureAutomation` at the beat position of
their bar. On import, a point that doesn't fall on a bar line shall move to the next bar line and
be reported.

- **Acceptance:** round-trip test (4/4 → 7/8 at bar 5 → 4/4 at bar 9); import test with an
  off-bar point.

#### REQ-013 — Tracks and nesting

Audio and instrument tracks shall map to `Track` with `contentType` `audio` or `notes`, keeping
name, color and order. Folder and group tracks shall map to a `Track` with `contentType="tracks"`
holding their children as nested `Track`s, and back.

- **Acceptance:** round-trip test on a project with a folder holding a group holding two tracks;
  names, colors, types, order and parents match.

#### REQ-014 — Channels and master

Each track's channel shall map to the `Track`'s `Channel` with volume (`linear`, 0–2), pan
(`normalized`, 0.5 = center), mute and solo. The master channel shall map to a `Track` whose
channel has `role="master"`. Bus channels without a track shall export the way Bitwig writes FX
channels: a `Track` (`contentType="audio"`, no clips) whose channel has role `effect` when the bus
is only a send target and `submix` otherwise. On import, a `Track` whose channel has role
`effect` or `submix` and that isn't a folder shall become a Sonara bus channel with no track; any
clips on it are reported and dropped.

- **Acceptance:** round-trip test — volume −6 dB, pan −0.5, mute, solo come back within 0.01 dB
  and 0.001 pan. Import of the Bitwig fixture: *Apricot* at −6.02 dB, *Reverb* as a bus with
  its channel's volume at 0 dB, *Master* as the master channel.
- **Example:** Sonara volume −6.0 dB ↔ `Volume value="0.501187"`; pan −0.5 ↔ `value="0.25"`.

#### REQ-015 — Routing and sends

Channel output routing shall map to `Channel@destination`, and sends to `Send` with `Volume`
(`linear`, 0–1 as Bitwig writes it), `Enable` (= not muted), `type` (`pre`/`post`) and
`destination`. On import, volumes above +12 dB are clamped to +12 dB and reported. Bitwig writes a
send from every channel to every FX channel, so a send that is disabled with volume 0, or that
targets its own channel, shall be skipped without a report entry.

- **Acceptance:** round-trip test with track → bus → master routing and a pre-fader send at
  −12 dB. Import of the Bitwig fixture: *Apricot* has one send to *Reverb* at −22.85 dB
  (0.071991 linear); *crash_cymbal_crash_01* and *Reverb* have no sends.

#### REQ-016 — MIDI clips and notes

MIDI clip instances shall map to `Clip` elements (time, duration, `playStart` = left trim, loop
region, fades, `enable` = not muted) holding `Notes`. Notes keep key, start, duration and
velocity (0–127 ↔ 0–1, rounded on import).

- **Acceptance:** round-trip test — every note's key, start and duration exact, velocity ±0.
  Import of the Bitwig example in the spec: 3 notes at beats 0, 1, 1.5.

#### REQ-017 — Shared clips

Two or more instances of one Sonara clip shall export as one content timeline with an `id`, and
the other instances as `Clip@reference` to it. On import, clips referencing the same timeline
shall become instances of one shared Sonara clip.

- **Acceptance:** round-trip test — three instances of one clip come back sharing one clip id.

#### REQ-018 — Audio clips

Audio clip instances shall map to a `Clip` holding `Warps` (`contentTimeUnit="seconds"`) around
an `Audio` element, with two `Warp` events giving the clip's stretch from its recorded BPM. On
export the audio file is embedded under `audio/`, once per distinct source file. On import, audio
without `Warps` (Bitwig writes a nested `Clip` with `contentTimeUnit="seconds"` and
`algorithm="raw"`) shall take its stretch from the ratio between the clip's beat duration and its
content length in seconds, so it plays over the same beats as in the source.

- **Acceptance:** round-trip test with a 120 BPM loop in a 100 BPM project: position, length,
  trim and stretch ratio match. The ZIP holds one copy of a file used by two clips. Import of the
  Bitwig fixture: the crash sits at beat 4 (tick 3840), lasts 1.8333 beats, and plays its 1.0 s
  file across them.

#### REQ-019 — Track automation

Automation lanes for channel volume, channel pan, send level and device parameters shall map to
`Points` in the track's lanes, with a `Target` pointing at that parameter's `id` and values in its
real unit. `STEP` points map to `hold`, `LINEAR` to `linear`. On export, a curved segment
(tension ≠ 0) shall be written as extra linear points that stay within 1% of the curve.

- **Acceptance:** round-trip test for each target kind; unit test that a tension 0.7 segment is
  approximated within 1% at 100 evenly spaced samples. Import of the Bitwig fixture: *Apricot*'s
  send-level lane ramps 0 → 1.0 linear (−60 … 0 dB in Sonara terms) over beats 0–8, and the
  crash track's volume lane ramps 0.501187 → 0 over beats 4–8.

#### REQ-020 — Markers

Song markers shall map to `Markers/Marker` (name, color, start). Marker durations are not
exported, and imported markers have duration 0.

- **Acceptance:** round-trip test; name, color and start match.

#### REQ-021 — CLAP plugins

CLAP devices shall map to `ClapPlugin` with `deviceID` = CLAP ID, `deviceName`, `deviceRole`
(`instrument` for instruments, `audioFX` otherwise), `Enabled`, and a `State` file holding the
plugin's saved state in the `.clap-preset` format (the bytes `clap`, a big-endian u32 length,
the CLAP id, then the plugin's raw state stream, as found in the Bitwig fixture). Automated
parameters shall appear in
`Parameters` as `RealParameter` with `parameterID` = the CLAP param id. On import, a CLAP plugin
that is installed shall load with that state.

- **Acceptance:** round-trip test (headless: state bytes identical after round trip). Live:
  importing the Bitwig fixture loads Apricot with the patch *Elder's Wisdom*, and an Apricot patch
  exported from Sonara opens with the same patch in Bitwig.

#### REQ-022 — Sonara built-ins

Sonara built-ins shall export as `BuiltinDevice` with `deviceID="sonara.<device id>"` and a
`State` file holding the device's Sonara JSON, children included. Files the device loads (SFZ,
samples) shall be embedded and restored on import. Importing a `BuiltinDevice` with a `sonara.`
id shall rebuild the device from that JSON.

- **Acceptance:** round-trip test — a channel with polysynth → delay, and a drum machine with two
  sampler pads, come back with the same parameter values and structure; the sampler's WAV is
  extracted next to the import.

#### REQ-023 — Transfer report on import

WHEN an import finishes, the editor shall show the transfer report when it isn't empty. Items that
shall be reported (and otherwise dropped or approximated): non-CLAP plugins (VST2/VST3/AU), CLAP
plugins that aren't installed, generic built-ins (`Equalizer`, `Compressor`, `NoiseGate`,
`Limiter`) and other vendors' `BuiltinDevice`s, warps with more than two events (approximated by
the first-to-last ratio), notes with a MIDI channel other than 0 or a release velocity, per-note
expressions, clip-level automation, expression-target automation (CC, pitch bend, …), send pan,
mute and bypass automation, crossfades (imported as overlapping clips with ordinary fades), VCA
channels, scenes and clip slots that hold a clip, mono channels (imported as stereo), clips on
bus tracks, and time signature points off a bar line. A release velocity counts only when it
differs from the note-on velocity (Bitwig writes `rel` = `vel` by default). Repeats of one kind
on one track or device are one entry with a count, e.g. *"Lead: 212 notes on MIDI channel 2
moved to channel 0"*.

- **Acceptance:** Godot test — a fixture holding one of each item produces one report entry per
  item, naming it; the rest of the project still imports. Import of the Bitwig fixture: one entry
  for the non-Sonara `BuiltinDevice` *Reverb*, and nothing for its empty scenes, default sends or
  `rel` values.

#### REQ-024 — Transfer report on export

WHEN an export finishes, the editor shall show the transfer report when it isn't empty. Items
that shall be reported: marker durations, clip instance transpose (written by transposing the
exported notes, so that instance no longer shares its clip), clip instance gain offset (dropped),
pan modes other than balance and mono (position only), hardware output routing (exported to
master), phase invert, and CLAP plugins whose state couldn't be fetched.

- **Acceptance:** Godot test — a fixture with each item produces one entry per item.

### Round trip

#### REQ-025 — Sonara round trip

Exporting a project and importing the result shall reproduce the core subset: the same tracks,
channels, routing, sends, clips, notes, automation, markers, tempo and signature maps, and
devices with their state, within the tolerances in REQ-014 to REQ-022.

- **Acceptance:** one Godot test that builds a project using every core-subset feature, round
  trips it, and compares field by field.

#### REQ-026 — Bitwig interop

A project exported from Sonara shall open in Bitwig Studio with its tracks, clips, notes, audio,
automation and CLAP plugins in place, and a project exported from Bitwig Studio shall import into
Sonara with the same.

- **Acceptance:** live, in Bitwig Studio, both directions, on one project with a CLAP instrument,
  an audio loop, a bus with a send, volume automation and a tempo change.

## Non-functional

- **Real-time safety:** unchanged — import and export run on the Godot side and reach the engine
  only through the existing project load path and plugin state save/load.
- **Latency / performance:** exporting or importing a 50-track project with 200 MB of audio may
  block the UI; it shall not take more than the file copy itself plus 2 s. No progress UI in this
  spec.
- **Compatibility:** `.sonara` files are unchanged. Imports accept any DAWproject 1.0 file,
  ignoring unknown elements and attributes.

## Out of scope

- The **[fidelity]** and **[later]** items in `docs/dawproject/sonara-gaps.md`, beyond reporting
  them (REQ-023/024): generic EQ/compressor/limiter/gate devices, clip-level MIDI CC and pitch
  bend playback, release velocity, per-note MIDI channel, send pan, mute and bypass automation,
  VCA channels, crossfades, time-locked (seconds-based) clips, missing-plugin placeholders, VST3
  hosting, video, scenes.
- Merging an imported project into the open one.
- A progress bar or cancel button for long imports and exports.
- `metadata.xml` fields beyond `Title`.
- Referencing audio externally on export (always embedded).

## Open questions

- [x] **`.clap-preset` content.** Resolved from `sonara_test_01.dawproject` (Bitwig 6.0.11):
  `clap` magic, big-endian u32 id length, the CLAP id, then the raw state stream (REQ-021).
- [x] **Bus role.** Only send targets → `effect`, otherwise `submix` (REQ-014).

## Reference fixture

`sonara_test_01.dawproject`, exported from Bitwig Studio 6.0.11 by the user: Apricot (CLAP) on a
notes track with two 4-beat clips, an audio track with a 1 s crash at beat 4, a *Reverb* FX track
(Bitwig built-in), a send with level automation, volume automation, and a tempo jump from 110 to
79.02 BPM at beat 4. It will be copied into the Godot test fixtures.
