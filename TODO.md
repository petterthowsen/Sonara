# TODO

[ ] is open, [x?] implemented but not verified, [x] is verified, [/] is mixed status.

## Audio Engine

### Mixing & Playback

- [ ] Plugin latency compensation
- [ ] Send amount curve is wrong: with Dragonfly Hall Reverb (100% wet) on a bus at 0 dB and a send of 0.5 from Drums, almost no signal reaches the reverb; past 0.5 it ramps up very steeply. Send amount should be in dB (-inf to 0 dB) like Bitwig, not a raw linear 0-1 factor
- [ ] Bug (`city_pop_5` project): soloing the Reverb channel appears to stop processing the Drum channel even though Drums sends into it. Closing and reopening the project doesn't fix it. Solo logic should keep channels alive that feed a soloed route target
- [x] Playhead line is jittery during playback. Traced to Godot, not OSC or the engine: `Editor._process()` drove the playhead from the error against the last received tick and clamped it to that tick, so visual velocity rippled at the 20 Hz update rate (10-30% velocity sd, up to 29x slowest-to-fastest frame with frame-time jitter). Replaced with a float clock that free-runs at tempo rate and corrects phase gradually; sd now under 4%. Covered by `Godot/tests/test_playhead_interpolation.gd`
  - [x] Engine status cadence: `samples_since_update` was reset to 0 instead of subtracting the interval, discarding the remainder (18.75 Hz instead of 20 at 512 frames/48 kHz)
  - [x] Removed `/status/sample_position` entirely - it was a free-running device sample counter, never reset on stop or seek, advancing even while stopped, and had no listener in Godot
  - [x] Verified live: playhead is smooth during playback
  - [ ] Optional, no longer jitter-related: OSC receive runs in `OSCServer._process()` on the main thread, so every message is delayed up to a frame. Affects parameter changes and meters too. Note `AudioEngineOSC.gd:70` claims a polling thread that doesn't exist
- [ ] Mixing: pre-fader send audio is copied before the device pre-pass, so pre-fader sends from instrument channels are silent
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
  - [x] Drum Machine pads feed nested child mixer channels (extra-out buses before the child device chain)
  - [ ] CLAP extra output ports into shared memory (child return channels are created when `audio_out_channels > 2`)
  - [x] Creating multi-out channels (like Drum Machine) should not create tracks for those sub channels, since the device routes MIDI input itself
  - [x] Multi-out devices do not show the child device on the device line for that child channel (neither in device lane nor in mixer channel). Pad returns now show the pad device first in the device lane and mixer strip (editable, draggable), plus a clickable parent header, see `docs/specs/001-multi-out-devices`
  - [x] Formalize multi-out contract (`AuxReturnSync`): undo keeps return channels, no tracks for CLAP returns, returns can't be deleted alone, stale engine aux slots cleared
- [ ] Add support for enum parameter type for builtins
- [x] Verify drag-to-reorder devices with builtin, CLAP and SFZ devices (engine + UI implemented)
- [ ] In Engine: Simplify device advertisement to avoid creating temporary instances
- [x?] CLAP processing is synchronous per block (per-block handshake over shared memory, sample-accurate notes/automation, one callback deadline). Verified live with 5 instances, 60 s playback: 0 dropouts, 0 xruns. Missing: audible null test and an end-to-end MIDI-offset check. See `docs/engine-stability-plan.md` Phase 3
- [ ] Crash / Error handling, send info to Godot for UI notifications
  - [x] Engine logs a warn and higher are sent over OSC
  - [x?] A crash report names the host's log file, and a plugin that keeps missing its deadline is flagged (amber ring on the device light)
  - [x] Host process exit is detected and turned into a per-host crashed state with a Reload action (stability plan Phase 4). Verified live: `kill -SEGV` a playing host, engine keeps running, UI gets `crashed:<reason>` + the host's stderr, `/reload` restores the plugin and its parameters. A `PopupMessage` window renders the crash with a Copy button
- [x?] Plugin hosting modes like Bitwig: Settings › Audio › Plugin Hosting (Individually, By plug-in, By vendor, Together) plus "Always host individually" per plugin in the device menu. Changes move loaded plugins live and keep their state; a shared host crash shows one popup and one Reload restores every plugin in it. See `docs/engine-stability-plan.md` Phase 5
- [ ] Plugin GUI windows should be forced to stay above Godot App
- [ ] Sforzando CLAP GUI embeds but renders black
- [x?] Improve logging of plugins: each plugin host writes `Engine/logs/plugins/<host>-<pid>.log` with the plugin named on every line, forwards warnings to Godot's `/log`, and reports per-plugin DSP load and dropouts (device header tooltip, EnginePanel). `plugin_host --probe` tests a plugin standalone; `SONARA_PLUGIN_HOST_WRAPPER` / `SONARA_PLUGIN_HOST_WAIT` run hosts under a debugger. See `docs/engine-stability-plan.md` Phase 6

### Built-in Devices

- [ ] Reverb
- [ ] EQ: Parametric, built-in spectrum
- [ ] Limiter
- [ ] Compressor
- [ ] Saturator
- [ ] L/R and M/S modes

Done:

- [x] PolySynth Device
- [x] Spectrum Analyzer
- [x] Chain container (serial children + volume)
- [x] Layer container (parallel mix, per-slot mute/solo)
- [x] Sampler and Drum Machine devices

---

## Godot

### Mixer & Tracks

- MixerChannel: Sync MainPane/VSplit's offset between all mixerchannels. Adjusting one > applies to all others.

- [ ] Master track doesn't accept device drops on its device lane and compact device list. Master track should accept devices.


### Arranger & Timeline

- [x] Ruler: Add secondary marker/ruler lanes (real-time ruler)
- [ ] Chord track: Implement chord track with visual notations
- [x] Marking track: Add marking/marker tracks (section labels, etc.)
- [ ] Bug: Due to recent changes to TrackItem, they sometimes change heights on their own due to control re-layout. This currently does not update height of tracks in the timeline itself.

### Clips

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
4. Rename clips that lose their last instance
   - [ ] When the count reaches 0, rename: strip the number suffix (`Clip.uniqueness_base`), append `_unused`, then re-suffix so names stay unique among unused clips too.
   - [ ] When an instance comes back (undo, or later placing from the asset browser), restore the original name. Store it on the clip so undo doesn't depend on reversing the string.
   - [ ] Make the rename part of `ClipInstanceDeleteCommand` (and multi-delete) so a single undo step restores both the instance and the name.
   - [ ] Tests for rename, suffix collisions and undo.
5. Waveforms (investigation, open-ended)
   - [ ] Profile generation (`AudioFileService` waveform caches) and drawing on long audio clips; write findings to STATUS.md before choosing fixes (e.g. multi-resolution peaks, min/max + RMS drawing, caching per zoom level).

#### Phase 2: Quick fixes (easy)

- [x?] Clip resize handles snap by rounding: `TimelineClip.gd` now uses `grid_helper.snap_ticks` for the resize start/end and for clip moves, for consistent behavior. Minimum-duration clamp verified unaffected (it depends only on `snap_interval`, not the floor/round choice).
- [x?] Clip context menu `Cut` and `Copy`: added buttons to `ClipContextMenu.tscn`/`.gd` (new `cut_requested`/`copy_requested` signals), wired in `Timeline.gd` to sync `clip_selection_manager` to the bound instances (so a right-click on an unselected clip cuts/copies the right clip) then call the existing `cut_selection_to_clipboard()` / `copy_selection_to_clipboard()`.
- [x?] Make Unique is grayed out when no selected instance shares its clip: `ClipContextMenu.bind_to_instances` already sets `make_unique.disabled`. Verify in the UI.
- [x?] SmartLineEdit for clip name (verify).
- [x] Make Unique
- [x] Delete

#### Maybe

- [ ] Differentiate clicking the clip header from the clip body, with settings under the Behavior category:
  - [ ] Double-click body: open the clip and switch to the MIDI editor in clip mode
  - [ ] Double-click header/text: rename
  - [ ] Right-click header: context menu
  - [ ] Right-click body: delete; holding the button deletes clips as the mouse moves over them

### Clip Editor / Note Editor

- [x?] Note maps and drum view: labeled/colored keys, a drum editing mode that folds to mapped rows, a note map library, and auto maps from the Drum Machine (see `docs/specs/002-note-maps/`)
- [ ] NoteContainer seems to assign IDs to midi notes. This responsibility should be moved elsewhere (Clip probably?)
- [ ] In track mode, notes from all clips should be visible
- [ ] Ctrl+click and drag ON a VisualNote should initiate "drag to duplicate anywhere"
    1. create VisualNotes of the selection (or the clicked visual if empty) and add them but tag them as "pending"
    2. while "duplicate-dragging", continually move the duplicates relative to mouse note position
- [ ] Track vs clip context mode:
  - [ ] In clip mode: ruler is relative to ClipInstance, draw clip start and end in ruler
  - [ ] In track mode: show all clips as they appear in entire track, ruler relative to entire track
  - [ ] In track mode, the track list should be ordered the same as the timeline
  - [ ] In track mode, draw a track-colored overlay on the ruler for clip start/end. Unfocused clips as gray/white below; clips of the active/focused tracks above
- [ ] Modifier+right-click to open context menu in NoteEditor
- [ ] Bug: the blue vertical range line at the start of the clip renders off-screen
- [ ] Unify the ruler between the arranger and the note editor: share a set of ruler components so the note editor also gets real-time display, range interaction, selection and start position
- [ ] Incoming MIDI events (live input and playback) should depress keys on the vertical piano roll the same way clicking does, in blue. Change the hover color to a lighter gray/white and prioritize key press over hover

- [x?] should probably add a gray line between E/F and between B/C
- [x?] note audition mode, a toggle at the bottom (use one of our icons) when on, clicking a note plays it on that instrument, at the velocity of the note.
- [x?] piano roll (the piano keys on the left) should allow clicking to play the notes. low velocity on their left-most edge and higher velocity on the right (20% padding on velocity mapping) maybe style it so it looks like it depresses
- [x?] the hovered note lane should highlight the key on the piano roll on the left

### Devices

- [/] Simple View: a generated, editable grid view for any device without its own panel (strategies per device kind, compound controls, JSON layouts in `~/.config/sonara/device_layouts/`), spec `docs/specs/004-simple-view/`
  - [x] Engine parameter metadata, layout model and generator, view rendering (spec phases 1–3, T-001–T-012)
  - [x?] DevicePanel integration (T-013). Still to check live: Sampler "Simple" toggle, "loaded layout" after restart, hand-edited `rect` shows up, page tabs on a device with more than 24 cells, eq_band rendering
  - [ ] Edit mode, part 1 (T-014): edit toggle, drag to move and corner drag to resize (snapped, overlap rejected), move to page, add/remove page, column/row spinners, Reset with confirmation. Leaving edit mode saves and sets `generated: false`. Planned in `SimpleEditOverlay.gd`
  - [ ] Edit mode, part 2 (T-015): context menu (rename control or group title, pick a display unit, remove) and an "Add parameter" list of visible parameters missing from the layout
  - [ ] Full live run (T-018) once edit mode is done
- [x] SamplerDefaultView, DrumMachineDefaultView etc should have their static layout in the scene rather than generated in code
- [ ] `DrumMachineDefaultView._rebuild` connects `slot_changed` / `loading_state_changed` on child devices but never disconnects them when a child is removed from the drum machine
- [ ] `CompactDevicePanel.setup()` does `await ready` unconditionally, so it hangs if the panel is already in the tree (use `if not is_node_ready(): await ready`)
- [ ] Device lane: add slight spacing between header and parent header
- [ ] Device lane: for each device, add an animated signal icon on its left side that flashes black then green on audio and blue on MIDI
- [ ] All devices should have their own volume control
- [x?] Devices should be freely renamable, with uniqueness enforced per-channel (auto-suffix on collision, like track/channel names above). Inline SmartLineEdit (double-click) on the device lane and compact panels, plus the context menu, all through `DeviceActions.rename`. Uniqueness is per host (siblings in a container), which is what `Channel/Device/Child` paths need

Done:

- [x] Drag a device between drum-machine slots (e.g. kick C1 → E1). Occupied target: swap.
- [x] Dragging devices around on the device lane, or within containers: drop targets occupy space at all times but are invisible, serving as spacers and drop targets simultaneously
- [x] Drum Machine: Clicking a slot should play the sample (velocity from the Y click position in the slot with some padding so that 80% Y position is highest velocity and 20% Y is lowest velocity)

#### Plugins

- [ ] Subfolders aren't scanned: the engine only looks at the top level of each plugin folder. The CLAP spec says to search subfolders, so a plugin at ~/.clap/<vendor>/Foo.clap isn't found today.

### Save / Load / Export

- [ ] Welcome Screen with recent projects, templates
- [ ] Export/rendering
  - [ ] bouncing tracks or clips to audio clip on a new track
  - [ ] bounce in-place a midi clip to audio clip, replacing midi clip with audio and auto-converting channel to hybrid track (midi+audio)?
- [ ] Export MIDI
- [ ] Export menu with separate track (stem) selection

Done:

- [x] bug: device CC values do not persist
- [x] bug: tracks in a folder initialize in the wrong position in the arranger

### Hardware & MIDI

- [ ] Modulation
  - [ ] Basic modulation, similar to Bitwig: allow any channel and device parameter to be modulatable
  - [ ] Phase 1: track automation lanes for channel and device parameters (incl. MIDI CCs) — spec `docs/specs/003-automation/`

### UI / Quality of Life

- [ ] Investigate overall frontend architecture: deviations from code style / best practices, and organization improvements — prioritize low-risk, high-ROI
- [x] Add [Lucide](https://lucide.dev) icons throughout the UI; curate a subset as selectable track/channel icons
- [x] Dock system: Inspector, Browser, and AI Chat freely placeable
  - Two side docks (left / right)
  - Each dock can stack panels vertically; split is draggable when two panels share a dock
  - Ensure drop targets never change size (show/hide visually only)
- [x] Asset Browser: Persist tree/list mode state and collapsed/uncollapsed folders
- [x?] SmartLineEdit: clicking outside (or losing focus) commits the edit, like Enter

### Settings

- [ ] Data-driven settings system: register a setting with name, category, optional sub-category, description/help, default value, data type / input control type, and build the UI from that registry (rendered when the settings window opens), we may allow custom controls linking to a packed scene perhaps for certain settings (maybe for assets path definitions).
  - [ ] Sub-category renders as a large-font label with margins between sub-categories
  - [ ] Table-like layout with the controls aligned on the right for readability
- [ ] Searchable settings: fuzzy search bar at the top, with a little debounce
- [] Move asset related settings to a top-level Assets category and include paths to search for Clap plugins. Default values should point to common clap paths on linux.

#### Asset Browser

- [ ] each asset path entry from settings should show as its own top-level folder in the tree.
- [ ] Split browser into two vertical areas, tree at top and details at bottom. Details show info about item, dependong on asset type. audio can show waveform and a preview button that plays the sound, ideally this should play to the output the master is set to (don't play on the master itself, that would color the preview if master has any fx devices.)
- [ ] Tree view can have icons, maybe audio / midi / device, we have a few lucide icons, but we might fetch more filetype icons from lucide.dev

### AI Assistant

Design notes: `docs/ai-integration.md`, clip DSL: `docs/clip-text-format.md`

- [x?] Let AI set Tempo and Rhythm
- [x?] Let AI read and create ruler markers
- [x?] Attach selection as prompt context (range, selected clip(s), selected track, selected mixer channel); show a glowing badge in the chat composer for each active context that will be sent on the next message depending on selected element. Make a reusable badge component that is a rounded colored pin with optional icon and label (might use it elsewhere later).; logic should be depending on current view, if in Arrange view, send selected track, range and selected clips. If in Mixer view, only mixer related stuff (channel and/or device).
- [ ] Allow the AI to ask questions via a tool with multiple choice answers (but always with a custom answer option), optionally tagging a clip, track, channel. The question will then be presented to the user and the element highlighted in the chat (if clicked, select and make visible/scroll toward it in mixerchannel or timeline (and switch arranger/mix/edit view if needed).
- [ ] Implement conversation compaction — when triggered, send the conversation to a compaction model with instructions to summarize it, focusing on the important bits. Add configuration settings to Settings/AI menu (threshold and what model to use). Compaction prompt can be a .md file with a {conversation} variable maybe?
- [ ] Add to AI settings personality presets for assistant. Default (helpful, concise, friendly), and Teacher is an interesting idea (less dumping info, more back-and-forth)
- [x?] AI Assistant needs a way to remove clips from timeline, and/or allow place_clip to optionally overwrite.
- [x?] AI Assistant needs a way to move clips. Instead of cut/copy/paste that need several tool calls, we could make atomic tools that take a range and a track_filter parameter. A move_clips (select_start=1.1.1, select_end=3.1.1, destination_start=5.1.1, tracks=[tracks default to all maybe])


- [x?] scope chat conversation dropdown to current project file, and automatically open convo when opening a prior project


- [x?] Store request/response JSON for debugging, with a reference on messages. Messages in UI show a small `{ }` link (tokens/cost) that opens a syntax-highlighted request/response viewer. Retention: Settings → AI → Keep Request Logs
- [x] Button in chat UI: on click, open a popup showing the last rendered system prompt
- [x] Format code and JSON in chat messages (especially tool call / tool result bubbles) for readability and easy dev UX
- [x?] Investigate if tool results can be presented in a simpler way to assistant? (see docs/ai-tool-results-plan.md)
- [x?] AI device tools should resolve devices by name once devices are freely renamable, matching the existing track/channel name lookup
- [x?] Formalize naming convention for clips, tracks, channels and devices as "Capitalized Lower Case"; assistant name lookup should normalize/resolve regardless of exact casing (e.g. "capitalized_lower_case" or arbitrary user casing). `NameStyle`: lookups and uniqueness compare by `key()`, AI-supplied names go through `format()`, system prompt states the convention
- [x?] AI tools: fuzzy device lookup, default clip placement + overlap refusal, reference tracks/channels by name instead of id (see docs/ai-names-and-placement-plan.md)
- [x] Debugging: show conversation token usage (TokenEstimate for unsent messages) and % of max context limit (context_length from /models); meter + breakdown tooltip in the chat header


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