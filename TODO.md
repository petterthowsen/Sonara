# TODO

[ ] is open, [x?] implemented but not verified, [x] is verified, [/] is mixed status.

## Codebase Audit

- [ ] Full audit of `Godot/` for file structure and code organization issues: folder layout and naming, misplaced or oversized scripts, duplicated logic, dead code, and code that breaks the data-model/UI split
- [ ] Full audit of `Engine/` for the same: module layout, oversized files (e.g. `osc/server.rs`), duplicated logic, dead code and unused dependencies
- [ ] migrate TODO.md to gh issues.
## Audio Engine

### Mixing & Playback

- [ ] Plugin latency compensation
- [x] Time signature changes: a lane in the arranger ruler (below the bar/beat ruler, above the tempo lane); the arranger grid, BBT readout and the engine's transport info follow the changes. Spec: `docs/specs/009-time-signature-map/`
- [x] Tempo map playback: the engine clock, audio clips, playhead and time ruler follow the tempo lane; devices and CLAP plugins receive transport info (tempo, ramp, position, bar, time signature) every block. Spec: `docs/specs/008-tempo-map-engine/`
- [ ] Pan modes: Stereo Balance (default), Cubase-style Stereo Combined (position + width), Stereo Dual and Mono. Covers the mixer UI for all four modes, undoable mode switches, migrating old Combined projects to Balance, and AI `set_mixer` pan-mode support. Spec: `docs/specs/005-pan-modes/`
- [x?] Send knobs: right-click opens a menu with a Pre-Fader toggle (undoable, disabled until the send exists); pre-fader sends draw their knob arc in blue. `Godot/tests/test_sends_panel.gd`
- [x?] Send knobs work in dB (-inf to +12 dB): the tooltip reads dB ("-inf dB" at the bottom), double-click takes a dB value, Ctrl+click resets to -inf
- [x] Bug (`city_pop_5` project): soloing the Reverb channel appears to stop processing the Drum channel even though Drums sends into it. Solo now uses reach flags per channel (`solo_up`: carries soloed audio, `solo_down`: leads to a soloed channel); a route or send stays when its source is up or its target is down. Fixes a group bus that sends into a soloed reverb (it and its feeders were muted). Covered by `soloed_reverb_*` tests in `mixing.rs`
  - [ ] Optional, no longer jitter-related: OSC receive runs in `OSCServer._process()` on the main thread, so every message is delayed up to a frame. Affects parameter changes and meters too. Note `AudioEngineOSC.gd:70` claims a polling thread that doesn't exist
- [ ] Bug: a bus can't send to another bus. The UI allows it, but no audio arrives. The engine mixes bus → bus sends correctly (`bus_sends_to_another_bus`, `bus_pre_fader_send_carries_bus_device_output` tests), so if this still happens the cause is on the Godot/OSC side
  - [ ] Decide the constraints: can a delay bus and a reverb bus send to each other? Check how other DAWs handle feedback loops (reject cycles, or allow with a one-buffer delay) and what it means for routing latency
- [x] Mixing: pre-fader send audio is copied before the device pre-pass, so pre-fader sends from instrument channels are silent. The copy is now taken after each channel's devices run (`copy_pre_fader`); route targets copy it in the routing pass, after their fader (applied as inputs mix in) and before pan
- [x] Stop, pause and seek no longer reset every device, which cut off instrument releases and effect tails (delay buffers, CLAP `Reset`). Clip notes are counted per channel (`Channel::held_clip_notes`) and released with note-offs; live MIDI keeps playing. Idle chains still sleep after ~3 s of silence via `DeviceSleepState`
- [ ] Read MIDI input directly in the engine instead of through Godot (Godot adds up to a frame of jitter)
- [x?] Make sample rate and buffer size configurable: Settings › Audio › Output (device, sample rate, buffer size) applies live; the engine prepares devices and re-activates plugins for a new rate, reloads clips, lists the device's output pairs for master (1000 = 1/2, 1001 = 3/4, …) and grows its buffer when PipeWire's quantum doesn't fit. See `docs/engine-stability-plan.md` Phase 7
  - [ ] Live check through the Godot UI: switch device, 44.1 ↔ 48 kHz and buffer size during playback; clips at the right pitch, plugins keep their state, settings survive a restart

### Audio Thread

Phased plan for this section, plugin hosting rework and audio device settings: `docs/engine-stability-plan.md`

- [ ] Remove the shared `Arc<Mutex<EngineState>>` (phase 2): the audio thread should own its state and drain a lock-free command queue, with removed objects sent back to be dropped off-thread
  - [ ] Phase 1, partly verified live (CLAP on a bus, large clip import during playback): slow commands (plugin scan, device create/drop, plugin GUI/activation IPC) run outside the lock in `CommandWorker`; the callback uses a bounded `try_lock` and outputs silence
- [x?] Audio thread allocations still left: unbounded status channel sends, `process_device_chain` sleep-change Vec, `audio_playback_positions` insert (String clone) on clip start, `poll_parameter_changes` sets a socket read timeout every buffer per CLAP plugin (Phase 1 of the stability plan; verify with `SONARA_FEATURES=rt-debug`)
  - [ ] Known left: `poll_device_data` (spectrum analyzer) allocates its payload while a view is subscribed
  - [ ] Removed, needs live verification: per-buffer Vecs/HashMaps and buffer clones in `process_audio`/`mix_and_output`, debug `info!` logging in the callback
- [ ] CPU affinity for audio thread and plugin processing
- [ ] Realtime thread priority configuration
- [ ] CPU core assignment for plugin processing

### Devices & Plugins

- [ ] DeviceInstance and their UIs should init with loading state and wait for Engine updates
- [ ] Multi-in and multi-out for devices
  - [ ] CLAP extra output ports into shared memory (child return channels are created when `audio_out_channels > 2`)
- [ ] Add support for enum parameter type for builtins
- [ ] In Engine: Simplify device advertisement to avoid creating temporary instances
- [x?] CLAP processing is synchronous per block (per-block handshake over shared memory, sample-accurate notes/automation, one callback deadline). Verified live with 5 instances, 60 s playback: 0 dropouts, 0 xruns. Missing: audible null test and an end-to-end MIDI-offset check. See `docs/engine-stability-plan.md` Phase 3
- [ ] Crash / Error handling, send info to Godot for UI notifications
  - [x?] A crash report names the host's log file, and a plugin that keeps missing its deadline is flagged (amber ring on the device light)
  - [x?] Plugin hosting modes like Bitwig: Settings › Audio › Plugin Hosting (Individually, By plug-in, By vendor, Together) plus "Always host individually" per plugin in the device menu. Changes move loaded plugins live and keep their state; a shared host crash shows one popup and one Reload restores every plugin in it. See `docs/engine-stability-plan.md` Phase 5
- [ ] Plugin GUI windows should be forced to stay above Godot App
- [x?] Plugin state persistence: CLAP plugin state is saved into `.sonara` projects and restored on load (`{device}/state/save` and `{device}/state/load`, which pass the blob as a file)
- [ ] Sforzando CLAP GUI embeds but renders black
- [x?] Improve logging of plugins: each plugin host writes `Engine/logs/plugins/<host>-<pid>.log` with the plugin named on every line, forwards warnings to Godot's `/log`, and reports per-plugin DSP load and dropouts (device header tooltip, EnginePanel). `plugin_host --probe` tests a plugin standalone; `SONARA_PLUGIN_HOST_WRAPPER` / `SONARA_PLUGIN_HOST_WAIT` run hosts under a debugger. See `docs/engine-stability-plan.md` Phase 6

### Built-in Devices

- [/] Effects suite (spec 012, `docs/specs/012-builtin-effects/plan.md`): Delay v2, EQ, Compressor, Filter, Chorus, Phaser, Reverb, external sidechain
  - [x] Phases 1-7 (Delay v2, EQ, Compressor, Filter, Chorus, Phaser, Reverb): merged, covered headless, and tested live
  - [ ] Chorus Ensemble mode is over its CPU budget (0.35 % vs 0.3 %)
  - [ ] Phase 8: external sidechain (may become spec 013)
- [ ] Limiter
- [ ] Saturator
- [ ] L/R and M/S modes

---

## Godot

### [ ] Channel & Track enabled/visible system

We should have two states on both tracks and channel.

Visibility, which is visual only, and can be useful in certain scenarios during editing of clips etc. Visibility is toggled any time via context menu (both TrackItem and MixerChannel), channel-linked tracks stay in sync of course (bidirectionally), though that behavior could be a configurable setting under Behavior. Visibility on Group and Folder hides/shows the children.

Enabled status is similar to visibility except it deactivates all the devices on the channel and child channels, saving RAM. Quite useful for large templates where only the most used are enabled and less common ones can progressively be enabled. 

To make it possible to bring them back, two toggles at the bottom of the Arranger and the Mixer, using a suitable icon.
### Mixer & Tracks

- [x?] Master track doesn't accept device drops on its device lane and compact device list. Master track should accept devices. `DeviceDropUtil.device_fits_channel` now lets effects (and moved devices) onto master; instruments are still refused (master has the default INSTRUMENT type, so it is excluded by id). The engine already runs master's chain as a route target.
- [x?] Bug: moving a device sometimes leaves a stray device visual on the DeviceLane; it goes away when switching channel. `Channel.device_removed` passes the device *type* id, but `DeviceLane` matched it against instance ids, so a move into a container never removed the root panel. The compact `ChannelDeviceList` matched by position after reindexing and could free the wrong panel. Both now drop panels whose device left `channel.devices`.
- [x?] MixerChannel: the name label should ellipsize mid-word, so long words don't widen the channel. Name label now uses character ellipsis (`OVERRUN_TRIM_ELLIPSIS`). The actual widening came from the sends panel: a long bus name under a send knob set every strip's width (244 px for a 26-char name). Send labels are now 44 px with an ellipsis and a tooltip.
- [x?] Sync the scroll position of the sends container across MixerChannels (`MixerChannel._shared_sends_scroll`, like the shared VSplit offset)


### Arranger & Timeline


- [x?] Increase the maximum horizontal zoom in the timeline. Arranger max is now 16384 px/beat (was 4096), about 1.5 samples per pixel at 120 BPM / 48 kHz. The grid still stops at 1/8-beat lines, so at full zoom snapping is coarse relative to the view.
- [x?] Arranger track list: wire up the IO routing menu button on `TrackItem`. It sets the track channel's output route (Master or a bus/group) and shares its list with the mixer strip's output button via `mixer/ChannelOutputMenu.gd`. Locked while the channel sits in a folder/group; disabled on unrouted tracks. Covered by `Godot/tests/test_track_io_button.gd`.
- [ ] Chord track: design & implement chord track with visual notations
- [x] Bug: when an automation lane is visible, Ctrl+C, Ctrl+V and Ctrl+D don't work on clips. Seems to occur specifically when a curve point is selected (likely the automation curve point steals the shortcut/focus).
- [x?] Bug: Due to recent changes to TrackItem, they sometimes change heights on their own due to control re-layout. This currently does not update height of tracks in the timeline itself. `TrackItem._sync_layout_height()` (run on `NOTIFICATION_RESIZED` and `content_box.minimum_size_changed`) pushes a wrapping-forced height through `Track.height`, so the timeline lane and clips follow; the height the user last set is remembered and restored once the panel is wide enough again, and any explicit height change (drag, Ctrl+scroll zoom, undo) clears that memory. Skipped while the fold animation clips the row (`fold_clip`), then re-run when the clip is removed. Also re-run on every `Track.height` write, so a vertical zoom, undo or a small stored height (which the container would silently floor at the header's content minimum without changing the header's realized size) cannot leave the timeline lane shorter than its header. Covered headlessly by `Godot/tests/test_track_item_height_sync.gd` (wrapping, restore, explicit resize, shrink-below-floor); live check of narrowing/widening the TracksPanel pending. Same for automation lanes: `AutomationLaneHeader` clamps `AutomationLane.height` up to its content floor (the 20 px `set_height` minimum is below the label/button floor), so the timeline `AutomationLaneRow` is never shorter than its header; covered by `Godot/tests/test_automation_lane_height.gd`.
- [x?] Ctrl+scroll vertical zoom should zoom around the mouse cursor, I.E if mouse is at a track near bottom, should also scroll down. Still broken.
- [x] Arranger track list footer: right-aligned toggles for automation (hides every automation lane row in both columns and the header automation buttons) and routing (hides the header IO button). Stored in `Project.arranger_view` and saved with the project. Covered by `Godot/tests/test_arranger_view_toggles.gd`.
- [x] Bug: clicking a track header did not deselect the other tracks when the clicked track was already part of a multi-selection. The block is still kept on press so it can be dragged; releasing without a drag now selects only the clicked track. Covered by `Godot/tests/test_arranger_view_toggles.gd`.
- [x] Bug: changing track color does not update the timeline background color. Not a bug: the lane tint does follow the color; it is just faint (`TimelineTrack` keeps the track color's hue/saturation at `bg_color` brightness and 50% alpha).

### Clips

- [x?] UX: moving timeline clips around needs improvement. Dragging a clip to another track should move it there live during the drag, not just on drop.
- [x?] Shift+click while dragging a clip should bypass grid snap.
- [x] Double-clicking to place a clip starts moving it straight away: keep the button held and drag it into place; the release records the move (a separate undo step from the creation). Covered by `Godot/tests/test_clip_placement_drag.gd`.
- [x] Resize several clips at once: dragging an edge of a clip in a multi-selection moves that edge on every selected clip by the same snapped delta, each clamped to its own neighbours, as one undo step. Covered by `Godot/tests/test_clip_group_resize.gd`.

#### Phase 1: Clip instance awareness and unused clips (complex)

1. Instance count as observable state (foundation)
   - [ ] `Project` emits `clip_instance_count_changed(clip_id, count)` whenever an instance is added, removed, moved to another track or made unique (hook into `Track.clip_instance_added/removed`).
   - [ ] Tests: count updates across create, delete, Make Unique and undo/redo.
2. Instance count badge
   - [ ] TimelineClip header shows the count right-aligned; show nothing when count is 1.
   - [ ] Update from the signal in 1, not by polling in `_draw`. Hide the badge when the clip is too narrow.
3. `Select All Instances` in the clip context menu
   - [ ] Selects every instance of the clicked clip(s) through `ClipSelectionManager`, across tracks.
   - [ ] Disabled when no other instances exist (same check as Make Unique).
   - [ ] Add `Select Tracks` to the clip instance context menu: selects every track that the selected clip instance(s) sit on.
4. Rename clips that lose their last instance
   - [ ] When the count reaches 0, rename: strip the number suffix (`Clip.uniqueness_base`), append `_unused`, then re-suffix so names stay unique among unused clips too.
   - [ ] When an instance comes back (undo, or later placing from the asset browser), restore the original name. Store it on the clip so undo doesn't depend on reversing the string.
   - [ ] Make the rename part of `ClipInstanceDeleteCommand` (and multi-delete) so a single undo step restores both the instance and the name.
   - [ ] Tests for rename, suffix collisions and undo.
5. Waveforms (investigation, open-ended)
   - [x?] Profile generation (`AudioFileService` waveform caches) and drawing on long audio clips; write findings to STATUS.md before choosing fixes (e.g. multi-resolution peaks, min/max + RMS drawing, caching per zoom level).

#### Maybe

- [ ] Differentiate clicking the clip header from the clip body, with settings under the Behavior category:
  - [ ] Double-click body: open the clip and switch to the MIDI editor in clip mode
  - [ ] Double-click header/text: rename
  - [ ] Right-click header: context menu
  - [ ] Right-click body: delete; holding the button deletes clips as the mouse moves over them

### Clip Editor / Note Editor

#### Multi track editing

- [ ] Improve design of the track list. active/selected should use white border, to be cohesive with arranger's trackitem and mixer's mixerchannel styling.
- [ ] tracks in track list should be ordered the same as the timeline
- [ ] by default, the track list should show all enabled+visible (when enable/visibility is implemented) tracks
- [ ] tracks could have a checkbox to show/hide their notes
- [ ] by default, show all tracks

- [x?] Note editor: dragging the end of a note to adjust its length seems to floor the drag instead of rounding it, so it doesn't "feel right". `_snapped_duration` now rounds to the nearest grid step (still min one step).
- [x?] Piano roll: black keys use a white background, so the note-hover overlay is barely visible on them. `VPiano` now darkens light keys on hover instead of lightening them.
- [x?] Bug: the blue vertical range line at the start of the clip renders off-screen. The markers track content X correctly (projected note position == marker X), but `MidiEditorOverlays` had no clipping, so a marker scrolled left of the note area painted over the piano keys / outside the editor. Fixed with `clip_contents = true` in `_ready()`.
  - bug still present: issue is that it isn't visible. maybe fix is draw +1 px to the right?
  - Markers are now inset by half their width (start drawn right of the edge, end left of it), so a start marker at x = 0 is no longer half-clipped.

- [ ] Consider Modifier+right-click to open context menu in NoteEditor?
- [x?] should probably add a gray line between E/F and between B/C
- [x?] Clip editor track list: every instrument track is listed with an eye and a pencil toggle (drag to paint, Shift+click solo, revert), hidden tracks aren't drawn, clicking another editable track's note switches to that track, right-click erases across tracks, and the header shows the clip name in clip mode with an icon mode toggle. Spec `docs/specs/007-clip-editor-track-list/`. Implemented and covered headless; needs the live pass (T-012 in tasks.md)
- [x?] Clip editor track-mode performance (`docs/clip-editor-performance-plan.md`, phases 1 and 2): scrolling no longer repositions notes, and only the active track has note nodes; the other visible tracks are drawn and hit-tested from data by `ContextNotesLayer`. Headless benchmark: binding 100 tracks x 500 notes went from 10.9 s to 0.14 s. Needs a live pass: drawing of the dimmed tracks, clicking one to switch, right-click erase across tracks, Drum View with many tracks, and the hand cursor over other tracks' notes

### Devices

- [/] Drum synths: four built-in drum instruments (Kick, Snare, Hat, Clap) sharing `Engine/src/audio/devices/drums/` and the `audio/dsp/` drum blocks. Spec `docs/specs/013-drum-synths/`
  - [x?] Phase 0: shared foundation — one-shot/burst envelopes, `sweep_osc`, `noise`, `saturate`, generic `DrumHost<DrumVoice>`, `DRUM_IDS`/`create_drum`, `drum_conformance.rs`, Godot `DeviceKind.DRUM` + `DrumStrategy`
  - [x?] Phase 1: Kick (`sonara.builtin.kick`) — swept body + click + filtered noise, keytrack, gate mode; `drums/layers.rs` (`ClickLayer`, `DriveStage`)
  - [x?] Phase 2: Snare (`sonara.builtin.snare`) — two tone modes + band-passed snares + snap
  - [x?] Phase 3: Hat (`sonara.builtin.hat`) — six 808 pulses + noise, band-pass + high-pass; Drum Machine choke groups (engine `AudioDevice::choke`, OSC `slot/{slot}/choke`, project persistence, ADR 0012)
  - [x?] Phase 4: Clap (`sonara.builtin.clap`) — burst hands + room tail
  - [x?] Wrap-up: "Synth Kit" Drum Machine preset — `DrumKit.gd` plus "Load Synth Kit" in a Drum Machine's context menu (GM notes Kick 36, Snare 38, Clap 39, Closed Hat 42, Open Hat 46; both hats in choke group 1, the open hat's Decay set so it rings). Covered headless by `Godot/tests/test_drum_kit.gd`
  - [ ] Live pass: a full four-piece pattern with no clicks or dropouts, and a kick that sounds good at its defaults
- [x?] Layer note mapping: per-slot input→output note maps (zones, remapping, layering), per-slot separate outputs, and a mapping window with Resolve overlaps and Distribute. Spec `docs/specs/006-layer-note-mapping/`. Implemented and covered headless; needs the live pass (T-014 in tasks.md)
- [/] Simple View: a generated, editable grid view for any device without its own panel (strategies per device kind, compound controls, JSON layouts in `~/.config/sonara/device_layouts/`), spec `docs/specs/004-simple-view/`
  - [x?] DevicePanel integration (T-013). Still to check live: Sampler "Simple" toggle, "loaded layout" after restart, hand-edited `rect` shows up, page tabs on a device with more than 24 cells, eq_band rendering
  - [ ] Edit mode, part 1 (T-014): edit toggle, drag to move and corner drag to resize (snapped, overlap rejected), move to page, add/remove page, column/row spinners, Reset with confirmation. Leaving edit mode saves and sets `generated: false`. Planned in `SimpleEditOverlay.gd`
  - [ ] Edit mode, part 2 (T-015): context menu (rename control or group title, pick a display unit, remove) and an "Add parameter" list of visible parameters missing from the layout
  - [ ] Full live run (T-018) once edit mode is done
- [x?] `DrumMachineDefaultView._rebuild` connects `slot_changed` / `loading_state_changed` on child devices but never disconnects them when a child is removed from the drum machine. Now tracked in `_tracked_children` and reconciled by `_sync_child_signals()` on every rebuild; `_on_unbind` clears the tracked list. Verified headless (throwaway): a removed pad's signals are disconnected and the other pads stay connected.
- [x?] `CompactDevicePanel.setup()` does `await ready` unconditionally, so it hangs if the panel is already in the tree (use `if not is_node_ready(): await ready`). Done; covered by `Godot/tests/test_compact_device_panel.gd`, which fails against the old code.
- [x?] Device lane: add slight spacing between header and parent header. `DeviceLane` inserts a 4px `ParentHeaderGap` spacer between them, visible only with the parent header. Verified headless: order and 4px layout width.
- [ ] Bug: clicking the light (enable/bypass) button on `DevicePanel` in the device lane doesn't seem to work.
- [ ] Device lane: for each device, add an animated signal icon on its left side that flashes black then green on audio and blue on MIDI
- [ ] All devices should have their own volume control
- [x?] Devices should be freely renamable, with uniqueness enforced per-channel (auto-suffix on collision, like track/channel names above). Inline SmartLineEdit (double-click) on the device lane and compact panels, plus the context menu, all through `DeviceActions.rename`. Uniqueness is per host (siblings in a container), which is what `Channel/Device/Child` paths need

#### Plugins


### Save / Load / Export

- [ ] Welcome Screen with recent projects, templates
- [ ] Export/rendering
  - [ ] bouncing tracks or clips to audio clip on a new track
  - [ ] bounce in-place a midi clip to audio clip, replacing midi clip with audio and auto-converting channel to hybrid track (midi+audio)?
- [ ] Export MIDI
- [x?] DAWproject import and export, core subset (tracks, channels, routing, sends, MIDI/audio clips, automation, markers, tempo and signature maps, CLAP and built-in devices with state, transfer report). Spec: `docs/specs/010-dawproject-core/`
- [ ] Export menu with separate track (stem) selection

### Hardware & MIDI

- [ ] Modulation
  - [ ] Basic modulation, similar to Bitwig: allow any channel and device parameter to be modulatable
  - [x?] Device modulation routes (PolySynth v2, spec `docs/specs/011-polysynth-v2/`): engine + OSC + Godot model done (phase 4); assign UI in SimpleView done (phase 5, [x?]: manual check pending); live display is phase 6
  - [ ] Phase 1: track automation lanes for channel and device parameters (incl. MIDI CCs) — spec `docs/specs/003-automation/`

### UI / Quality of Life

- [ ] Investigate overall frontend architecture: deviations from code style / best practices, and organization improvements — prioritize low-risk, high-ROI
- [ ] Complete the value-control gesture set (see `docs/subsystems/godot-ui-components.md`, "Consistent interaction")
  - [ ] Double-click value entry (`FloatingValueEditor`) on HorSlider, XYSlider and EnvelopeControl (per handle)
  - [ ] Ctrl/Cmd-click reset to default on VSlider, the Meter fader, Volumeter (0 dB? or the channel default) and EnvelopeControl (per handle)
- [x?] SmartLineEdit: clicking outside (or losing focus) commits the edit, like Enter
- [ ] Logging performance: every log call writes and flushes the log file with no level filter, and the note editor logs once per note on every edit. That adds up during bulk edits; a level filter or removing those lines would fix it.

### Settings

- [ ] Data-driven settings system: register a setting with name, category, optional sub-category, description/help, default value, data type / input control type, and build the UI from that registry (rendered when the settings window opens), we may allow custom controls linking to a packed scene perhaps for certain settings (maybe for assets path definitions).
  - [ ] Sub-category renders as a large-font label with margins between sub-categories
  - [ ] Table-like layout with the controls aligned on the right for readability
- [ ] Searchable settings: fuzzy search bar at the top, with a little debounce
- [ ] Scroll zoom sensitivity setting (applies to horizontal and vertical zoom): Slow / Normal / Fast, where Normal is twice the current speed
- [] Move asset related settings to a top-level Assets category and include paths to search for Clap plugins. Default values should point to common clap paths on linux.

#### Asset Browser

- [ ] each asset path entry from settings should show as its own top-level folder in the tree.
- [ ] Split browser into two vertical areas, tree at top and details at bottom. Details show info about item, dependong on asset type. audio can show waveform and a preview button that plays the sound, ideally this should play to the output the master is set to (don't play on the master itself, that would color the preview if master has any fx devices.)
- [ ] Tree view can have icons, maybe audio / midi / device, we have a few lucide icons, but we might fetch more filetype icons from lucide.dev

### AI Assistant

Design notes: `docs/ai-integration.md`, clip DSL: `docs/clip-text-format.md`

- [ ] Allow the AI to ask questions via a tool with multiple choice answers (but always with a custom answer option), optionally tagging a clip, track, channel. The question will then be presented to the user and the element highlighted in the chat (if clicked, select and make visible/scroll toward it in mixerchannel or timeline (and switch arranger/mix/edit view if needed).
  - [ ] Actually, could also implement link system that both assistant and user can use via some simple syntax maybe URL style? clip://some-clip and it is rendered as a clickable badge? 
- [ ] Implement conversation compaction — when triggered, send the conversation to a compaction model with instructions to summarize it, focusing on the important bits. Add configuration settings to Settings/AI menu (threshold and what model to use). Compaction prompt can be a .md file with a {conversation} variable maybe?
- [ ] Add to AI settings personality presets for assistant. Default (helpful, concise, friendly), and Teacher is an interesting idea (less dumping info, more back-and-forth)
- [x?] AI Assistant needs a way to remove clips from timeline, and/or allow place_clip to optionally overwrite.
- [x?] AI Assistant needs a way to move clips. Instead of cut/copy/paste that need several tool calls, we could make atomic tools that take a range and a track_filter parameter. A move_clips (select_start=1.1.1, select_end=3.1.1, destination_start=5.1.1, tracks=[tracks default to all maybe])


- [x?] scope chat conversation dropdown to current project file, and automatically open convo when opening a prior project


- [x?] Store request/response JSON for debugging, with a reference on messages. Messages in UI show a small `{ }` link (tokens/cost) that opens a syntax-highlighted request/response viewer. Retention: Settings → AI → Keep Request Logs
- [x?] Investigate if tool results can be presented in a simpler way to assistant? (see docs/ai-tool-results-plan.md)
- [x?] AI device tools should resolve devices by name once devices are freely renamable, matching the existing track/channel name lookup
- [x?] Formalize naming convention for clips, tracks, channels and devices as "Capitalized Lower Case"; assistant name lookup should normalize/resolve regardless of exact casing (e.g. "capitalized_lower_case" or arbitrary user casing). `NameStyle`: lookups and uniqueness compare by `key()`, AI-supplied names go through `format()`, system prompt states the convention
- [x?] AI tools: fuzzy device lookup, default clip placement + overlap refusal, reference tracks/channels by name instead of id (see docs/ai-names-and-placement-plan.md)


## Track and pass along user changes to assistant

When chat history is not empty, track the user's changes/edits and feed that summary along with the next user message.

For example, a changelist could look like this:
```
The user has made several changes:

- added instrument track: "Strings"
- modified clip "Bass Part 1"
- placed clip "Bass Part 1" to x:y:z

---

{user_message-here}
```
However, we should ensure they are concise and not full of detail that might not be needed at the time. Also, if there are large amounts of changes - probably just say "The user has made significant changes to X, Y, Z".

We can check how many clip modifications, if it's a lot, we can collapse to "modified 4 clips" or such.
