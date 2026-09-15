# AI tool results: compact text, better asset search, `list_assets`

Implementation plan for TODO.md › AI Assistant › "Investigate if tool results can be presented in a simpler way to assistant?"

## Checklist

- [x] Phase 1: Text result plumbing
- [x] Phase 2: Library-relative asset paths
- [x] Phase 3: `search_assets` word matching and totals
- [x] Phase 4: `list_assets` tool
- [x] Phase 5: One-line results for tools that change things
- [x] Phase 6: `create_track` shortcuts

## Why

In the conversation `~/Documents/Sonara/city_pop_1.aichat/conv_0357ab25b67a.json`, the user asked for "tracks with all the VPO section performance patches". It took 13 `search_assets` calls, 12 `create_track` calls, 12 `add_device` calls and 12 `route_channel` calls. The results were verbose JSON.

What went wrong:

| Call | Result | Cause |
|---|---|---|
| `search_assets "vpo performance"` | 0 hits | "vpo" appears only in the folder path. The path fallback in `AssetSearch.score` checks the *whole query* as one substring. "performance" doesn't match "PERF". |
| `search_assets "vpo"`, then `"SEC-PERF"` | 25 hits each | Results stop at the limit and the result doesn't say more exist, so the model searched once per instrument. |
| Every search row | ~125 chars | `{"favorite":false,"name":…,"path":"/home/peter/Music/libs/SFZ/VPO3/Strings/harp-KS-B7.sfz","tags":[],"type":"sfz"}` |
| `add_device` | ~290 chars | Repeats `loaded_file` (the model's own input), `category`, the empty `children`, `bypass:false` and `position`. |
| `create_track` / `route_channel` | ~180–275 chars | Return the whole nested channel. The model only needs the new ids. |

## Goals

1. Tools can return **plain text**. Rows are short lines, and keys that are empty or false are left out.
2. Asset paths the model sees are **relative to the library root** (`SFZ/VPO3/Strings/harp-KS-B7.sfz`). Tools also accept these paths as input.
3. `search_assets` matches **each query word separately**, including folder names, and reports `showing N of M`.
4. A new `list_assets` tool **browses folders** with pages.
5. Tools that change things return **one confirmation line** with the new ids and handles.
6. `create_track` can also add an instrument and set the output in the same call.

## Non-goals

- Converting every tool in one go. Phase 5 lists the remaining tools as follow-up work.
- Changing Browser search behavior. The Browser keeps using `AssetSearch.rank` exactly as it works today.
- Engine or OSC changes. This work is Godot-only.

## Conventions for text results

Every tool that moves to text follows these rules:

- The first line is a one-sentence summary, e.g. `12 SFZ assets match "vpo sec perf" (showing 12 of 12)`.
- Lists use one line per item, formatted as `- <handle>` followed by optional `, key: value` parts.
- Leave out keys that are false, empty, zero or the default. Write `favorite`, never `favorite: false`.
- Don't repeat what the model just sent, unless the tool changed or normalized it.
- IDs the model needs for later calls always appear, in a clearly labeled form: `(id 2108662093)`, `channel 2`.
- Errors are `Error: <message>`.
- Keep lines under about 160 characters. Leave out absolute paths, colors and anything the model can't act on.

---

## Phase 1: Text result plumbing

### 1.1 `AiTool` ([Godot/ai/tools/AiTool.gd](../Godot/ai/tools/AiTool.gd))

- Add `static func ok_text(text: String, data: Dictionary = {}) -> Dictionary`. It returns `{"ok": true, "text": text, "data": data}`. `data` is optional structured output for tests and the UI. It is never sent to the model when `text` is present.
- Add `static func to_model_content(result: Dictionary) -> String`:
  - If `ok == false`, return `"Error: " + error`.
  - Otherwise, if `text` is present, return `text`.
  - Otherwise return `JSON.stringify(result)`. Tools that haven't been converted keep working unchanged.

### 1.2 `Assistant` ([Godot/ai/Assistant.gd:259](../Godot/ai/Assistant.gd#L259))

Replace `JSON.stringify(result)` with `AiTool.to_model_content(result)`.

### 1.3 Transcript UI

- In [ChatTranscript.gd:91](../Godot/ai/ui/ChatTranscript.gd#L91), `add_tool_result` stringifies the dict. Change it to use `AiTool.to_model_content(result)` so the live view and the reloaded view (lines 42–47, which show `msg.content`) look the same.
- Check `CollapsibleBlock` and `ChatTextFormat.json_to_bbcode`:
  - `pretty_json` already returns non-JSON text unchanged.
  - Make sure `_highlight_json` doesn't mangle plain text.
  - Make sure `[`, which is BBCode, is escaped. If plain text isn't handled well, add a branch: when `JSON.parse_string(body) == null`, render it as an escaped `[code]` block with no highlighting.

### 1.4 Tests

Add `Godot/ai/tests/test_tool_results.gd`, extending `TestBase` like `test_device_tools.gd` does. It covers `to_model_content` for fail, ok_text and legacy dict results.

---

## Phase 2: Library-relative asset paths

### 2.1 New helper `Godot/browser/AssetPaths.gd` (`class_name AssetPaths`, static only)

Keep the logic pure (roots are passed in) so tests can run headless. `AssetService` skips providers in test mode.

```gdscript
## Root dirs as `[{abs: String, label: String}]`. Label = last folder name, with " 2", " 3"... for duplicates.
static func build_roots(abs_dirs: Array) -> Array[Dictionary]
## "/home/peter/Music/libs/SFZ/VPO3/Strings/x.sfz" → "SFZ/VPO3/Strings/x.sfz". Longest matching root wins. Returns abs path if no root matches.
static func to_relative(abs_path: String, roots: Array) -> String
## Inverse. Accepts an absolute path unchanged. Returns "" if the label is unknown.
static func to_absolute(path: String, roots: Array) -> String
```

Details:
- Expand each root with `Utils.expand_path` and remove any trailing `/`.
- Remove duplicate dirs: the same dir can appear in both `assets/sfz/paths` and `assets/samples/paths`.
- Matching needs a `/` boundary: `/a/SFZ` must not match `/a/SFZ2/x.sfz`.
- Device assets (`Asset.TYPE.Device`) use the `device_id` as their path. Pass those through unchanged in both directions.

### 2.2 `AssetService` ([Godot/browser/AssetService.gd](../Godot/browser/AssetService.gd))

- Cache the roots: `var _roots: Array[Dictionary]`. Build them from `Settings.get_value("assets/samples/paths") + Settings.get_value("assets/sfz/paths")` in `_initialize_providers`. Rebuild them in `_on_setting_changed` (line ~410) when either key changes.
- `func get_roots() -> Array[Dictionary]`
- `func relative_path(asset: Asset) -> String`
- `func resolve_asset(path: String) -> Asset`. It tries `find_asset(path)` first, then `find_asset(AssetPaths.to_absolute(path, _roots))`. Leave `find_asset` as is, since the Browser and other code use it with absolute paths.

### 2.3 Accept relative paths in tools

Replace `AssetService.find_asset(...)` with `AssetService.resolve_asset(...)` in:
- `AddDeviceTool._resolve_asset` ([AddDeviceTool.gd](../Godot/ai/tools/AddDeviceTool.gd))
- `LoadDeviceFileTool` (line ~37)
- Any other tool that takes `asset_path`. Find them with `grep -rn find_asset Godot/ai`.

### 2.4 Tests

Add these to `test_tool_results.gd`, or to a new `Godot/tests/test_asset_paths.gd`:
- Round trip.
- Longest root wins when one root is nested inside another.
- Duplicate labels get numbered.
- A `/` boundary is required.
- Device ids pass through.
- Absolute input passes through.

---

## Phase 3: `search_assets` word matching and totals

### 3.1 Matching (`AssetSearch`, AI-only path)

Add `static func rank_tokens(assets: Array, query: String, rel_path_of: Callable) -> Array[Dictionary]`. It returns `{asset, score}`, best first. **Do not change `score` or `rank`**, since the Browser uses them.

Algorithm:
1. Lowercase the query and split it on whitespace. Drop empty words. Keep hyphens inside a word ("SEC-PERF" stays one word). An empty query matches everything with score 1.
2. For each asset, build:
   - `name` = the display name, lowercased.
   - `rel` = `rel_path_of.call(asset)`, lowercased, with the extension removed.
   - `tags`, lowercased.
   - `words` = `name`, `rel` and `tags` split on `/ - _ . space`.
3. Score each query word `t` with the **best** of:
   - `1.0`: `t` equals a word from the name
   - `0.9`: a word from the name starts with `t`, or `t` equals a tag
   - `0.8`: `t` is a substring of `name`
   - `0.7`: `t` equals a path folder, or a substring of `rel`
   - `0.6`: prefix rule. Some word `w` in `words` with `w.length() >= 3` satisfies `t.begins_with(w)` ("performance" → "perf"), **or** `w.begins_with(t)` with `t.length() >= 3`.
   - `0.5 * Utils.fuzzy_match(t, w)` for the best `w` in `words`, only if `fuzzy_match > 0.7` (typos).
   - otherwise `0`
4. **Every word must score above 0**, or the asset is out.
5. Asset score = the average of the word scores. Add `+0.05` if the asset is a favorite.
6. Sort by score (descending), then `last_used` (descending), then name (ascending). This matches the existing tie-break in `AssetService.search_assets`.

Expected results. Write each as a test with fake `Asset`s:
- `"vpo sec perf"` matches `SFZ/VPO3/Strings/1st-violin-SEC-PERF.sfz` and `SFZ/VPO3/Brass/trumpet-SEC-PERF-staccato.sfz`. It does not match `SFZ/VPO3/Strings/harp-KS-B7.sfz`.
- `"vpo performance"` matches the same SEC-PERF files, through the prefix rule.
- `"strings"` matches everything under `…/Strings/`.
- `"violin sec perf"` ranks `1st-violin-SEC-PERF` above `1st-violin-SEC-PERF-KS-C2`. The name words match equally, so a shorter name needs to win: add `-0.01 * extra name words` beyond the query word count, or break ties by name length. Pick one and test it.
- `"trumpt"` (typo) still finds trumpet files through the fuzzy step.

### 3.2 `AssetService.search_assets`

Change the signature to `search_assets(query, type_filter = "", limit = 25, offset = 0) -> Dictionary`, returning `{"assets": Array[Asset], "total": int}`. It uses `rank_tokens` with `relative_path`. `SearchAssetsTool` is the only caller (checked with grep). Clamp `limit` to 1–100.

### 3.3 `SearchAssetsTool` ([SearchAssetsTool.gd](../Godot/ai/tools/SearchAssetsTool.gd))

- Add an `offset` parameter. Update the description: "Every word must match the name, a tag, or a folder in the path. Use list_assets to browse folders."
- Return `ok_text` in this format:

```
12 of 61 sfz assets match "vpo sec perf" (offset 0). Pass offset 12 for more.
- SFZ/VPO3/Strings/1st-violin-SEC-PERF.sfz
- SFZ/VPO3/Strings/2nd-violin-SEC-PERF.sfz, favorite
- Samples/Drums/kick_01.wav, tags: kick, acoustic
- Delay (device: sonara.builtin.delay, effect)
```

Line rules:
- Files: the relative path. Add `, favorite` when it's a favorite and `, tags: a, b` when there are tags. The extension already shows the type, so `type` is left out.
- Devices: `display name (device: <device_id>, <category lowercase>)`. `add_device` accepts `device_id`.
- Drop the "Pass offset…" sentence when everything is shown.
- With no results: `No assets match "…". Try fewer words or list_assets.`

Also pass `data = {"total": total, "paths": [...]}` for tests and the UI.

---

## Phase 4: `list_assets` tool

New file `Godot/ai/tools/ListAssetsTool.gd`. Register it in `ToolRegistry.create_default` next to `SearchAssetsTool`.

Parameters:
- `path` (string, optional): a library-relative folder. Empty means list the roots.
- `type` (enum `audio|midi|sfz`, optional): count and list only this type.
- `page` (integer, default 1): 30 files per page. Folders always appear in full on every page.

Build the list from `AssetService`'s asset index, not from `DirAccess`. The listing then shows exactly what search can find, and it doesn't touch the filesystem. For the folder `F`, look at every asset whose relative path starts with `F/`:
- If the rest contains `/`, record the first segment as a subfolder and increase its file count.
- Otherwise it's a file directly in `F`.

Output:

```
SFZ/VPO3/: 4 folders, 0 files
- Brass/ (38)
- Percussion/ (22)
- Strings/ (61)
- Woodwinds/ (44)
```

```
SFZ/VPO3/Strings/: 0 folders, 61 files (page 1/3, 30 per page)
- 1st-violin-SEC-PERF.sfz
- 1st-violin-SEC-PERF-KS-C2.sfz
…
```

- Files are listed by **name only**. The folder is in the header, so the full path = header + name. Add `, favorite` and `, tags: …` the same way as search.
- Sort folders and files alphabetically, ignoring case.
- With no path, list each root as `- <label>/ (<count>)`.
- If the path is unknown: `Error: No folder "X". Roots: SFZ/, Samples/`.
- If the page is past the end: `Error: page N out of range (1–M)`.

Put the folder and page logic in a static helper, e.g. `static func build_listing(rel_paths: Array, folder: String, page: int, per_page: int) -> Dictionary` on `AssetPaths` or the tool. Test it headless with plain strings.

Update [system_prompt.md](../Godot/ai/prompt/system_prompt.md). Add a short "Assets" section:
- Paths are library-relative.
- Use `list_assets` to browse a library, and `search_assets` (all words must match) to find specific items.
- Pass the path exactly as shown to `add_device`.

Change the drum pad line to say that too.

---

## Phase 5: One-line results for tools that change things

Convert these to `ok_text`. Keep `data` filled with the existing `compact_*` dict so tests and the UI can still inspect it.

| Tool | Text |
|---|---|
| `add_device` (single) | `Added Sfizz SFZ Sampler to 1st Violins → path "1st Violins/Sfizz SFZ Sampler" (id 2108662093)`. Add `, pad note 36` for drum pads. |
| `add_device` (several) | Header `Added 4 pads to Drums/Drum Machine:`, then `- Kick (note 36, id …)` per pad. |
| `create_track` | `Created instrument track "1st Violins" (track 0, channel 2)`. For folders or tracks without a channel, leave out the channel part. |
| `create_bus` | `Created bus "Strings" (channel 14)` |
| `route_channel` | `Routed 1st Violins (2) → Strings (14)`. Use `Master` for 1, `no output` for 0, `hardware out N` for ≥1000. |
| `remove_device`, `move_device`, `rename_*`, `set_track_color`, `set_mixer`, `add_send`, `delete_track`, `place_clip`, `load_device_file`, `set_device` | One line saying what changed, with the ids of any new objects. Read each file and write the natural sentence. For `set_mixer`, list only the fields that changed: `Strings: volume -3 dB, pan 0.2`. For `load_device_file`, the loaded file is the input, so don't repeat it; say `Loaded into Cellos/Sfizz SFZ Sampler`. |

Also, in `compact_device` ([AiTool.gd](../Godot/ai/tools/AiTool.gd)), used by `list_devices` and `get_device`, which stay JSON for now:
- Leave out `loaded_file` when empty, and otherwise show it as a relative path.
- Leave out `children` when empty and `bypass` when false.
- Update the `ListDevicesTool` description to match.

Out of scope, but note as a TODO at the end: the read tools `list_project`, `list_tracks`, `list_channels`, `list_devices`, `get_device` and `list_clips` could move to text the same way. Measure first, since `list_project` is probably the biggest.

---

## Phase 6: `create_track` shortcuts

Add optional parameters to [CreateTrackTool.gd](../Godot/ai/tools/CreateTrackTool.gd):
- `asset_path` / `device_id` (instrument tracks only): after `TrackCreateCommand`, run the same code `AddDeviceTool` uses. Move `AddDeviceTool._resolve_asset` and `_add_one` into a shared static helper (e.g. `DeviceToolUtil`) instead of creating an `AddDeviceTool` inside this tool.
- `output_channel_id`: after creating the track, route its channel, the same way `RouteChannelTool` does.

Undo: put the whole call in one history step. Check how `HistoryUtil` and `hist.begin_macro` work in `Assistant.gd`, since a whole assistant turn is already one macro. If the per-turn macro already covers undo, nothing extra is needed.

Result: `Created instrument track "Cellos" (track 3, channel 5) with Sfizz SFZ Sampler (id 1338329375), output → Strings (14)`

If adding the device or routing fails after the track exists, keep the track and add a second line: `Warning: device not added: <error>`.

Update the tool description and system_prompt.md: "Prefer one `create_track` call with `asset_path` and `output_channel_id` over separate calls."

---

## Verification

1. `Godot/tests/run_all.sh`: all suites pass, including the new ones.
2. Manual test (ask the user, since it needs the engine and the real SFZ library). In a fresh chat, repeat the city_pop_1 request: "orchestral template with all VPO section performance patches, buses Strings/Winds/Brass". Expected:
   - 3 or fewer asset calls.
   - Around 12–15 total calls instead of about 50.
   - Tool results in the saved conversation JSON are plain text lines.
3. Open an old conversation that has JSON tool results. It should still render.

## Task checklist

- [x] P1: `ok_text`, `to_model_content`, Assistant and transcript wiring, tests
- [x] P2: `AssetPaths`, `AssetService` roots and `resolve_asset`, tools accept relative paths, tests
- [x] P3: `rank_tokens`, `search_assets` with total and offset, text output, tests
- [x] P4: `ListAssetsTool`, listing helper, registry, system prompt, tests
- [x] P5: one-line results for tools that change things, trimmed `compact_device`
- [x] P6: `create_track` with `asset_path` and `output_channel_id`, shared add-device helper
- [ ] Mark the TODO.md item `[x?]` when done

## Gotchas

- The working tree has many uncommitted changes on `dev`. Don't revert unrelated files.
- In test mode (`-- --test`), `AssetService._ready` returns early, so no providers and no roots. Keep all logic that needs testing in static helpers that take their inputs as arguments.
- Tool args arrive as floats from JSON (`channel_id: 2.0`). Keep using `int(args.get(...))`.
- Match the existing GDScript style: `##` doc comment on every function, typed vars, tabs.
