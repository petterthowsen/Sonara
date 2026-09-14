# Frontend Architecture Audit (Godot UI)

Date: 2026-09-14. Snapshot: `dev` @ `85c6ad8`. Scope: `Godot/` (excluding `addons/`), 208 scripts, ~45.6k lines.
TODO item: *Investigate overall frontend architecture: deviations from code style / best practices, and organization improvements — prioritize low-risk, high-ROI.*

Line numbers are approximate and will drift. **Verification levels:**
- ✅ = re-checked directly in the source during this audit
- 👁 = found by careful code reading, not re-checked or run
- ❓ = suspected; confirm with logging before fixing

Risk / payoff / size use L/M/H and S/M/L.

---

## 1. Executive summary

The overall shape is good. There is a clear data layer with self-syncing models, reusable `components/` (none of them touch `Sonara.editor`), a working command history, cleanly split docks, and AI tools that mostly go through the same commands as the UI.

The audit found four kinds of problems:

1. **Real bugs hiding in the plumbing.** About 30 were found, many of them S-sized. Several are user-visible:
   - Save after Open acts as Save As.
   - Physical MIDI input is never enabled.
   - Undo can report "clean" when the project is dirty.
   - Two instances of one plugin clobber each other's parameters.
   - The arranger redraws every frame while idle.
2. **Leaks from lifecycle and signal wiring.** Signals are not disconnected on rebind or close. `bindv` connections can never be disconnected. Device panels are freed without unsubscribing their data streams. Closed projects stay alive through reference cycles and can resync to the engine.
3. **Layering drift.** Some OSC is sent outside `data/`: transport in `Editor.gd`, MIDI in `MidiManager`, and plugin/builtin discovery in `DeviceAssetProvider`. Meanwhile the data layer reaches *up* into the UI: `Track.gd` searches the `mixer_channel` scene group, and `DeviceInstance.create_view()` instantiates scenes.
4. **Style and organization debt.** Four files exceed the 1000-line hard limit. There are 430 raw `print()` calls even though a `Log` class exists. Drop-handling and device-list code is heavily duplicated. Stale test and scratch files sit in the project root. Some settings defaults disagree between files.

**Recommendation:** spend roughly 2–3 days on the Phase 1 quick-win batch (§3) before any structural refactor. It fixes the visible bugs and removes noise that makes later refactors harder to verify. After that, the three highest-leverage structural moves are:
- a `Transport` model
- splitting `Project.gd`
- a shared device-drop / device-chain helper

---

## 2. Metrics

| Metric | Value | Guideline |
|---|---|---|
| Files > 1000 lines | 4: `Project.gd` 1792, `Timeline.gd` 1183, `NoteEditor.gd` 1128, `MixerChannel.gd` 1002 | never > 1000 |
| Files 600–1000 lines | 13 (incl. `Browser.gd` 952, `Channel.gd` 931, `TrackList.gd` 920, `Arranger.gd` 889, `Editor.gd` 864) | prefer < 600 |
| `print()` calls | 430. Top files: NoteEditor 33, Project 30, SpectrumAnalyzerView 27, Channel 27 | use `Log` |
| Files using `Log.make` | 9 | all |
| Files lacking a `##` class doc | ~133 / 208 | all |
| Untyped `var x = …` | ~1720, vs ~3210 typed | typed |
| Function spacing violations (< 2 blank lines) | ~356 (heuristic) | 2 blank lines |
| `"""docstrings"""` instead of `##` | common in Editor, Settings, Browser, Mixer, Project | `##` |
| OSC `send`/`listen` outside `data/` | `Editor.gd` (9), `DeviceAssetProvider.gd` (6), `MidiManager.gd` (3), `EnginePanel.gd` (1) | 0 |
| Hardcoded `Color(...)` literals | 92 | exports / theme |
| `project.godot` warnings disabled | `unassigned_variable`, `unused_variable`, `unused_parameter` | — |

---

## 3. Phase 1: quick wins (low risk, high ROI)

Each item below is S-sized and independent, so they can go in as small commits.

### 3.1 Bugs

| # | Bug | Where | Fix | Ver. |
|---|---|---|---|---|
| B1 | **Save after Open acts as Save As.** `load_project` sets `project_path` and then calls `open_project()`. That calls `close_project()`, which clears the path. | `editor/Editor.gd` ~415, ~347 | Set `project_path` after `open_project()`, or pass it as a parameter. | ✅ |
| B2 | **Physical MIDI input never works.** `handle_physical_midi_event` drops devices that are not in `enabled_devices`. That list defaults to the virtual keyboard only, and `set_device_enabled` has no callers. Device IDs are also port indices that come back from JSON as floats. | `midi/MidiManager.gd` ~71, ~251, ~113 | Enable physical inputs by default or add a UI toggle. Persist by device name and cast with `int()`. | ✅ |
| B3 | **Undo save point can falsely report "clean".** Save at depth 3, undo to 1, make two new edits: the stack is at depth 3 again and reads as the save point. Merging into the save-point entry also keeps it clean. | `history/CommandHistory.gd` `_push` ~177 | In `_push`, if `save_point_index > _undo_stack.size()`, set it to -1. Don't merge when `size == save_point_index`. | ✅ |
| B4 | **Logger keeps every message in memory forever.** The `*_messages` arrays are never read. `AudioEngineOSC.send` logs *every* outgoing message at INFO: notes, parameter drags, clip moves. | `support/Log.gd` ~128–181, `AudioEngineOSC.gd` ~99 | Delete the arrays. Log sends at `debug`, or not at all. | ✅ |
| B5 | **Arranger scroll loops every frame.** `_process` sets `grid_helper.scroll_position` to the float lerp value, then `_update_ruler()` sets it back to the integer scroll value. Two `changed` emits per frame, forever, whenever the target is fractional. Each emit recomputes timeline width (walking all clips) and redraws rulers. | `arranger/Arranger.gd` ~239, ~285, ~513 | Round targets to whole pixels. Assign `scroll_position` once per frame. Recompute song length only when clips change. | ✅ |
| B6 | **ClipEditor wipes its own selection.** `selected_clips = pending_clips` aliases the array, then `pending_clips.clear()` empties both. | `clip_editor/ClipEditor.gd` ~141, ~171 | `pending_clips = []`. Also remove the leftover `or true` at ~117. | ✅ |
| B7 | **Pan undo is wrong in dual mode.** The command captures `channel.pan` instead of `pan_left`. | `mixer/MixerChannel.gd` ~328 | Capture `pan_left if dual else pan`. | ✅ |
| B8 | **`bindv` connections are never disconnected.** `parameter_changed.connect(cb.bindv([position]))` is disconnected with the unbound callable, which never matches. Connections accumulate on add/undo, and the bound `position` goes stale after moves, so `ParameterList` and `DevicePanel` refresh the wrong device. | `data/Channel.gd` ~625, ~656, ~913 | Delete the relay. Emit or connect with the `DeviceInstance` instead of its position. | ✅ |
| B9 | **Device files load twice on connect.** `Channel.sync_to_engine` loads with a `req_id`, then `DeviceInstance.connect_to_engine` sends `load_file` again without one. It also has no guard against being called twice, so listeners are registered twice. | `data/DeviceInstance.gd` ~415, `data/Channel.gd` ~163 | Make `connect_to_engine` register listeners only, and add an `_is_connected` guard. | ✅ |
| B10 | **Freeing a `DevicePanel` leaks engine subscriptions.** It has no `_exit_tree`, so views never receive `_on_view_hidden()` when the lane clears. For example, a spectrum analyzer keeps streaming. The Large popup is parented to `Sonara.editor` and outlives the panel. | `devices/device_lane/DevicePanel.gd`, `DeviceLane.gd` ~104, ~168 | Add `_exit_tree()` that calls `_close_large()`, `_clear_panel_and_aux()` and unbinds the device. | ✅ |
| B11 | **Mixer never disconnects `project.channel_added` / `channel_removed` on close.** | `mixer/Mixer.gd` ~97, ~116 | Disconnect them in `_on_project_closed`. | ✅ |
| B12 | **Shared `Device` parameter lists are overwritten per instance.** `DeviceInstance._on_param_count_received` clears and refills `device.parameters` on the *registry* object shared by every instance, so two SFZ or CLAP instances clobber each other. *(M-sized; listed here for its payoff.)* | `data/DeviceInstance.gd` ~534, ~559 | Store advertised parameters on the instance. | 👁 |
| B13 | **Closed projects can come back to life.** `disconnect_from_engine()` returns early when the state is DISCONNECTED, so listeners stay registered. `Track._project_ref` ↔ `Project.tracks` form a cycle. When the engine reconnects, the dead project re-inits and resyncs. | `data/Project.gd` ~611, `Track.gd` ~111, `Channel.gd` ~105 | Always unregister listeners. Use a `WeakRef` (as `DeviceInstance` does). Clear `routed_tracks` on close. | 👁 |
| B14 | **Undoing a track delete loses children and position.** | `history/commands/TrackDeleteCommand.gd` | Snapshot the subtree and layout, then restore via `apply_track_layout`. *(M)* | 👁 |
| B15 | **Small crashes and wrong values:** <br>• `Channel._on_peak_received` checks size ≥ 2 but reads `[3]`. <br>• `Clip.find_average_note` divides by zero on an empty clip. <br>• `Project.from_json` defaults `next_channel_id` to 1, which is master's ID. <br>• `Channel.pan_changed` is declared with 1 argument but emitted with 2. <br>• `Track` sets `default_channel_id = -1` *before* `disconnect_from_engine()`, which checks `>= 0`. | `data/*` | One-liners each. | 👁 |
| B16 | **Note editor:** <br>• A mid-drag Shift/Alt switch rebuilds the drag snapshot without `clip_instance`, which breaks cross-clip transfer. <br>• Arrow-key nudge ignores the clip offset in track mode. <br>• `bind_to_clips` early-returns and keeps a stale `track`. | `clip_editor/note_editor/NoteEditor.gd` ~379, ~710, ~995; `NoteContainer.gd` ~183 | Use one `_snapshot_selection()` helper. Call `_update_single_note_position`. Compare `owner_track` in the early-return check. | 👁 |
| B17 | **Undo history gaps and bypasses:** <br>• Arrow-key clip moves are not undoable. <br>• Time-signature changes are not recorded, so undo/redo can mark the project clean while the change is unsaved. <br>• TrackList device drops call `channel.add_device` directly. <br>• `TrackItem` renames with `track.name =`. | `Timeline.gd` ~951, ~982; `Editor.gd` ~524; `TrackList.gd` ~504–572; `TrackItem.gd` ~442, ~492 | Route through `HistoryUtil` / existing commands. | 👁 |
| B18 | **AI batch and undo interaction.** The Assistant opens a macro and then `await`s tools. Ctrl+Z pops older history while the macro is open, and UI edits made meanwhile silently join the "Assistant" macro. | `ai/Assistant.gd` ~249 | Block undo/redo while a macro is open. Close the macro on every exit path. | 👁 |
| B19 | **Autoload order.** `MidiManager._ready` runs before `Settings` is in the tree, so `get_node_or_null("/root/Settings")` returns null and it never hears setting changes. | `midi/MidiManager.gd` ~83, `project.godot` | Use the `Settings` global directly, or reorder the autoloads. | ❓ |
| B20 | **Caps-lock `toggle_computer_keyboard` action is declared but never handled.** | `project.godot`, `MidiManager.gd` | Handle it in `_input`. | 👁 |

DONE

### 3.2 Performance quick wins

- **`MixerChannel._process`** polls the cursor every frame per strip. Use `_gui_input` and enable processing only while resizing or moving. `DeviceLightButton._process` has the same problem.
- **`MidiclipRenderer._process`** polls per clip per frame through `Sonara.editor.arranger.timeline` and uses `print_rich` inside `_draw`. Listen to `grid_helper.changed` instead.
- **Browser rebuilds:** `asset_added` and `assets_updated` both trigger a full `_refresh_asset_list()`, so adding N files causes N+1 full rebuilds. Listen only to `assets_updated` and coalesce the refresh with `call_deferred`. Also debounce search and mark other tabs dirty (they currently show stale results after switching).
- **`AudioEngineOSC`** compiles a new `RegEx` for every `/data` message and walks all listener patterns per message. Cache the regex and keep wildcard listeners in a separate list.
- **`SpectrumRenderer`** calls `log()` per bin per redraw and allocates a `PackedVector2Array` each frame. Cache bin x positions and reuse the buffer.
- **`TimelineTrack._draw_grid`** draws the full content width on every track during zoom. Clip it to the visible range.

DONE

### 3.3 Dead code and leftovers to delete

All of these were grepped for references across `.gd`, `.tscn` and `.tres`. Moves and deletes of scenes should go through the Godot editor or MCP so UIDs stay intact.

- **Root scratch files:** `AudioFileLoader.gd` (310 lines, zero refs; the engine decodes now), `Test.gd` + `test.tscn`, `mcp_testing/test_scene.tscn`, `components/test_components.tscn`, `assets/theme_testing.tscn`.
- **`AudioEngineOSC`:** `send_audio_data()` (no callers), and the unused `engine_log_message` / `device_data_received` signals.
- **`Editor.gd`:** the deprecated `clip_instance_selected` signal and its emit, the unused `browser_panel` / `assistant_panel` `find_child` lookups, `pause_here()`, and the commented-out block ~145.
- **`Device.gd`:** `create_builtin_oscillator/delay/sfizz`, `register_visual_scene` / `visual_scene_path`, `register_controls_scene` / `controls_scene_path` / `has_custom_controls`.
- **`Channel.gd`:** `get_pan_coefficients`, `get_linear_gain`. **`Track.gd`:** `_update_channel_link`, the no-op `_on_clip_note_*` handlers and their wiring, and the `track_color` alias. **`Project.gd`:** `get_track_siblings`, `next_clip_id`, and the no-op `_is_engine_connected` read ~144. **`ClipInstance.gd`:** `get_midi_notes_for_playback`.
- **`NoteEditor.gd`:** `_snap_position_to_grid`, `_find_clip_instance_for_note`, `drag_start_ticks`. **`Arranger.gd`:** `_timeline_tracks`, `_get_track_index_at_position`, `_find_track_by_id` and the `_on_track_added` / `_on_track_removed` wiring. These also index by the wrong order.
- **`AiTool.is_read_only()`** is never read. Either use it (skip the macro for read-only batches) or drop it.
- **`test_scoring.gd`** is stale: it fails all 3 scenarios against the current `Utils.fuzzy_match` and never asserts. Rewrite it as property assertions under `tests/`, or delete it.

### 3.4 Logging cleanup

Replace `print()` with `Log.make("Name")` loggers. Start with the hot paths, where the noise costs real time:
- per-note prints during drag (`NoteEditor.gd` ~480)
- per-parameter prints in `DeviceInstance.sync_parameter_to_engine` and `SpectrumAnalyzerDefaultView`
- `Channel.set_pan` / `set_color`
- every volumeter drag (`TrackItem.gd` ~468)
- every waveform level (`TimelineClip.gd` ~205)
- `NoteContainer.gd` ~340, which builds a debug string even when logging is off

Warning-level prints should use `logger.warn` / `push_warning`. This is mechanical and safe, and it makes the log useful again for the debugging workflow described in AGENTS.md.

### 3.5 Security

The OpenRouter key is stored in plaintext in `~/.config/sonara/config.json`, which is world-readable (mode 644). `base_url` accepts `http://`, so the Bearer token can go out unencrypted.
- Set the file mode to 0600 on save.
- Prefer the `OPENROUTER_API_KEY` environment variable.
- Warn on non-TLS URLs that aren't localhost.

---

## 4. Cross-cutting themes

### 4.1 Layering: OSC outside `data/`, and the data layer reaching into the UI

Two opposite leaks break the documented rule that the UI calls setters and the data layer owns OSC.

**UI / services sending OSC directly**

| Location | What | Proposed home |
|---|---|---|
| `editor/Editor.gd` ~239–527, ~757–848 | `/transport/*` sends, `/status/playhead` and `/status/playing` listeners, playhead smoothing, BBT conversion | new `data/Transport.gd` (see §5.1) |
| `midi/MidiManager.gd` ~457–473 | per-note MIDI OSC | `Channel.send_midi()` / `send_cc()` |
| `browser/DeviceAssetProvider.gd` ~81–369 | `/plugin/scan`, `/builtin/request` protocol, `Device` construction, log-parameter guessing by name | new `data/DeviceRegistry.gd`; the provider only maps devices to `Asset`s. The log flag should come from the engine. |
| `editor/EnginePanel.gd` ~103 | `/status/engine_load` listener | small engine-status model, or accept it as a documented exception |

**Data layer depending on the UI or `Sonara.editor`**

| Location | Issue | Fix |
|---|---|---|
| `data/Track.gd` ~337–408 | `_find_channel_in_mixer_ui`, `_adopt_channel_into_project`, `_fallback_project`: searches the `mixer_channel` scene group to "recover" channels. This covers up a root-cause bug where channels drop out of `project.channels`. | Log the root cause, delete the fallbacks, fail loudly. |
| `Channel.gd` ~558–713, `AuxReturnSync.gd` ~127, `DeviceInstance.gd` ~642 | `Sonara.editor.project` fallbacks | Inject `_project_ref: WeakRef`. |
| `Clip.gd` ~393 | Note IDs allocated from `Sonara.editor.project.next_note_id`, also incremented by hand in 5 UI places | `Project.allocate_note_id()`, passed in as a Callable. |
| `Project.gd` ~265, ~553 | `Sonara.editor.get_tree()` for timers | `Engine.get_main_loop() as SceneTree` |
| `DeviceInstance.gd` ~361 `create_view()` | Data object instantiates UI scenes | `devices/DeviceViewFactory.gd` (3 callers, all in `DevicePanel`) |
| Various | Private fields read across classes: `_is_connected`, `_synced_to_engine` (including from `ai/clip_text/ClipTextGrid.gd`), `_color`, `_name` | Public accessors |

### 4.2 Signal lifecycle

One recurring pattern causes most of the leak bugs: views connect to data signals in `bind_*` or `_on_project_opened` and never disconnect them. Examples: `Mixer`, `EnginePanel`, `TrackItem.bind_to_track`, `DeviceView.bind_to_device`, `DevicePanel` (`plugin_gui_closed` with no `is_connected` guard), and the `_clear_all_*` methods in Timeline and TrackList.

Suggested convention, documented in `godot-architecture.mdc`:
- Every `bind_to_x(obj)` starts with `_unbind()` and ends by storing `obj`.
- `_unbind()` is also called from `_exit_tree()`.
- Never connect a `bind`/`bindv` callable you intend to disconnect. Keep the bound callable in a variable, or pass the object in the signal instead.

### 4.3 Settings: one store, two access paths, disagreeing defaults

There is a single store (`Sonara.get_config` / `set_config`). `Settings` is a metadata registry on top of it. Most consumers bypass `Settings`, so defaults are copied and disagree. For example, `assets/sfz/paths` defaults to `~/Music/libs/SFZ` in `Settings.gd`, `~/Music/SFZ` in `AssetService.gd`, and `[]` in `SfzAssetProvider.gd` / `Browser.gd`.

Other symptoms:
- `MidiManager`'s transpose and velocity hotkeys write config without signalling or saving.
- `SettingsDialog` uses dynamic `.call("emit_signal", …)`.
- The key `appearence/…` is misspelled.

**Rules to adopt:**
- Registered user settings always go through `Settings.get_value` / `set_value`.
- `Sonara.get/set_config` is only for internal UI state (dock layout, browser state).
- Delete `AssetService._setup_default_config`.
- Update `godot-config-system.mdc`, which doesn't mention `Settings` at all.

### 4.4 Duplication hot spots

| Duplicate | Locations | Extraction |
|---|---|---|
| Device drop zones and drop handling | `DeviceLane.gd` ~193–270, `ChannelDeviceList.gd` ~171–256, `NestedDeviceList.gd` ~183–277, `MixerChannel.gd` ~952–1019, `DevicePanel.gd` ~393–434, `CompactDevicePanel.gd` ~185–230 | `DeviceChainDropHost` helper plus `DeviceDropUtil.can_drop_on_device` / `drop_on_device`. Delegate `MixerChannel` drops to the existing `DeviceDropUtil`. |
| "Which channel owns this device" | `DevicePanel`, `CompactDevicePanel`, `DrumPad`, `NestedDeviceList`, `ParameterList` | `DeviceInstance.get_channel()` |
| `create_timer(0.1)` before `load_file` | `DeviceDropUtil.gd` ~176, ~308, `MixerChannel.gd` ~1070, `Mixer.gd` ~620, `TrackList.gd` ~575 | `DeviceInstance` holds a pending path and sends it once the engine confirms the device. This also fixes B18's await window. |
| FS vs SFZ asset providers (~95% identical) | `FileSystemAssetProvider.gd`, `SfzAssetProvider.gd`; `_expand_path` ×3 including `Browser.gd` | `FileScanAssetProvider` base class, `Utils.expand_path` |
| Waveform pyramid ingest | `Clip.gd` ~98–207 vs `devices/DeviceWaveform.gd`; parallel clip/device branches in `Project._on_audiofile_*` | a single `WaveformPyramid` helper |
| Asset search | `AssetService.search_assets` (substring, used by the AI) vs Browser fuzzy scoring | `AssetSearch.score()` used by both; the AI currently gets 0 hits for queries the Browser finds |
| Scroll/zoom lerp, cursor-anchored zoom, middle-mouse pan | `Arranger.gd` ~223–429, `MidiEditor.gd` ~179–506 | `ViewNavigator` (RefCounted) around `GridHelper` |
| Track-list binding and visual order | `Timeline.gd` ~75–236, `TrackList.gd` ~82–212 | `VisualTrackListBinder` |
| Clip creation (create → color → length → command) | `CreateClipTool.gd`, `TimelineTrack.gd` ~337, `NoteContainer.gd` ~690 (the last one bypasses history) | `ClipActions.create_midi_clip()` |
| "One command, or a macro if several" | 8+ sites in Timeline and NoteEditor | `HistoryUtil.execute_many` / `record_many` |
| Snapping | manual floor snapping in `TimelineClip` ×3 and `NoteEditor` ×5 vs `GridHelper.snap_ticks` (round to nearest) | `GridHelper.floor_ticks()`; snap the drag *delta*, not each note |
| Sibling sorting, subtree checks, enclosing-folder lookups | `Project.gd` ×5; `track_is_in_subtree` ≡ `channel_is_in_subtree`; `create_instrument_track` ≡ `create_audio_track` | `_ancestor_where()`, `_alloc_track()` |
| Model serialization | hand-written `to_json`/`from_json` with disagreeing defaults (Channel volume -6 vs 0, sample rate 44100 vs 48000, track height 48 vs 38, colors via `to_html` vs `Utils.color_to_json`) | a small `JsonFields` table helper; a shared base class is not recommended |
| Track/channel kind helpers | `AiTool.gd` ~139–163, `PromptContext.gd` ~280–307 | shared static |
| Pan-mode UI | `MixerChannel.gd` ~309–320 vs ~659–670 (verbatim copies) | `PanControl` component |
| Ruler header, colors, start arrow | `Ruler.gd`, `RealTimeRuler.gd` | `BaseRuler` |

### 4.5 Code-style conformance

These are mechanical items, best done file by file *while touching them* rather than in one big diff:
- Switch `"""docstrings"""` to `##`. Note that `## ====` banner lines attach to the next symbol as doc comments.
- Use two blank lines between functions.
- Add types to untyped locals and collections: `Array[SendConfig]`, `Array` automation lanes, `Dictionary` lookups in `Project`.
- Move hardcoded colors and sizes in `_draw` to exports or the theme: `SamplerDefaultView` (6), `Meter`, `DropZone`, `SendControl`, `SpectrumRenderer` labels.
- UI built in code, against the style guide: `DevicePanel._create_cc_tab` / `_create_container_folder`, `SendsPanel.SendControl`.
- `BBT` math ignores the time-signature denominator (6/8 is shown as six quarters). It is consistent across `Editor.gd`, `GridHelper.gd` and `ClipTextTime`, so fix it in `GridHelper` and delete the Editor copy.
- Consider re-enabling `unused_variable` / `unused_parameter` warnings (prefix intentionally unused names with `_`). That would have flagged much of the dead code above.

### 4.6 Tests

There are six test scripts in three places (root, `history/`, `ai/tests/`), each with its own copy-pasted `_assert` code and no runner.

Running them headless also boots every autoload:
- they read the real `~/.config/sonara`
- AssetService starts scans
- MidiManager opens MIDI inputs

In the reviewer's sandbox every script crashed at `MidiManager.gd` `OS.open_midi_inputs` *after* printing ALL PASSED (possibly environment-specific ❓). `test_device_tools.gd` also logs a compile error.

**Proposal:**
- Create `Godot/tests/` with a shared `TestBase` (asserts, failure count, exit code).
- Add `tests/run_all.sh`, which runs each script and checks the exit code.
- Autoloads skip side effects when `--test` is in `OS.get_cmdline_user_args()`.
- Move `history/test_command_history.gd` and a rewritten `test_scoring` there.

---

## 5. Phase 2: structural refactors (strategic)

These are listed in recommended order. Every split keeps thin delegating methods on the original class, so external callers don't change in the same commit.

### 5.1 `Transport` model: medium risk, high payoff, M

Move the following out of `Editor.gd` into `data/Transport.gd` (a Project child or a RefCounted owned by Editor):
- `play` / `pause` / `stop` / `seek`
- the playhead listeners and smoothing
- `is_playing`, `playhead_ticks`
- the `playback_*` and `playhead_moved` signals

Tempo and time signature become `project.set_tempo()` / `set_time_signature()`, both recorded in history. That fixes B17 and also the missing tempo propagation to `GridHelper` (❓: nothing listens to `tempo_changed` or sets `grid_helper.tempo`, so `RealTimeRuler` seconds may go stale).

Editor keeps forwarding signals for the existing listeners. Transport label updates move into a small `TransportBar.gd`. This takes `Editor.gd` from 864 to about 500 lines and removes the largest OSC layering violation.

At the same time, add `Editor.request_close(then: Callable)` and `Editor.new_project()` to consolidate the four "TODO: Prompt to save" sites (`Editor.gd` ~339, `MainMenu.gd` ~161, ~186, ~223). Also hook up `project_modified`, which has no listeners today, to the title bar.

### 5.2 Split `Project.gd` (1792 lines): L overall, do it in steps

1. **`data/project/ClipLoadCoordinator.gd`** (~450 lines, low risk): OSC listeners for clip and audiofile events, `req_id` maps, decode/waveform/progress/error handlers, waveform retry timers.
2. **`data/project/EngineSession.gd`** (~150 lines, low risk, *after B13*): connect, disconnect, confirm, mark unsynced. `_sync_clip_to_engine` moves into `Clip.sync_to_engine()`, which also removes the duplicated `/clip/create`.
3. **`data/project/MixRouting.gd`** (~150 lines): enclosing folder bus / group channel, track↔channel pairing, folder↔bus linking. `AuxReturnSync` lives next to it.
4. **`data/project/TrackHierarchy.gd`** (~500 lines, medium risk because of the re-entrancy flags): place, apply layout, children, visual list, nesting and the channel-nest sync.

Result: `Project.gd` is about 450 lines. A similar extraction of `ChannelDeviceChain.gd` (`Channel.gd` ~603–811) brings `Channel.gd` under 750.

### 5.3 Device chain and drop consolidation: low risk, medium payoff, M

This covers the device drop zones, "which channel owns this device" and the `create_timer(0.1)` rows in §4.4, plus `DeviceViewFactory` and `DeviceRegistry` from §4.1. It removes about 300 lines across six files and fixes several drop-behaviour inconsistencies. For example, `MixerChannel` drops skip the Audio-channel rule that `DeviceDropUtil` enforces.

### 5.4 Split `MixerChannel.gd` (1002 lines)

- `PanControl` component (~90 lines; removes the verbatim duplicate; fixes B7 in one place)
- `OutputRoutingButton` (extends MenuButton, ~120 lines)
- Delegate drops to `DeviceDropUtil` (−70 lines)
- `MixerChannelResize` helper (~130 lines)

Result: about 550 lines. In `Mixer.gd`, add a `Dictionary[int, MixerChannel]` registry in place of the `get_nodes_in_group("mixer_channel")` scans. Debounce the routing-menu and sends rebuilds, which are currently O(n³) when opening a project, and drop the second sends rebuild.

### 5.5 Split `Timeline.gd` (1183) and `NoteEditor.gd` (1128)

**`Timeline.gd`:**
- `ClipDragController` (~260 lines): drag state, horizontal/vertical apply, clamps, finish, `move_selection_by_*` with history.
- `ClipEditActions` (~200 lines): copy, cut, paste, duplicate, delete, make unique.
- `Timeline` keeps lifecycle, layout, input and hit testing (~450 lines).

**`NoteEditor.gd`:**
- `NoteGestureController` (~350 lines): drag, resize and place-and-drag. It should also absorb the mouse state machine from `MidiEditor._handle_*`, which today calls NoteEditor's private methods.
- `NoteEditActions` (~250 lines).
- `NoteEditHistory` (~60 lines).
- Extract `_commit_selected_notes()` (copied 4 times) and `_owner_ci(vn)` (4 times).
- Stop writing `selection_manager` internals from outside.
- Rename `multi_clip_mode` to `track_mode` (the TODO at `NoteContainer.gd` ~97).

Also: `TrackList.gd` (920) → `TrackReorderController` (~280) + `TrackAssetDropHandler` (~175). `Arranger.gd` (889) → `ViewNavigator` (§4.4).

### 5.6 Browser and asset pipeline: medium risk (threading), high payoff, M

- **Hot-reload scan off the main thread.** The 30 s `DirAccess` walk runs on the main thread. It opens every file just to read its size, detects removals in O(n²) with an Array `in` (~21M comparisons for 4.6k assets), and rewrites the 1 MB cache even when nothing changed.
  - Move the walk to `WorkerThreadPool` with a `call_deferred` handoff.
  - Use a Dictionary for removal detection.
  - Save only on change.
  - Do this together with the `FileScanAssetProvider` merge.
- **Split `Browser.gd` (952).**
  - `BrowserTreeBuilder` (static, ~250 lines)
  - `BrowserTreeState` (expanded-folder persistence, ~100 lines)
  - `AssetSearch` (shared with the AI)
  - Make the three `_populate_*` pairs data-driven.
  - Stop detecting folder headers by `Color.YELLOW`.
- **Metadata lost on rescan.** A manual rescan drops favourites and last-used (`_consolidate_provider_assets` never reloads metadata). `mark_asset_used` rewrites `assets.json` on every click; debounce it.

### 5.7 Project root reorganization: low risk, low–medium payoff, S

| Current | Move to |
|---|---|
| `Midi.gd` | `midi/` |
| `Utils.gd` | `support/` |
| `AudioEngineOSC.gd` | `support/` (or new `engine/`) |
| `test_scoring.gd`, `history/test_command_history.gd`, `ai/tests/*` | `tests/` (or keep `ai/tests` and add a runner) |
| `Sonara.find_waveform_cache_file` | the waveform / clip-loading code (its only user) |

After this the project root contains only `project.godot`, `Sonara.gd` and `icon.svg`. Do the moves through the Godot editor so `.uid` references stay valid.

---

## 6. Suggested roadmap

| Phase | Content | Est. |
|---|---|---|
| **1a: bug batch** | B1–B11, B15, B19, B20 | ~1 day |
| **1b: hygiene** | §3.3 dead code, §3.4 logging in hot paths, §3.2 perf quick wins, §3.5 key permissions | ~1 day |
| **1c: lifecycle** | B12, B13, B14, B16–B18; signal unbind convention (§4.2) | ~1–2 days |
| **2a** | Transport model + close/new consolidation (§5.1); settings access rule (§4.3) | ~1–2 days |
| **2b** | `Project.gd` split steps 1–2, then 3–4 (§5.2) | ~2–3 days |
| **2c** | Device chain / drop consolidation (§5.3), `MixerChannel` split (§5.4) | ~2 days |
| **2d** | Test runner (§4.6), root reorg (§5.7) | ~0.5 day |
| **3** | Timeline / NoteEditor / TrackList splits (§5.5), browser threading and split (§5.6), `ViewNavigator`, selection gesture sharing | as the areas get touched |

Suggested TODO.md entries to replace the investigation item:

```md
- [ ] Frontend audit phase 1a: bug batch (docs/frontend-architecture-audit.md §3.1 B1–B11, B15, B19, B20)
- [ ] Frontend audit phase 1b: dead code, logging, perf quick wins, API key perms (§3.2–3.5)
- [ ] Frontend audit phase 1c: lifecycle/undo bugs + signal unbind convention (B12–B14, B16–B18, §4.2)
- [ ] Transport model out of Editor.gd; unify save-prompt/close flow (§5.1)
- [ ] Split Project.gd (§5.2)
- [ ] Consolidate device drop/chain code; split MixerChannel.gd (§5.3, §5.4)
- [ ] Godot test runner + project root reorg (§4.6, §5.7)
```

---

## 7. What's already in good shape

- `components/` controls have no dependency on `Sonara.editor` or the project, so they are reusable.
- `editor/docks/` files are small, documented and free of OSC.
- AI tools mostly go through the same Commands and `DeviceDropUtil` as the UI. The exceptions are a few `set_name` / `clip.color` calls in `AddDeviceTool` and `CreateClipTool`.
- `CommandHistory`, `PropertyCommand` merging and `HistoryUtil` form a sound foundation; the bugs above are edge cases.
- `GridHelper` sharing works as documented. The remaining issues are manual snapping and duplicated navigation around it, not the helper itself.
- The `Log` class, with engine error capture into `Godot/logs/last.log`, is good infrastructure that just needs adopting.
- `Meter`, `RealTimeRuler` and `DropZone` already expose most visual values as exports.
