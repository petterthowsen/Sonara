# Settings: sub-categories, table layout, search, Assets category

Implementation plan for TODO.md › Settings (all four items).

## Checklist

- [x?] Phase 1: Registry API (sub-category, builder helpers, custom control scene)
- [x?] Phase 2: Dialog layout (sub-category headers, table rows)
- [x?] Phase 3: Fuzzy search with debounce
- [x?] Phase 4: Assets category and CLAP search paths (Godot + engine)

Do the phases in order. Run `Godot/tests/run_all.sh` after each Godot phase and `cargo test` (from `Engine/`) after Phase 4. Mark the TODO items `[x?]` when a phase is done, never `[x]`.

## What already exists (don't rebuild it)

Most of the "data-driven settings system" is already in place. Read these files fully before starting, plus `docs/subsystems/godot-config-system.md`:

| File | What it does now |
|---|---|
| `Godot/settings/Settings.gd` | Autoload registry. `Setting` inner class (key, label, type, default, category, description, min/max/step, options). `_register_all_settings()`, `get_value` / `set_value` (coerce, save, emit `setting_changed`), `_RENAMED_KEYS` migration, `get_categories()` (a hard-coded ordered list). |
| `Godot/settings/SettingRow.gd` + `.tscn` | One row: `NameLabel` (180 px) + `EditorContainer`. Builds the widget from `setting.type`. Writes live through `Settings.set_value`. Has its own copy of the `Type` enum, which must stay in the same order as `Settings.Type`. |
| `Godot/settings/SettingsDialog.gd` + `.tscn` | Native `Window`: category `Tree` on the left, `ScrollContainer/Content` VBox on the right, Defaults/Cancel/Apply/OK. Cancel restores a snapshot. One shared `FileDialog`. |
| `Godot/core/Utils.gd` | `Utils.fuzzy_match(query, target) -> float` (0..1) and `Utils.expand_path(path)` (handles `~`). |
| `Godot/data/DeviceRegistry.gd` | `scan_plugins()` sends `/plugin/scan` with no args. |
| `Engine/src/audio/devices/clap_host/discovery.rs` | `PluginScanner::new()` (hard-coded defaults `/usr/lib/clap`, `/usr/local/lib/clap`, `~/.clap`) and `PluginScanner::with_paths()`. |
| `Engine/src/osc/server.rs` (`["plugin", "scan"]`), `audio/commands.rs` (`AudioCommand::ScanPlugins`), `audio/command_worker.rs` (`scan_plugins`) | The scan pipeline. |

Current problems this plan fixes:
- Constraints are set by poking the registry after registration (`_settings["…"].min_val = …`). This is noisy and easy to get wrong.
- There is no sub-category, so all settings in a category form one flat list.
- The "Audio" and "Shortcuts" categories show empty pages.
- Asset settings live under "Behavior".
- CLAP scan paths can't be configured.

## Phase 1: Registry API

**`Godot/settings/Settings.gd`**

1. Add fields to `Setting`: `sub_category: String = ""` and `control_scene: String = ""` (a `res://` path to a `.tscn`).
2. Add chainable helpers on `Setting` that return `self`:
   - `range(min_v: float, max_v: float, step_v: float = 1.0) -> Setting`
   - `choices(opts: Array) -> Setting`
   - `sub(name: String) -> Setting`
   - `scene(path: String) -> Setting`
3. Make `_register(s)` return `s`. Rewrite `_register_all_settings()` to use the helpers and delete every `_settings["…"].min_val = …` line. Example:
   ```gdscript
   _register(Setting.new("midi/virtual_keyboard/transpose", "Transpose (semitones)", Type.INT, 0,
   		CATEGORY_BEHAVIOR, "Transpose the virtual keyboard up or down.")) \
   		.sub("Computer Keyboard").range(-24, 24, 1)
   ```
   Keep every key, default and description exactly as they are. Moving settings between categories happens in Phase 4.
4. Assign sub-categories to the existing settings:
   - Behavior: "Computer Keyboard" (the 3 `midi/virtual_keyboard/*`), "Arranger" (`record_arm_follows_active_track`, `markers/rename_on_create`). The asset settings stay unassigned until Phase 4.
   - Appearance: "Arranger" (both settings).
   - AI: "Connection" (api_key, base_url, model), "Chat" (temperature, max_tokens, max_tool_rounds, reasoning, reasoning_effort, user_instructions), "Audio" (voice, format), "Debug" (keep_exchanges).
5. Add `get_sub_categories(category: String) -> Array[String]`. It returns the distinct sub-categories in registration order, with `""` first if any setting has no sub-category. Godot 4 `Dictionary` keeps insertion order, and ordering relies on that.
6. Change `get_categories()` to leave out categories that have no registered settings. Today that hides "Audio" and "Shortcuts". Keep the constants and the order list. `get_shortcut_list()` has no UI yet, so leave it alone.

**Custom control scenes.** A setting with `control_scene` set gets that scene as its editor instead of the built-in widget. `setting.type` still drives `_coerce`. The scene's root script must provide:
```gdscript
signal value_edited(value)
func setup(setting, value) -> void    # called once after add_child
func set_value(value) -> void         # must not emit value_edited
func get_value()
```
In `SettingRow._refresh_ui()`, check `setting.control_scene` first. If it is set, instantiate the scene, add it to `EditorContainer`, call `setup`, connect `value_edited` to `_write_value`, and store it as `_editor_widget`. Route `get_current_value()` and `_apply_value_to_widget()` to it before the `match` blocks. If the scene fails to load, `push_error` and fall back to the built-in widget. No real setting uses a custom scene yet. Only the test below exercises it.

**Tests.** Create `Godot/tests/test_settings_registry.gd`, extending `TestBase` and modelled on `test_fuzzy_match.gd`:
- `range()`, `choices()`, `sub()` set the fields and return the same object.
- `get_sub_categories("AI")` returns `["Connection", "Chat", "Audio", "Debug"]` in that order.
- `get_categories()` does not contain "Audio" or "Shortcuts".
- `_coerce` still clamps (for example, transpose 99 → 24). Call `Settings._coerce(Settings.get_setting(key), 99)` directly. Don't call `set_value`, because it writes config.
- The `Type` enum sizes match: `Settings.Type.size() == SettingRow.Type.size()`, and the key names are the same.
- Custom scene: add `Godot/tests/fixtures/DummySettingControl.tscn`, check whether a `fixtures` dir already exists first, then instantiate `SettingRow` with a `Setting` that has `.scene(...)` and assert that `get_current_value()` comes from the scene. If `SettingRow` can't be instantiated headless without a tree, add it under `get_root()` like the other UI tests do (see `test_toggle_icon_button.gd`).

## Phase 2: Dialog layout

**Sub-category headers.** In `SettingsDialog._populate_rows(category)`, go through `get_sub_categories(category)`. For each non-empty sub-category, add a header `Label` before its rows. The header uses a larger font (`theme_override_font_sizes/font_size` about 1.4× the default; first check `Godot/assets` for a theme and a heading label variation, and use it if one exists), with a top margin (for example a `MarginContainer` with `margin_top` 18, and 0 for the first header) and a thin `HSeparator` under it. Settings with no sub-category render first, with no header. Track headers in a separate array so `_populate_rows` frees them along with the rows. Keep `_setting_rows` holding only `SettingRow`s, because `_flush_visible_rows` depends on that.

**Table rows.** Restructure `SettingRow.tscn`:
```
SettingRow (VBoxContainer, size_flags_horizontal = FILL|EXPAND)
├── Line (HBoxContainer, separation 16)
│   ├── LabelBox (VBoxContainer, size_flags_horizontal = EXPAND_FILL)
│   │   ├── NameLabel (Label)
│   │   └── HelpLabel (Label, dimmed modulate/font color, smaller font, autowrap WORD_SMART)
│   └── EditorContainer (HBoxContainer, alignment = END, custom_minimum_size.x = 260)
└── WideEditorContainer (MarginContainer, hidden by default)
```
- The editor sits in a fixed-width right column, so every control lines up on the right edge. BOOL, INT, FLOAT, CHOICE, CHOICE_MULTI, STRING, SECRET and PATH go in `EditorContainer`. STRING, SECRET and PATH fill the 260 px column.
- TEXT and PATH_ARRAY are too wide for the column. Put them in `WideEditorContainer` (shown, full width, under the label). For these, `EditorContainer` stays empty.
- `HelpLabel.text` is the description's first paragraph (split on `"\n\n"`). Hide the label when that is empty. Keep the full description as the `tooltip_text` of `NameLabel`.
- Update the `@onready` paths in `SettingRow.gd`. `SettingRow` changes from `HBoxContainer` to `VBoxContainer`, so update `class_name SettingRow extends …`.
- Add a small vertical gap between rows (`Content` separation 10) and a right margin inside the scroll area so controls don't touch the scrollbar (wrap `Content` in a `MarginContainer` with right 12 and update the node path in `SettingsDialog._ready`).
- Bump the default dialog size in `SettingsDialog.tscn` and `popup_centered_size` to 900×600.

Check the result in the running app (`godot --path Godot`, Edit › Preferences) at the minimum size (600×400) and at 900×600. Check that labels wrap instead of pushing controls off-screen, and that Cancel, Apply and Restore Defaults still behave the same.

## Phase 3: Search

**Scoring (pure, testable) in `Settings.gd`:**
```gdscript
## Settings matching *query*, best first. Empty query returns [].
func search(query: String) -> Array[Setting]
```
- Score each setting as `max(fuzzy(label), 0.9 * fuzzy(sub_category), 0.8 * fuzzy(category), 0.7 * fuzzy(description), 0.6 * fuzzy(key))` with `Utils.fuzzy_match`.
- Keep settings that score at or above a `SEARCH_MIN_SCORE` constant. Pick the value by trying real queries against `Utils.fuzzy_match` (for example "velo", "clap", "api key", "temp", and "zzz", which must return nothing). Check how `Godot/browser/AssetSearch.gd` or the browser picks its threshold and reuse that if it applies.
- Sort by score descending. Break ties by registration order, so the sort must be stable: sort an array of `[score, index, setting]`.

**UI in `SettingsDialog`:**
- Add a `SearchEdit` (`LineEdit`, placeholder "Search settings…", `clear_button_enabled = true`) as the first child of `MarginContainer/VBoxContainer`, above the `HSplitContainer`. Add a `SearchDebounce` `Timer` (`one_shot`, `wait_time = 0.15`).
- `text_changed` restarts the timer. `timeout` calls `_apply_search()`.
- `_apply_search()`:
  1. Call `_flush_visible_rows()` first, as `_on_tree_item_selected` does.
  2. If the query is empty (after `strip_edges`), rebuild the selected tree category and return.
  3. Otherwise `tree.deselect_all()` and rebuild `Content` from `Settings.search(q)`. Group the rows under headers of the form `"Category › Sub-category"` (or just `"Category"`), in the order each group first appears in the ranked list. Reuse the Phase 2 header builder.
  4. If there are no results, show one dimmed "No settings match "<q>"" label.
- Selecting a tree item while a search is active clears `SearchEdit` without triggering another search (stop the timer) and shows that category.
- Pressing Escape in `SearchEdit` clears it if it has text. Otherwise let the window handle it.
- Pressing Enter in `SearchEdit` gives focus to the first result's editor, if there is one.
- `_begin_session()` clears the search box, so every open starts clean.
- Refactor `_populate_rows(category)` into `_clear_content()` + `_build_rows(groups: Array)`, where each group is `{title: String, settings: Array}`. Category view and search view then share one code path. `_refresh_rows()` must re-run the active search if there is one. Otherwise Restore Defaults while searching would jump back to a category.
- Focus: when the dialog opens, focus goes to `SearchEdit`.

**Tests:** add to `test_settings_registry.gd`:
- `search("")` is empty.
- `search("velocity")` puts `midi/virtual_keyboard/velocity` first.
- `search("openrouter")` includes the AI connection settings.
- `search("qqqzzz")` is empty.
- Results are stable across two calls.

## Phase 4: Assets category and CLAP search paths

### Godot

**`Settings.gd`**
1. Add `const CATEGORY_ASSETS = "Assets"` and place it second in `get_categories()`: Audio, Assets, Behavior, Appearance, AI, Shortcuts.
2. Move the asset settings to `CATEGORY_ASSETS`. **Keep their keys** so no `_RENAMED_KEYS` migration is needed:
   - "Browser": `assets/scan_interval_seconds`, `assets/enabled_providers`
   - "Audio & MIDI": `assets/samples/paths`
   - "SFZ Instruments": `assets/sfz/paths`
   - "CLAP Plugins": new setting (below)
3. Register the new setting:
   ```gdscript
   _register(Setting.new("assets/clap/paths", "CLAP Plugin Search Paths", Type.PATH_ARRAY,
   		["~/.clap", "/usr/lib/clap", "/usr/local/lib/clap"], CATEGORY_ASSETS,
   		"Directories scanned for .clap plugins. Entries in the CLAP_PATH environment variable are also scanned.\n\n"
   		+ "Run Edit › Scan Plugins after changing this.")).sub("CLAP Plugins")
   ```
   These are the standard Linux locations from the CLAP spec, plus the common `/usr/local` prefix. They match the engine's current hard-coded defaults, so behavior doesn't change for existing users.

**`Godot/data/DeviceRegistry.gd` `scan_plugins()`:** build the args from `Settings.get_value("assets/clap/paths")`. For each entry, apply `Utils.expand_path`, `strip_edges`, skip empty entries and remove duplicates. Send them as string args: `AudioEngineOSC.send("/plugin/scan", paths)`. Update the header comment at the top of the file. Don't rescan automatically when the setting changes, because scanning loads native plugin code and is slow. The description tells the user to rescan.

Check whether anything else sends `/plugin/scan` or runs a scan at startup (`grep -rn "/plugin/scan\|scan_plugins" Godot --include=*.gd`). Every sender must go through `DeviceRegistry.scan_plugins()` so the paths are always included.

### Engine

OSC contract change: `/plugin/scan [path: string]*`. With no args, the engine uses its built-in defaults, so `oscsend localhost 7000 /plugin/scan` keeps working.

1. **`audio/commands.rs`:** `ScanPlugins` becomes `ScanPlugins { paths: Vec<PathBuf> }`. Update the `| AudioCommand::ScanPlugins` arm near line 2320 to `ScanPlugins { .. }`.
2. **`osc/server.rs`** (`["plugin", "scan"]`): collect every `OscType::String` arg into `Vec<PathBuf>`, ignore other arg types and log the count. Look at a neighbouring handler to see how args are read in this file.
3. **`clap_host/discovery.rs`:**
   - Add `pub fn set_paths(&mut self, paths: Vec<PathBuf>)`. An empty `paths` means `default_scan_paths()`.
   - Add a pure helper `fn resolve_scan_paths(configured: Vec<PathBuf>, clap_path_env: Option<&str>) -> Vec<PathBuf>`. It starts from `configured`, or the defaults if that is empty, appends the entries from `CLAP_PATH` (split with `std::env::split_paths`), and removes duplicates while keeping order. `set_paths` calls it with `std::env::var("CLAP_PATH").ok().as_deref()`. `new()` also goes through it, so `CLAP_PATH` is honoured when no args are given.
   - Add unit tests in a `mod tests` block: empty configured → defaults; configured replaces defaults; `CLAP_PATH` entries are appended; duplicates are removed and order is kept.
4. **`audio/command_worker.rs`:** `ScanPlugins { paths } => self.scan_plugins(paths)`. Call `self.plugin_scanner.set_paths(paths)` before `scan()`. Scanning already runs on the command thread without the state lock. Keep it that way.
5. Run `cargo fmt`, `cargo build --release` and `cargo test`.

**Docs:** AGENTS.md mentions `OSC_PROTOCOL.md` and `PLUGIN_OSC_PROTOCOL.md`, but neither file exists in the repo. Don't create them. Put the `/plugin/scan [path]*` contract in the doc comment on the server handler and in the `DeviceRegistry.gd` header, and tell the user that the files AGENTS.md refers to are missing.

**Manual check (ask the user to do this, it needs the running app):** add a custom dir containing a `.clap` file to the setting, run Edit › Scan Plugins, and confirm that `Engine/logs/last_info.log` shows `Scanning for CLAP plugins in [...]` with the configured paths and that the plugin appears in the browser.

## Out of scope (mention to user, don't implement)

- `scan_directory` in `discovery.rs` doesn't recurse. The CLAP spec says to search subdirectories, so `~/.clap/<vendor>/Foo.clap` is not found today. This is worth its own TODO item.
- There is no shortcut editor UI. The "Shortcuts" category is only hidden until one exists.
- Asset browser work that uses these paths (TODO › Asset Browser) is separate.

## Conventions reminder

- Tabs for indentation in GDScript. Match the `"""docstring"""` / `##` comment style already in each file.
- UI code never sends OSC directly. Only `DeviceRegistry` does.
- Consumers read preferences through `Settings.get_value`, never `Sonara.get_config`.
- Headless tests run with `godot --headless --path Godot -s tests/<file>.gd -- --test`.
