# Frontend Architecture Audit (Godot UI)

Date: 2026-09-14. Snapshot: `dev` @ `85c6ad8`. Scope: `Godot/` (excluding `addons/`), 208 scripts, ~45.6k lines.
TODO item: *Investigate overall frontend architecture: deviations from code style / best practices, and organization improvements — prioritize low-risk, high-ROI.*

Line numbers are approximate and will drift. **Verification levels:**
- ✅ = re-checked directly in the source during this audit
- 👁 = found by careful code reading, not re-checked or run
- ❓ = suspected; confirm with logging before fixing

Risk / payoff / size use L/M/H and S/M/L.

## Progress

Last updated: 2026-09-15. Tick an item when it's merged, and change the section's **Status** line to match.

| § | Item | Status |
|---|---|---|
| 3.1 | Bugs B1–B20 | ✅ Done |
| 3.2 | Performance quick wins | ✅ Done |
| 3.3 | Dead code and leftovers | ✅ Done |
| 3.4 | Logging cleanup (hot paths) | ✅ Done |
| 3.5 | API key file mode, env var, TLS warning | 🟢 Implemented, unverified |
| 4.1 | Layering | 🟡 Partial: Transport → §5.1 |
| 4.2 | Signal unbind convention | ✅ Done |
| 4.3 | Settings / Config layering | ✅ Done |
| 4.4 | Duplication hot spots | 🟢 Implemented, unverified; `ViewNavigator` and `VisualTrackListBinder` moved to §5.5 |
| 4.5 | Code-style conformance | 🟡 Partial: BBT math and warnings done |
| 4.6 | Test runner | 🟢 Implemented, unverified |
| 5.1 | `Transport` model | ⬜ Not started |
| 5.2 | Split `Project.gd` | ⬜ Not started |
| 5.3 | Device chain and drop consolidation | 🟢 Implemented, unverified |
| 5.4 | Split `MixerChannel.gd` | ⬜ Not started |
| 5.5 | Split `Timeline.gd` / `NoteEditor.gd` / `TrackList.gd` | ⬜ Not started |
| 5.6 | Browser and asset pipeline | ⬜ Not started |
| 5.7 | Project root reorganization | ⬜ Not started |

### TODO

- [x] **§3.3 Dead code.** Delete the root scratch files (`AudioFileLoader.gd`, `Test.gd` + `test.tscn`, `mcp_testing/test_scene.tscn`, `components/test_components.tscn`, `assets/theme_testing.tscn`) and the unused members listed in §3.3. Use the Godot editor for scene deletes.
- [x] **§3.3** Decide on `AiTool.is_read_only()`: use it or drop it. Rewrite or delete `test_scoring.gd`.
- [x?] **§3.5** Save `config.json` with mode 0600, prefer `OPENROUTER_API_KEY`, warn on non-TLS remote `base_url`.
- [x] **§4.2** Document the `bind_to_x` / `_unbind` / `_exit_tree` convention in `godot-architecture.mdc`, then apply it to `Mixer`, `TrackItem`, `DeviceView`, `DevicePanel` and the Timeline/TrackList `_clear_all_*` methods.
- [x?] **§4.4** Extract shared helpers, starting with the ones §5.3 needs: device drop host, `DeviceInstance.get_channel()` callers, pending `load_file`.
- [x?] **§4.4** `FileScanAssetProvider` base class and `Utils.expand_path`.
- [x?] **§4.4** `HistoryUtil.execute_many` / `record_many`, `GridHelper.floor_ticks`, `PanControl`, `BaseRuler`, `ClipActions.create_clip`.
- [x?] **§4.4** `AssetSearch`, `WaveformPyramid`, `JsonFields`, Project sibling/ancestor/subtree helpers, shared track/channel kind strings.
- [ ] **§4.5** `##` docs, spacing, typed locals, colors to exports/theme, scene-built UI. Do these file by file while touching each file.
- [x?] **§4.5** Remaining `print()` calls: converted to `Log.make` across app code (33 files, ~226 calls). Remaining `print()` calls are intentionally left in third-party addons (`addons/godot_ai`, `addons/godOSC`), headless test-runner scripts (`history/test_command_history.gd`, `ai/tests/test_*.gd`), and `support/Log.gd` itself.
- [x?] **§4.6** `Godot/tests/` with `TestBase` and `run_all.sh`. Added `Utils.is_test_mode()` (checks `--test` in `OS.get_cmdline_user_args()`); `Sonara`, `AudioEngineOSC`, `AssetService` and `MidiManager` skip their side effects in test mode. Migrated all five `test_*.gd` scripts to extend `TestBase`; moved `history/test_command_history.gd` to `tests/`; added `tests/test_fuzzy_match.gd` (rewritten `test_scoring.gd`, deleted in §3.3). Ran `tests/run_all.sh`: all six scripts pass, no `MidiManager` crash. `test_device_tools.gd`'s pre-existing `AudioEngineOSC` compile error (§4.6 note above) is unrelated and still present.
- [ ] **§5.1** `data/Transport.gd` out of `Editor.gd`; `project.set_tempo()` / `set_time_signature()` with history; `Editor.request_close()` / `new_project()`.
- [ ] **§5.2** Split `Project.gd` (1812 lines): ClipLoadCoordinator → EngineSession → MixRouting → TrackHierarchy.
- [x?] **§5.3** `DeviceRegistry` out of `DeviceAssetProvider`; consolidate device drops.
- [ ] **§5.4** Split `MixerChannel.gd` (1012 lines); mixer channel registry in place of group scans.
- [ ] **§5.5** Split `Timeline.gd` (1237), `NoteEditor.gd` (1131) and `TrackList.gd` (920); `ViewNavigator`, `VisualTrackListBinder` (from §4.4).
- [ ] **§5.6** Asset scan off the main thread; split `Browser.gd` (991); keep metadata on rescan.
- [ ] **§5.7** Move `Midi.gd`, `Utils.gd`, `AudioEngineOSC.gd` out of the project root (through the Godot editor).

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

## 4. Cross-cutting themes

### 4.1 Layering: OSC outside `data/`, and the data layer reaching into the UI

**Status:** 🟡 Partial. Data→UI leaks, MIDI and engine status are done; Transport and DeviceRegistry are open.

Two opposite leaks break the documented rule that the UI calls setters and the data layer owns OSC.

**UI / services sending OSC directly**

| Location | What | Proposed home | Status |
|---|---|---|---|
| `editor/Editor.gd` ~239–541 | `/transport/*` sends, `/status/playhead` and `/status/playing` listeners, playhead smoothing | new `data/Transport.gd` | Open, see §5.1 |
| `browser/DeviceAssetProvider.gd` ~81–369 | `/plugin/scan`, `/builtin/request` protocol, `Device` construction, log-parameter guessing by name | new `data/DeviceRegistry.gd`; the provider only maps devices to `Asset`s. The log flag should come from the engine. | Done (log flag still guessed by name; needs an engine change) |
| `midi/MidiManager.gd` | per-note MIDI OSC | `Channel.send_midi_event()` / `send_midi_cc()` | Done |
| `editor/EnginePanel.gd` | `/status/engine_load` listener | `data/EngineStatus.gd` (`start()` / `stop()`, `engine_load_received`) | Done |

**Data layer depending on the UI or `Sonara.editor`**: done. `grep Sonara.editor data/` is now empty.

| Was | Now |
|---|---|
| `Track._find_channel_in_mixer_ui`, `_adopt_channel_into_project`, `_fallback_project` searched the `mixer_channel` group to recover channels | Deleted. `Track._ensure_linked_channel` looks only in `get_project_ref()` and logs an error if `default_channel_id` isn't in `project.channels`. `pair_mixer_channel` logs an error if there's no project ref yet. `TrackItem` and `TrackItemContextMenu` no longer patch the ref from the UI. |
| `Channel._fallback_project` / `AuxReturnSync` / `DeviceInstance.load_file` used `Sonara.editor.project` | `Channel` holds a weak `_project_ref` (`set_project` / `get_project`), set in `Project._init` (master), `add_channel` and `from_json`, and cleared in `remove_channel`. `DeviceInstance` resolves the project through `get_channel().get_project()`. |
| Note IDs incremented by hand in 7 places | `Project.allocate_note_id()`. `Clip.cut_overlapping_notes_at_pitch` takes it as a required `Callable`. |
| `Project._get_scene_tree` used `Sonara.editor.get_tree()` | `Engine.get_main_loop() as SceneTree` |
| `DeviceInstance.create_view()` | `devices/DeviceViewFactory.create(instance, type)` |
| Private reads across classes | `Track/Channel.is_engine_connected()`, `Clip.is_synced_to_engine()` / `mark_synced_to_engine()` / `extend_content_length()`, `Track.apply_channel_color()` / `apply_channel_name()` |

### 4.4 Duplication hot spots

**Status:** 🟢 Implemented, unverified (2026-09-15). Compiles headless; helper round trips checked with a throwaway headless script; not yet exercised in the app.

Resolution notes:
- **Device drops / channel lookup / pending load:** see §5.3.
- **Providers:** `browser/FileScanAssetProvider.gd` holds the walk, diff, cache and timer; FS and SFZ providers are ~25 lines each. Removal detection uses a Dictionary and the cache is saved only when a scan changed something (the §5.6 threading work is still open). `Utils.expand_path` replaces the three `_expand_path` copies.
- **Waveform:** `DeviceWaveform` became `data/WaveformPyramid.gd`. `Clip` owns one as `clip.waveform` and forwards its old fields, and `Project`'s decode/level handlers use one path for clips and devices (`_waveform_for_req`). Retries stay clip-only.
- **Asset search:** `browser/AssetSearch.gd` (`score`, `rank`) is used by the Browser and by `AssetService.search_assets`, which also accepts a path substring hit.
- **Clip creation:** `history/ClipActions.create_clip()` (named without `_midi_` because the timeline double-click still creates audio clips on audio tracks). The note editor's clip creation is now undoable as its own step.
- **Macros:** `HistoryUtil.execute_many` / `record_many` replace the 7 Timeline sites, NoteEditor and three AI tools.
- **Snapping:** `GridHelper.floor_ticks()`. Note-editor position drags now snap the drag delta, so notes keep their relative offsets; resize uses `_snapped_duration()`.
- **Project:** `_sorted_track_siblings`, `_ancestor_where`, `_id_in_subtree` (tracks and channels) and `_create_track_with_channel`.
- **Serialization:** `data/JsonFields.gd` plus a `JSON_FIELDS` list on Channel, Track and Clip. Missing keys keep constructor values, which fixes the disagreeing defaults (Channel volume now -6 for non-master, Track height 48, Clip sample rate 44100). Clip colors are saved as RGBA arrays; legacy hex strings still load.
- **Kind strings:** `AiTool.track_kind` / `channel_kind` (now returns `master`) are used by `PromptContext`.
- **Pan UI:** `mixer/PanControl.gd` is the script on the `Panning` node, and `PanModePopup` moved under it in `MixerChannel.tscn`.
- **Rulers:** `components/BaseRuler.gd` holds the exports, GridHelper binding, background, start arrow and `_draw_tick_line`.
- **Not done here:** `ViewNavigator` and `VisualTrackListBinder` are interactive gesture/layout code that needs in-app testing; they move to §5.5.

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

**Status:** 🟡 Partial

These are mechanical items, best done file by file *while touching them* rather than in one big diff:
- Switch `"""docstrings"""` to `##`. Note that `## ====` banner lines attach to the next symbol as doc comments.
- Use two blank lines between functions.
- Add types to untyped locals and collections: `Array[SendConfig]`, `Array` automation lanes, `Dictionary` lookups in `Project`.
- Move hardcoded colors and sizes in `_draw` to exports or the theme: `SamplerDefaultView` (6), `Meter`, `DropZone`, `SendControl`, `SpectrumRenderer` labels.
- UI built in code, against the style guide: `DevicePanel._create_cc_tab` / `_create_container_folder`, `SendsPanel.SendControl`.
- ~~`BBT` math ignores the time-signature denominator.~~ Done: `GridHelper.beat_ticks`/`bar_ticks`/`bbt_of` are the single source; `ClipTextTime` delegates to them and the Editor copy is gone.
- ~~Consider re-enabling `unused_variable` / `unused_parameter` warnings.~~ Re-enabled in `project.godot`; prefix intentionally unused names with `_` as the warnings surface.

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