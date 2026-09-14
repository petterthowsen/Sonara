# TODO

[ ] is open, [x?] implemented but not verified, [x] is verified, [/] is mixed status.

## Audio Engine

### Mixing & Playback

- [ ] Plugin latency compensation
- [ ] Mixing: pre-fader send audio is copied before the device pre-pass, so pre-fader sends from instrument channels are silent
- [ ] Read MIDI input directly in the engine instead of through Godot (Godot adds up to a frame of jitter)
- [ ] Make sample rate and buffer size configurable (currently constants in `engine.rs`)

Done:

- [x] Keep audio engine running after playback so instruments (PolySynth) and reverb/delay effects can settle after stopping
- [x] Solo causes a sharp click
- [x] RMS Metering
- [x] Performance profiling: emit engine load metrics via OSC for UI display
- [x] Mixing: reverb/delay tails on a routed bus cut off when playback pauses (verified live)
- [x] Mixing: a bus or master that receives audio in more than one routing pass runs its devices and pan more than once per buffer (verified live with nested buses)
  - Fix: routing and sends run in dependency order (`pending_inputs` in `MixBuffers`). Each channel finishes once, after all its inputs; route targets run devices even with no input, then pan, then route onward.
- [x] Solo behavior: Bus channels should still sound when instrument/audio channels are soloed
- [x] Solo behavior: Bus solo is a group solo (route feeders stay fully audible; send-only feeders keep the send and mute dry)
  - Engine implemented; needs live verification
- [x] Mixer channel sends do not sync bus names until send knob is touched

### Audio Thread

- [ ] Remove the shared `Arc<Mutex<EngineState>>` (phase 2): the audio thread should own its state and drain a lock-free command queue, with removed objects sent back to be dropped off-thread
  - [ ] Phase 1, partly verified live (CLAP on a bus, large clip import during playback): slow commands (plugin scan, device create/drop, plugin GUI/activation IPC) run outside the lock in `CommandWorker`; the callback uses a bounded `try_lock` and outputs silence
- [ ] Audio thread allocations still left: unbounded status channel sends, `process_device_chain` sleep-change Vec, `audio_playback_positions` insert (String clone) on clip start, `poll_parameter_changes` sets a socket read timeout every buffer per CLAP plugin
  - [ ] Removed, needs live verification: per-buffer Vecs/HashMaps and buffer clones in `process_audio`/`mix_and_output`, debug `info!` logging in the callback
- [ ] CPU affinity for audio thread and plugin processing
- [ ] Realtime thread priority configuration
- [ ] CPU core assignment for plugin processing

### Devices & Plugins

- [ ] DeviceInstance and their UIs should init with loading state and wait for Engine updates
- [ ] Multi-in and multi-out for devices
  - [x] Drum Machine pads feed nested child mixer channels (extra-out buses before the child device chain)
  - [ ] CLAP extra output ports into shared memory (child return channels are created when `audio_out_channels > 2`)
- [ ] Add support for enum parameter type for builtins
- [ ] Verify drag-to-reorder devices with builtin, CLAP and SFZ devices (engine + UI implemented)
- [ ] In Engine: Simplify device advertisement to avoid creating temporary instances
- [ ] Crash / Error handling, send info to Godot for UI notifications
  - [x] Engine logs a warn and higher are sent over OSC
- [ ] Plugin GUI windows should be forced to stay above Godot App
- [ ] Sforzando CLAP GUI embeds but renders black (may need an OpenGL context on the host window)
- [ ] Improve logging of plugins

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
- [x] Sampler ADSR (high prio — samples click without an envelope)

---

## Godot

### Mixer & Tracks

- [ ] Soloing a channel from mixer should sync to the linked track
- [ ] Sync selection of tracks and linked channels bidirectionally
  - [ ] Might make this behavior adjustable in settings
- [ ] Delete, Duplicate Channels
- [ ] Duplicate track
- [ ] Investigate metering in mixer and track UI: improvements, whether the current approach is sound, and any bugs. Lerp/smooth the peak? also should probably add text showing the peak value along with the line
- [ ] BUG: inline edit of channel names often has unreadable text color

### Arranger & Timeline

- [x] Ruler: Add secondary marker/ruler lanes (real-time ruler)
- [ ] Chord track: Implement chord track with visual notations
- [x] Marking track: Add marking/marker tracks (section labels, etc.)

### Clips

- [ ] Look at ways to improve waveform generation and display
- [/] TimelineClip context menu
  - [x?] SmartLineEdit for clip name
  - [ ] Cut
  - [ ] Copy
  - [x] Make Unique: makes clip instance unique (if ClipInstance shares underlying clip with any other ClipInstance)
    - [ ] gray the button if there's only one instance of it
  - [x] Delete
- [ ] some way to visually say if a clip is instanced more than once
  - [ ] context menu > select all instances (grey if none)

### Clip Editor / Note Editor

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

### Devices

- [x] SamplerDefaultView, DrumMachineDefaultView etc should have their static layout in the scene rather than generated in code

Done:

- [x] Drag a device between drum-machine slots (e.g. kick C1 → E1). Occupied target: swap.
- [x] Dragging devices around on the device lane, or within containers: drop targets occupy space at all times but are invisible, serving as spacers and drop targets simultaneously
- [x] Drum Machine: Clicking a slot should play the sample (velocity from the Y click position in the slot with some padding so that 80% Y position is highest velocity and 20% Y is lowest velocity)

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

### UI / Quality of Life

- [ ] Investigate overall frontend architecture: deviations from code style / best practices, and organization improvements — prioritize low-risk, high-ROI
- [x] Add [Lucide](https://lucide.dev) icons throughout the UI; curate a subset as selectable track/channel icons
- [x] Dock system: Inspector, Browser, and AI Chat freely placeable
  - Two side docks (left / right)
  - Each dock can stack panels vertically; split is draggable when two panels share a dock
  - Ensure drop targets never change size (show/hide visually only)
- [x] Asset Browser: Persist tree/list mode state and collapsed/uncollapsed folders

### AI Assistant

Design notes: `docs/ai-integration.md`, clip DSL: `docs/clip-text-format.md`

- [ ] Store request/response JSON for debugging, with a reference on messages. Messages in UI can show a small link to open a popup showing a syntax-highligthed the request and response cycle.
- [ ] scope chat conversation dropdown to project
- [x] Button in chat UI: on click, open a popup showing the last rendered system prompt
- [x] Format code and JSON in chat messages (especially tool call / tool result bubbles) for readability and easy dev UX
- [ ] Attach selection as prompt context (timeline range, selected clip(s), selected track, selected mixer channel); show a glowing badge in the chat composer for each active context that will be sent on the next message depending on selected element. Make a badge component that is a rounded colored pin with optional icon and label.
- [ ] Investigate if tool results can be presented in a simpler way to assistant?
- [ ] Add to AI settings personality presets for assistant. Default (helpful, concise, friendly), and Teacher is an interesting idea (less dumping info, more back-and-forth)
- [ ] Allow the AI to ask questions via a tool with multiple choice answers (but always with a custom answer option), optionally tagging a clip, track, channel. The question will then be presented to the user and the element highlighted and scrolled towards in mixerchannel or timeline (and switch arranger/mic view if needed).

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
However, we should ensure they are concise and not full of detail that might not be needed at the time. Also, if there are large amounts of changes - probably just say "The user has made significant changes to X, Y, Z" (xyz = categories like tracks, clips etc).

We can check how many clip modifications, if it's a lot, we can collapse to "modified 4 clips" or such.