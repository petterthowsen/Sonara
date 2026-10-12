# Spec 037: Browser folder split, info panel and sample preview

Simple implementation plan. Three parts, done in order; each part ends in a working state.

## Goals

1. **List mode becomes a folder/contents split.** A `VSplitContainer` holds two `Tree`s: the top one shows folders only, the bottom one shows the selected folder's contents as a flat list.
2. **Info panel at the bottom of the Browser** for the selected item: filename, type, file size, and (for audio) sample rate, channels and duration. For audio it also shows the waveform, a play/stop button and a playhead you can click or drag to seek.
3. **Audition toggle** in the Options bar, shown on the Samples tab only. While it is on, selecting an audio file plays it right away.

Out of scope: MIDI file preview, SFZ preview, preview through a track's instrument, tempo-synced preview.

## Decisions

- **Preview plays in the engine, not in Godot.** Godot's own audio output may open a different device, and it skips the engine's output config. The engine gets a small preview player whose output is added to the master **hardware** output after the master channel (no fader, no master FX), with a fixed preview gain (−6 dB). This touches the audio thread, so it must follow the audio thread contract in AGENTS.md.
- **Decoding reuses AudioFileService** (`/audiofile/decode`). The preview player only ever gets finished PCM at the project rate.
- **Waveform reuses `WaveformRegistry` / `WaveformView`** (`Godot/support/waveform/`) through the peak file from `/audiofile/waveform/ready`. Sample rate and channels come from the peak header (`WaveformData.source_sample_rate`, `channels`). The duration comes from `/audiofile/decode/ready`.
- The old `ItemList` flat mode is **replaced** by the split for every tab. The `TREE_VIEW` mode stays as it is.
  - Samples, SFZ, Presets: the folder tree is the directory structure under the scan roots. It reuses the path logic in `_build_asset_tree` / `_strip_search_path_prefix`, folder items only. Audio and MIDI stay separate top-level roots, as in the tree view.
  - Devices: the "folders" are the existing category hierarchy from `_build_device_hierarchy_tree`.
  - The top tree has a root item "All" that lists everything (recursive) in the bottom tree.
  - **While the search box has text**, the bottom tree shows every search match (ranked, as `_populate_samples_tab` does now), whatever folder is selected. The folder tree stays usable.
  - The selected folder and the split offset per tab are persisted under `ui/browser` (`_save_ui_state` / `_load_ui_state`).

## Part 1: Folder/contents split (Godot only)

Files: `Godot/browser/Browser.gd`, `Godot/browser/Browser.tscn`.

1. In `_setup_ui`, replace `_create_item_list` with a `_create_split(asset_type)` that builds a `VSplitContainer` with `folder_tree` (one column, `hide_root` off) and `content_tree` (`hide_root = true`, columns as in the current tree for that tab). Store them in `_splits`, `_folder_trees`, `_content_trees`. Remove `_item_lists`.
2. Folder population: build folder items from the filtered assets' directories. Each folder item's metadata is the absolute folder path; for Devices it is the category path. Restore expansion with the existing `_expanded_folders` helpers, keyed separately (for example a `"<type>/folders"` key).
3. Contents population: the assets whose folder is the selected folder (direct children only, plus subfolders listed first as folder rows that navigate on double-click). Under "All" or with a search, list every match. Rows carry `Asset` metadata exactly like the current tree rows, so drag (`_get_drag_data_tree`), the context menu and `asset_selected` keep working. Generalise those handlers to take the `Tree` instead of looking it up through `_trees[_current_tab]`.
4. Keep the lazy `_dirty_tabs` rebuild. Rebuilding a tab must keep the selected folder and the selected content row (by path) when they still exist.
5. Preset rows keep the unavailable grey-out and tooltip (`_decorate_preset_items`).
6. Update `docs/subsystems/godot-asset-system.md` (Browser section).

Tests: extend or add `Godot/tests/test_browser_split.gd` (extends `TestBase`). Cover these cases: selecting a folder lists only its direct assets; "All" lists everything; a search overrides the folder; the folder selection survives a rebuild; drag data from the content tree is the same as from the tree view. Make sure the existing `test_browser_*` and `test_preset_browser` still pass (`Godot/tests/run_all.sh browser preset`).

## Part 2: Engine preview player

Files: new `Engine/src/audio/preview.rs` (or `audio/mixing/preview.rs`), `audio/state.rs`, `audio/commands/` (new `preview.rs`), `osc/routes/` (new `preview.rs`), `osc/encode.rs`, the command worker, `docs/subsystems/osc-protocol.md`.

OSC (Godot → Rust):

| Address | Args | Meaning |
|---|---|---|
| `/preview/play` | `s:abs_path, f:start_s` | Decode (via AudioFileService) if needed, then play from `start_s`. Replaces any current preview |
| `/preview/stop` | — | Stop (3 ms fade) |
| `/preview/seek` | `f:pos_s` | Jump while playing or stopped. A stopped player keeps the position for the next play |

OSC (Rust → Godot):

| Address | Args | Meaning |
|---|---|---|
| `/preview/status` | `s:abs_path, i:state, f:pos_s, f:duration_s` | `state`: 0 stopped, 1 loading, 2 playing, 3 failed. Sent on every state change and at the ~20 Hz status rate while playing. A finished play sends one `stopped` with `pos_s = duration_s` |

Engine design:

- `PreviewPlayer` in `EngineState`: `Option<PreviewBuffer>` (interleaved f32 at the device rate, channels, frames), `pos_frames`, `state`, a 3 ms fade ramp for start/stop/seek, and a req_id/generation for stale-request checks.
- The command thread handles `/preview/play`: it sends an AFS decode with a fresh req_id and sets state Loading. When the decode for the **current** req_id finishes, it swaps the PCM in under the lock and sets state Playing. A stale req_id result is dropped (AGENTS.md: stale `req_id` completions must be ignored). The old buffer goes into `CommandEffects` and is dropped after the lock. Keep only one preview buffer.
- Audio thread: after the master output pass in `mix_and_output` (or right after it in the callback), add the preview to the hardware output buffer. Mono goes to both sides, stereo L/R, more than 2 channels → first two. Apply the fade and the gain. No allocation, no locks beyond the existing state lock. Advance `pos_frames`; at the end set Stopped.
- The preview plays even while the transport is stopped and while rendering is **off**. Mute it while `state.rendering` is set.
- Unit tests in the module (`mod tests`): plays the buffer into the output with gain; mono → stereo; seek moves the position; reaching the end stops; a stale decode result is ignored; output is unchanged when nothing is loaded.

Read first: `docs/subsystems/engine-audio-thread.md`, `engine-architecture.md`, and how `/audiofile/decode` + `load_device_sample` (`audio/commands/sampler.rs`) hand PCM over.

## Part 3: Info panel, waveform preview and audition toggle (Godot)

Files: new `Godot/browser/BrowserInfoPanel.gd` + `.tscn`, new `Godot/browser/PreviewPlayer.gd` (plain object owned by the Browser, or a small node), `Browser.gd/.tscn`.

1. **PreviewPlayer.gd**: wraps the OSC (`AudioEngineOSC`, following the existing listener pattern; UI code must not send OSC directly, so this class is the model). API: `play(path, start_s = 0)`, `stop()`, `seek(pos_s)`, `toggle(path)`. Signals: `state_changed(path, state)`, `position_changed(pos_s, duration_s)`. Between `/preview/status` messages, interpolate the position locally so the playhead moves smoothly.
2. **BrowserInfoPanel** (a `PanelContainer` at the bottom of the Browser VBox, under `Content`; collapsible and hidden when nothing is selected):
   - Line 1: filename (bold) and file type (extension / Asset type).
   - Line 2: file size (`Asset.file_size_bytes`, human readable), and for audio: sample rate, channels, duration. For presets: device name and author. For devices: vendor and category.
   - Audio only: a `WaveformView` (about 48 px high) with a playhead line overlay, plus a play/stop button. A click or drag on the waveform seeks (`seek` while playing; while stopped it plays from that point). The waveform comes from `/audiofile/waveform/start` → `/audiofile/waveform/ready` → `WaveformRegistry.get_or_load(peak_path)`. Check how `AudioClipInspector.gd` and the sampler's `SampleDisplay` set up a `WaveformView` and copy that.
3. The Browser connects `asset_selected` → `info_panel.show_asset(asset)`.
4. **Audition toggle**: a toggle `Button` (headphones/speaker icon from `res://assets/icons/` if one exists, else the text "Aud") in `Options`, visible only on the Samples tab. Persist it in `ui/browser`. While it is on, selecting an audio row calls `preview.play(path)`. Selecting a non-audio row or a folder, switching tabs, or turning the toggle off calls `stop()`.
5. Space bar while the content tree has focus toggles preview of the selected audio file (optional, only if it doesn't clash with `Hotkeys` transport bindings; if it clashes, skip it).
6. Update `docs/subsystems/godot-asset-system.md`.

Tests: `Godot/tests/test_browser_info_panel.gd`. Cover these cases: panel fields for an audio asset, a preset and a device; with audition on, selecting an audio row calls play (stub the PreviewPlayer); toggle off → stop; a seek click maps x → seconds correctly.

## Verification

- `cd Engine && cargo build --release && cargo test preview` plus the full `cargo test`.
- `Godot/tests/run_all.sh`.
- Manual (user): run the engine and the app, browse samples, check that the split works, the panel info is right, play/seek works, and audition plays on select.
