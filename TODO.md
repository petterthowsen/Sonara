# TODO

[ ] is open, [x?] implemented but not verified, [x] is verified, [/] is mixed status.

## Codebase Audit

- [ ] Full audit of `Godot/` for file structure and code organization issues: folder layout and naming, misplaced or oversized scripts, duplicated logic, dead code, and code that breaks the data-model/UI split
- [ ] Full audit of `Engine/` for the same: module layout, oversized files (e.g. `osc/server.rs`), duplicated logic, dead code and unused dependencies
- [ ] migrate TODO.md to gh issues.
- [x?] Sampler v2: loop modes with crossfade, reverse, per-voice filter, fine tune, root note, interactive sample display. Engine (phase 1) is `[x?]` except 1.9 (waveform loading reliability: logging added, waiting on a repro log); Godot UI (phase 2) is `[x?]` except the 1.9 resend hook in 2.6. Spec: `docs/specs/021-sampler-v2/`
- [ ] Sampler multisample: Window and Companion views, multisample mode with zones (key/velocity ranges, per-zone settings), groups (gain/mute/solo, round robin/random), zone crossfades, multisample editor (group bar, sample list, zone map, batch operations). Spec: `docs/specs/023-sampler-multisample/`. Follow-up: spec 024 Sampler group outputs
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
- [ ] Bug: modulator LFO phase does not work

### Audio Thread

Phased plan for this section, plugin hosting rework and audio device settings: `docs/engine-stability-plan.md`

- [ ] Remove the shared `Arc<Mutex<EngineState>>` (phase 2): the audio thread should own its state and drain a lock-free command queue, with removed objects sent back to be dropped off-thread
  - [ ] Phase 1, partly verified live (CLAP on a bus, large clip import during playback): slow commands (plugin scan, device create/drop, plugin GUI/activation IPC) run outside the lock in `CommandWorker`; the callback uses a bounded `try_lock` and outputs silence
- [x?] Audio thread allocations still left: unbounded status channel sends, `process_device_chain` sleep-change Vec, `audio_playback_positions` insert (String clone) on clip start, `poll_parameter_changes` sets a socket read timeout every buffer per CLAP plugin (Phase 1 of the stability plan; verify with `SONARA_FEATURES=rt-debug`)
  - [ ] Known left: `poll_device_data` allocates its payload while a view is subscribed (spectrum analyzer; the modulation wrapper's `modulation` stream likewise, ~20 Hz)
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
- [x?] Plugin GUI windows should be forced to stay above Godot App: with embedding on (X11), plugin GUIs live inside device frames (spec 022). With it off, they are still separate windows
- [x?] Device frames: Sonara-drawn device windows (custom title bar, floating or attached in the Primary area, per-channel tabs with tear-off) and experimental embedding of CLAP plugin GUIs into them via X11 reparenting (Settings › Audio › Plugins › Embed Plugin Windows). Spec `docs/specs/022-device-frames/`, ADR 0016. Partly verified live on X11: embedding, attach/detach, floating tabs; the full pass (T-019) is open
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
- [ ] Multiband FX: container that splits audio into 2–6 bands (LR4 crossovers), each with its own slot chain, e.g. multiband compression. Spec `docs/specs/016-multiband-fx/plan.md`
- [ ] L/R and M/S modes

---

## Godot

### [ ] Channel & Track enabled/visible system

We should have two states on both tracks and channel.

Visibility, which is visual only, and can be useful in certain scenarios during editing of clips etc. Visibility is toggled any time via context menu (both TrackItem and MixerChannel), channel-linked tracks stay in sync of course (bidirectionally), though that behavior could be a configurable setting under Behavior. Visibility on Group and Folder hides/shows the children.

Enabled status is similar to visibility except it deactivates all the devices on the channel and child channels, saving RAM. Quite useful for large templates where only the most used are enabled and less common ones can progressively be enabled. 

To make it possible to bring them back, two toggles at the bottom of the Arranger and the Mixer, using a suitable icon.
### Mixer & Tracks

- [x?] Bug: moving a device sometimes leaves a stray device visual on the DeviceLane; it goes away when switching channel. `Channel.device_removed` passes the device *type* id, but `DeviceLane` matched it against instance ids, so a move into a container never removed the root panel. The compact `ChannelDeviceList` matched by position after reindexing and could free the wrong panel. Both now drop panels whose device left `channel.devices`.
- [x?] Sync the scroll position of the sends container across MixerChannels (`MixerChannel._shared_sends_scroll`, like the shared VSplit offset)
- [ ] Improve `ChevronScrollContainer` and how it works in `MixerChannel`'s `SendsPanel`:
  - [ ] Add an option to only show chevrons buttons on hover
  - [ ] Ensure items are centered
- [x] Bug: `MixerChannel`: when big meters are toggled and sends are hidden, big meters don't expand to the available space. The main VSplit is now hidden when devices and sends are both hidden, and the bottom meter/fader loses its height cap when nothing else expands.


### Arranger & Timeline


- [x?] Increase the maximum horizontal zoom in the timeline. Arranger max is now 16384 px/beat (was 4096), about 1.5 samples per pixel at 120 BPM / 48 kHz. The grid still stops at 1/8-beat lines, so at full zoom snapping is coarse relative to the view.
- [x?] Arranger track list: wire up the IO routing menu button on `TrackItem`. It sets the track channel's output route (Master or a bus/group) and shares its list with the mixer strip's output button via `mixer/ChannelOutputMenu.gd`. Locked while the channel sits in a folder/group; disabled on unrouted tracks. Covered by `Godot/tests/test_track_io_button.gd`.
- [x?] Increase the amount of allowed zoom out in the timeline: `zoom_min_pixels_per_beat` is now 2 px/beat (was 8) in both the arranger and the MIDI editor, so zoom-out covers 4x more. Grid/ruler are safe: beat lines and subdivisions are already skipped below `min_line_spacing`, leaving bar lines only. Wheel zoom is multiplicative (ppb × sensitivity per notch), so it is already exponential/geometric; "lighter" feel would mean lowering `zoom_sensitivity_h` (see the scroll zoom sensitivity setting below)
- [ ] Chord track: design & implement chord track with visual notations
- [x] Bug: when an automation lane is visible, Ctrl+C, Ctrl+V and Ctrl+D don't work on clips. Seems to occur specifically when a curve point is selected (likely the automation curve point steals the shortcut/focus).
- [x?] Bug: Due to recent changes to TrackItem, they sometimes change heights on their own due to control re-layout. This currently does not update height of tracks in the timeline itself. `TrackItem._sync_layout_height()` (run on `NOTIFICATION_RESIZED` and `content_box.minimum_size_changed`) pushes a wrapping-forced height through `Track.height`, so the timeline lane and clips follow; the height the user last set is remembered and restored once the panel is wide enough again, and any explicit height change (drag, Ctrl+scroll zoom, undo) clears that memory. Skipped while the fold animation clips the row (`fold_clip`), then re-run when the clip is removed. Also re-run on every `Track.height` write, so a vertical zoom, undo or a small stored height (which the container would silently floor at the header's content minimum without changing the header's realized size) cannot leave the timeline lane shorter than its header. Covered headlessly by `Godot/tests/test_track_item_height_sync.gd` (wrapping, restore, explicit resize, shrink-below-floor); live check of narrowing/widening the TracksPanel pending. Same for automation lanes: `AutomationLaneHeader` clamps `AutomationLane.height` up to its content floor (the 20 px `set_height` minimum is below the label/button floor), so the timeline `AutomationLaneRow` is never shorter than its header; covered by `Godot/tests/test_automation_lane_height.gd`.
- [x?] Ctrl+scroll vertical zoom should zoom around the mouse cursor, I.E if mouse is at a track near bottom, should also scroll down. Still broken.
- [x] Arranger track list footer: right-aligned toggles for automation (hides every automation lane row in both columns and the header automation buttons) and routing (hides the header IO button). Stored in `Project.arranger_view` and saved with the project. Covered by `Godot/tests/test_arranger_view_toggles.gd`.
- [x] Bug: clicking a track header did not deselect the other tracks when the clicked track was already part of a multi-selection. The block is still kept on press so it can be dragged; releasing without a drag now selects only the clicked track. Covered by `Godot/tests/test_arranger_view_toggles.gd`.
- [x] Bug: changing track color does not update the timeline background color. Not a bug: the lane tint does follow the color; it is just faint (`TimelineTrack` keeps the track color's hue/saturation at `bg_color` brightness and 50% alpha).
- [x] Bug: timeline horizontal zoom jitter when zooming in at a > 0 horizontal scroll: the scroll position jitters when zooming in
- [x] Bug: timeline horizontal zoom did nothing within a beat of scroll 0 (regression from the jitter fix: the origin lock never set a zoom anchor, so the zoom was never applied). The origin lock is now an anchor at beat 0 / x 0.
- [x] MIDI editor scroll/zoom robustness: middle-mouse pan and wheel scroll clamp their targets (no more overscroll dead zone); Ctrl+wheel vertical zoom adjusts the scrollbar max before scrolling so it no longer snaps when zooming in; Shift+wheel horizontal zoom uses the arranger's cursor-anchor approach (no jitter, locks to origin near 0).
  - [x] Markers also jitter their lengths and their labels

### Clips

- [x?] UX: moving timeline clips around needs improvement. Dragging a clip to another track should move it there live during the drag, not just on drop.
- [x?] Shift+click while dragging a clip should bypass grid snap.
- [x] Double-clicking to place a clip starts moving it straight away: keep the button held and drag it into place; the release records the move (a separate undo step from the creation). Covered by `Godot/tests/test_clip_placement_drag.gd`.
- [x] Resize several clips at once: dragging an edge of a clip in a multi-selection moves that edge on every selected clip by the same snapped delta, each clamped to its own neighbours, as one undo step. Covered by `Godot/tests/test_clip_group_resize.gd`.
- [ ] Bug: timeline clips: zooming in/out seems to cause MIDI clip notes to flash, presumably due to them being re-rendered (consider debouncing)
- [ ] Bug: timeline audio clips: on project load, waveforms are not always loaded correctly (stuck in "loading waveform...", which also coincidentally overflows the clip instance)

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

- [x?] Bug: in drum view mode, inserted notes are too long and can sometimes end up replacing many notes. A length remembered from a piano-roll resize (`NoteEditor.last_note_length`) followed the user into Drum View, where the long insert's overlap cut removed the following hits on the row. Drum View now always inserts one grid step; the remembered length still applies in the piano roll. Covered by `test_drum_view.gd` (`_test_drum_insert_ignores_piano_roll_length`); needs a live pass
- [ ] Drum view: notes are hard to select. Draw/insert them as long as the smallest snap interval at the current zoom. Add a toggle at the bottom of the editor for this behavior; the inverted case makes them as small as the smallest snap interval (clarify: the toggle off may mean the note's actual length)
- [x?] Bug: velocity of new notes is wrong. New notes should inherit the last velocity used, or the velocity of the last clicked note (spec 019, REQ-028)
- [ ] Note values and the value lane: float velocity and release velocity, sounding-note ids through the device interface, a `release` modulator, and a value lane pane under the MIDI editor (paint, line, offset and scale gestures, Set/Randomize/Scale transforms, drum row selection). Expression curves come in a later spec. Spec `docs/specs/019-note-values/`
  - [ ] Phase A: foundation (engine, model, OSC, DAWproject `rel`)
  - [ ] Phase B: UI (value lanes, row selection, new-note values)

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
- [x?] Devices should be freely renamable, with uniqueness enforced per-channel (auto-suffix on collision, like track/channel names above). Inline SmartLineEdit (double-click) on the compact panels, the context menu everywhere, all through `DeviceActions.rename`. Uniqueness is per host (siblings in a container), which is what `Channel/Device/Child` paths need. The DevicePanel header now shows a plain Label (mouse PASS); the lane's inline edit was removed in favour of the context menu

#### DevicePanel

- [ ] Bug: sometimes, when moving a device, its device light ends up in a buggy state (off) though it keeps working
- [ ] Bug: when moving the EQ builtin to another position in the chain or elsewhere, sometimes the analyzer stops working. Workaround is to open and close the auxiliary window

- [x?] LeftHeader works as a drag handle (drag forwarding + `MOUSE_FILTER_PASS`, like TopHeader)
- [x?] DevicePanel is selectable, with a white selection border like MixerChannel and TrackItem.
  - [x?] Selecting and moving multiple devices at the same time; ctrl+click and shift+click select multiple (lane-owned selection, block drags move in one undo step; mixed hosts/slots reduce to the primary device)
- [x?] Animate showing/hiding device controls: panes slide the whole panel layout while fading (`DevicePanel._animate_pane` + `components/PaneReveal.gd`, 0.15 s)
  - [x?] Animate toggling the modulators and parameter list panels (same slide + fade)
- [x?] Move the device modulators toggle below the device show/hide toggle
- [x?] Modulators: the tile list pages through a `ChevronScrollContainer` (as SendsPanel does); the options panel stays a separate panel to the right

Verified headless (`tests/test_device_panel_selection.gd`); panes open/close through `components/PaneReveal.gd` (reveal tween slides the layout, pane fades); still to check live in the editor.

#### DevicePanel Modulators

- [ ] Modulator options panel should never scroll
  - [ ] When sync is on, hide the rate control
  - [ ] Retrigger can be a checkbox

#### Plugins


### Save / Load / Export

- [ ] Welcome Screen with recent projects, templates
- [x] Export/rendering (offline render core and WAV export: `docs/analyze-plan.md` Phases 1–2). File › Export Audio…
  - [ ] bouncing tracks or clips to audio clip on a new track
  - [ ] bounce in-place a midi clip to audio clip, replacing midi clip with audio and auto-converting channel to hybrid track (midi+audio)?
- [ ] Export MIDI
- [x?] DAWproject import and export, core subset (tracks, channels, routing, sends, MIDI/audio clips, automation, markers, tempo and signature maps, CLAP and built-in devices with state, transfer report). Spec: `docs/specs/010-dawproject-core/`
- [x] Export menu with separate track (stem) selection (Export Audio… dialog, per-channel stems)

### Hardware & MIDI

- [ ] Hardware MIDI controller support

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
- [x?] Scroll zoom sensitivity setting (applies to horizontal and vertical zoom): Slow / Normal / Fast under Settings › Behavior › Zoom, shared by the arranger and the MIDI editor (per-notch zoom multiplier 1.2 / 1.6 / 2.2, roughly a third faster than the old defaults at Normal; vertical sensitivities scale by the same step around their old bases). Both views follow live changes. The MIDI editor's Shift+wheel horizontal zoom now lerps toward its target like the arranger's (it was instant; plain scroll was already smoothed), and zooming within a beat of the origin sticks to scroll 0 there too, in both the smooth and instant paths.
- [] Move asset related settings to a top-level Assets category and include paths to search for Clap plugins. Default values should point to common clap paths on linux.

#### Asset Browser

- [ ] each asset path entry from settings should show as its own top-level folder in the tree.
- [ ] Split browser into two vertical areas, tree at top and details at bottom. Details show info about item, dependong on asset type. audio can show waveform and a preview button that plays the sound, ideally this should play to the output the master is set to (don't play on the master itself, that would color the preview if master has any fx devices.)
- [ ] Tree view can have icons, maybe audio / midi / device, we have a few lucide icons, but we might fetch more filetype icons from lucide.dev

### AI Assistant

Design notes: `docs/ai-integration.md`, clip DSL: `docs/clip-text-format.md`

- [x] `analyze` tool: render a range offline and return a per-bar loudness/band grid of the master and channels (see `docs/analyze-plan.md`; needs offline rendering first)
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
- [ ] Dead actions dropped from `project.godot` during the hotkey migration (no handler existed): `pause`, `stop_here`, `toggle_clip_editor`, `toggle_secondary_mixer`. Implement any that are wanted as registry actions in `HotkeyActions.gd`.
- [ ] `Timeline.gd:570`, `TimelineTrack.gd:69` and `TimelineClip.gd:596` read `Input.is_action_pressed("ui_select")` as an additive-select modifier. `ui_select` is a joypad button, so it is effectively dead. Remove it or give additive select a real binding.
