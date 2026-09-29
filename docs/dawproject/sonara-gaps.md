# DAWproject support: gap checklist

What Sonara needs to import and export `.dawproject` files, measured against
[specification.md](specification.md). Audited against the code on 2026-09-30 (`14eddd5`); check
the claims against the source before starting an item.

Legend: **[core]** needed for a useful first version of import/export. **[fidelity]** loses data
without it, but a round-trip still works. **[later]** rarely used, or a whole feature Sonara
doesn't have.

## Already maps directly

These need only translation code, no new features:

- Tempo and time signature (static values): `Project.tempo`, `time_numerator/denominator`.
  Beats = ticks / 960.
- Tracks with name and colour, folder and group tracks (`Track.TrackType.FOLDER/GROUP` ↔
  `contentType="tracks"` with child `<Track>`s).
- Channels: volume, pan, mute, solo, output routing (`output_channel_id` ↔ `destination`),
  master (ID 1 ↔ `role="master"`), buses (↔ `effect`/`submix`).
- Sends with level, pre/post and mute (`SendConfig.pre_fader`, `muted` ↔ `Enable`).
- Clip pool with shared clips (`ClipInstance.clip_id`) ↔ alias clips via `Clip@reference`.
- Clip instance position, length, left trim (`clip_offset` ↔ `playStart`), loop region, fade
  in/out, mute (↔ `enable="false"`).
- Notes: key, start, duration, velocity (0–127 ↔ normalized 0–1).
- Audio clips referencing a file, with a constant stretch (`recorded_bpm` ↔ a two-point
  `Warps`).
- Track automation for channel volume, pan, send level and device parameters, with linear and
  step (`hold`) points.
- Song markers at a position (`SongMarker`).
- CLAP plugins (`ClapPlugin@deviceID` = CLAP ID; CLAP param ID ↔ `parameterID`).
- ZIP read/write is available in Godot (`ZIPPacker`/`ZIPReader`).

## Missing

### Infrastructure

- [ ] **[core]** A DAWproject reader and writer: unzip, parse `project.xml` and `metadata.xml`,
  resolve `id`/IDREF (forward references included), resolve nested `timeUnit` /
  `contentTimeUnit` scopes, and write the container with embedded files. Decide where it lives
  (Godot `XMLParser` + `ZIPReader` is enough; no engine change is needed for the file format
  itself).
- [ ] **[core]** File menu entries: *Import DAWproject…* and *Export DAWproject…* next to the
  `.sonara` dialogs in `Godot/editor/MainMenu.gd`.
- [ ] **[core]** Import report: list what was dropped or approximated (unsupported plug-in
  formats, missing plug-ins, seconds-based content, flattened nesting) instead of failing
  silently.
- [ ] **[core]** Unit conversion layer between DAWproject real units and Sonara values:
  channel volume `linear` (0–2) ↔ dB (Sonara clamps to −60…+12 dB); pan `normalized` 0–1 ↔
  −1…+1; send level; normalized device parameters (ADR-0005) ↔ each `RealParameter`'s
  `unit`/`min`/`max`.
- [ ] **[core]** Audio file embedding on export (copy sources into `audio/…` in the ZIP) and
  extraction on import to a project-local folder, plus `external="true"` relative/absolute
  paths.
- [ ] **[core]** Round-trip test fixtures: generate the upstream reference files
  (`DawProjectTest.java` in bitwig/dawproject) and add Godot tests that import them and
  re-export.

### Plug-in state

- [ ] **[core]** **Sonara does not save CLAP plug-in state in `.sonara` projects today.**
  `DeviceInstance.to_json()` stores only `parameter_values`. The engine already supports
  `/plugin/save_state` → `/plugin/state/saved` (base64) and `/plugin/load_state`, but nothing in
  Godot calls them. DAWproject requires the full state as an embedded file, so this has to work
  first (and it fixes native projects too).
- [ ] **[core]** Carry large states: plug-in states can be hundreds of KB, well over a safe UDP
  datagram (ADR-0003, OSC over localhost UDP). Needs chunking or a file-based hand-off (engine
  writes the state to a temp file and sends the path).
- [ ] **[core]** Write and read the `.clap-preset` format the spec asks for. Verify whether it
  is the raw `clap_plugin_state` stream or a wrapped container (check Bitwig output and the
  CLAP `preset-load` extension) before implementing.
- [ ] **[fidelity]** `Parameters` list on export: every automated device parameter needs a
  `<RealParameter id=… parameterID=… unit=… min=… max=…>` so automation can target it. CLAP
  gives min/max/default but no unit; export `unit="linear"` with the plug-in's native range.
- [ ] **[fidelity]** Device metadata: `deviceVendor`, `pluginVersion`, `deviceRole`
  (Sonara's `DeviceCategory` Instrument/Effect/Utility → `instrument`/`audioFX`; nothing maps
  to `noteFX`/`analyzer` except `spectrum_analyzer`).
- [ ] **[fidelity]** Missing-plug-in placeholder: keep an unloadable device (unknown CLAP ID,
  or VST2/VST3/AU) in the chain with its state blob, so re-export does not lose it. Sonara
  hosts CLAP only.
- [ ] **[later]** VST3 hosting (the most common format in files from Cubase and Studio One).
  Without it those devices can only be placeholders.

### Built-in devices

- [ ] **[fidelity]** Generic `Equalizer` (bands: highPass, lowPass, bandPass, highShelf,
  lowShelf, bell, notch; Freq/Gain/Q/Enabled; input and output gain). Sonara has no EQ.
- [ ] **[fidelity]** Generic `Compressor` (threshold, ratio, attack, release, in/out gain, auto
  makeup). Sonara has none.
- [ ] **[fidelity]** Generic `Limiter`. Sonara has none.
- [ ] **[fidelity]** Generic `NoiseGate` (includes `Range`). Sonara has none.
- [ ] **[fidelity]** Export Sonara built-ins (`polysynth`, `delay`, `sfizz_device`, `sampler`,
  `drum_machine`, `layer`, `chain`, `spectrum_analyzer`) as `BuiltinDevice` with a vendor state
  file, so a Sonara → Sonara round-trip keeps them. Decide what the state file is (the device's
  JSON). SFZ and sample files it references must be embedded too.
- [ ] **[later]** Container devices (`layer`, `drum_machine`, `chain`) have no DAWproject
  equivalent. Other DAWs will drop them; consider exporting a flattened chain as a fallback.

### Transport, tempo and markers

- [ ] **[core]** Tempo changes (`Arrangement/TempoAutomation`). Sonara has one static tempo in
  `Project.tempo`, and the engine one `SetTempo(f32)`. Needs a tempo map in the engine clock
  (ADR-0007) and in `GridHelper` tick↔time conversion. Also needed to convert `seconds`-based
  content to beats on import.
- [ ] **[fidelity]** Time signature changes (`TimeSignatureAutomation`). Sonara has one
  static signature.
- [ ] **[fidelity]** Marker ranges: `SongMarker` has `duration_ticks`, DAWproject markers are
  points. On export, write the start only (maybe an extra `"<name> end"` marker); on import,
  set duration 0.
- [ ] **[later]** `metadata.xml` fields (Title, Artist, Album, Composer, Year, Genre,
  Copyright, Comment, …). Sonara stores only `project_name`. Add a project info dialog, or at
  least map Title ↔ `project_name`.

### Mixer

- [ ] **[fidelity]** Send pan (`Send/Pan`). `SendConfig` has no pan.
- [ ] **[fidelity]** Mute automation (`BoolParameter` target). `AutomationTarget.Kind` has
  only CHANNEL_VOLUME, CHANNEL_PAN, SEND_AMOUNT, DEVICE_PARAM.
- [ ] **[fidelity]** Device bypass automation (`Device/Enabled` as a target).
- [ ] **[fidelity]** Pan mode mapping: DAWproject has one pan value. Export
  `STEREO_BALANCE`/`MONO` as is; `STEREO_COMBINED` (width) and `STEREO_DUAL` lose information.
  Decide on the lossy mapping and document it.
- [ ] **[fidelity]** Mono channels (`audioChannels="1"`). Sonara channels are stereo.
- [ ] **[later]** VCA channels (`role="vca"`). Sonara has none; import could drop them and
  bake their gain into the controlled channels.
- [ ] **[later]** Hardware outputs (Sonara channel IDs ≥ 1000, `device_output_id`) and
  `phase_invert` have no DAWproject equivalent. Export routes to master; keep them only in the
  Sonara-specific state.

### Notes and MIDI

- [ ] **[fidelity]** Release velocity (`Note@rel`). `MidiNoteData` has no note-off velocity.
- [ ] **[fidelity]** Per-note MIDI channel (`Note@channel`). `MidiNoteData` has none; notes
  on channels other than 0 would be merged.
- [ ] **[fidelity]** Fractional velocity: DAWproject is continuous 0–1, Sonara is 0–127
  integers. Rounding is acceptable; note it in the import report only if MPE/high-res matters.
- [ ] **[fidelity]** MIDI CC, pitch bend, channel pressure and program change **in clips**
  (`Points` with `expression=channelController|pitchBend|…` inside a `Clip`). `Clip.midi_events`
  exists and is saved, but no engine playback path for clip CC events was found. Verify, then
  add playback and editing.
- [ ] **[fidelity]** The same MIDI expressions as **track** automation (`Points` in the
  track's lanes targeting an expression rather than a parameter). Sonara can target a device's
  CC *parameters* (SFZ), not a raw MIDI expression on the track.
- [ ] **[later]** Per-note expressions (`Points` inside a `Note`: gain, pan, transpose, timbre,
  pressure, formant, polyPressure). Needs MPE / CLAP note-expression support in the engine.

### Clips and audio

- [ ] **[core]** Variable time warping (`Warps` with more than 2 events). Sonara supports one
  constant stretch factor from `recorded_bpm`. Import can fall back to the average ratio
  between the first and last warp and report it.
- [ ] **[fidelity]** Seconds-based clip placement (`timeUnit="seconds"` timelines, and audio
  not locked to tempo). Sonara positions everything in ticks; needs the tempo map to convert,
  and has no "time-locked" clip mode.
- [ ] **[fidelity]** Crossfades (negative `fadeInTime`). Sonara has per-clip fades but no
  crossfade concept; import can overlap the clips with ordinary fades.
- [ ] **[fidelity]** Nested clip timelines (Bitwig puts a `Clips` of audio events inside each
  arrangement clip). Import must flatten them into separate Sonara clip instances;
  export can write the flat form.
- [ ] **[fidelity]** Clip-level automation (`Points` inside a clip, e.g. volume or a device
  parameter). Sonara automation lives on tracks only; import must flatten into the track lane
  at the clip's position.
- [ ] **[fidelity]** Per-instance gain and transpose (`ClipInstance.gain_offset`, `transpose`)
  have no DAWproject attribute. Export gain as clip-level `gain` expression points or bake it;
  bake transpose into note keys.
- [ ] **[fidelity]** Automation tension: Sonara points have a `tension` curve; DAWproject has
  only `hold`/`linear`. Export must resample curved segments into extra linear points.
- [ ] **[fidelity]** Comments on tracks, channels, clips (`Nameable@comment`). Sonara has no
  comment field.
- [ ] **[later]** Video tracks (`Video`, `contentType="video"`).
- [ ] **[later]** Audio `algorithm` (vendor stretch algorithm). Store and pass through only.

### Clip launcher

- [ ] **[later]** Scenes and clip slots (`Scenes`, `Scene`, `ClipSlot@hasStop`). Sonara has no
  clip launcher. Import can drop them or lay each scene out sequentially on the arrangement.

## Suggested order

1. Persist CLAP plug-in state in `.sonara` projects (needed anyway), including large states.
2. Export only: tracks, channels, routing, sends, MIDI and audio clips, track automation,
   markers, CLAP devices with state, embedded audio. Validate the output against `Project.xsd`
   and open it in Bitwig or Studio One.
3. Import of the same subset, with the import report.
4. Tempo map (unlocks tempo automation, seconds-based content and variable warps).
5. Generic EQ / Compressor / Limiter / Gate built-ins, clip MIDI CC playback, release
   velocity and MIDI channel.
6. The **[later]** items as their features arrive.

Items 1 and 4 cross the Engine/Godot boundary and change the `.sonara` format, so they should
go through a spec under `docs/specs/` first.
