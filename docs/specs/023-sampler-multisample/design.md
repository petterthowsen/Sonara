# Sampler Multisample — Design

Implements [requirements.md](./requirements.md).

## Context

Engine:

- `Engine/src/audio/devices/sampler.rs`: `SamplerDevice` holds one `sample: Option<SampleBuffer>`,
  device-wide `Params` (from the `param_table` `SPECS`) and one cached `Regions` from
  `resolve_regions()`. Voices are a fixed `[Voice; MAX_VOICES]` (64).
  - `note_on()` allocates one voice. `note_off()` releases the oldest held voice for the note
    (`find_held_voice_for_note`).
  - `render_active_voices()` takes a `RenderCtx` with *the* sample, regions, loop mode and root.
  - `playheads_payload()` normalizes positions over *the* sample.
- `Engine/src/osc/server.rs`:
  - `handle_device_message()` matches device sub-addresses (`["load_file"]`, `["slot", n, …]`, …).
  - `begin_device_sample_load()` records a `PendingDevice { channel_id, device_path, source_path }`
    by `req_id` and submits the decode to the AudioFileService (AFS).
  - `handle_afs_event()` turns `AfsEvent::DecodeReady` / `Error` into
    `AudioCommand::LoadDeviceSample` / `FailDeviceSampleLoad`.
  - `EngineStatus::DeviceLoadingStateChanged` becomes `{device}/loading_state` (around line 2031).
- `Engine/src/audio/commands.rs`:
  - `BeginLoadDeviceSample`, `LoadDeviceSample` and `FailDeviceSampleLoad` downcast to
    `SamplerDevice` and call `begin_sample_load` / `set_sample` / `fail_sample_load`.
  - `AuditionLayerSlot` goes through the `with_layer` helper.
  - `process_command` runs under the state lock (`CommandWorker::apply_locked`).
- `Engine/src/audio/devices/sfizz_keys.rs`: the precedent for a pure helper module sitting next
  to its device.

Godot:

- `Godot/data/DeviceInstance.gd`:
  - `load_file()` registers the `req_id` with `Project.track_device_request()` and fills
    `sample_source: AudioSourceInfo`.
  - `_watch_waveform()` retries a missing waveform.
  - `to_json()` / `from_json()` persist `loaded_file_path` and `parameter_values`.
  - `sync_to_engine()` sends the params. `audition_slot()` is the audition precedent.
- `Godot/data/Project.gd`: `_waveform_for_req()` maps `/audiofile/decode/ready` and
  `/audiofile/waveform/ready` to a clip's or device's `AudioSourceInfo`.
- `Godot/data/Channel.gd`: `_sync_device_tree_to_engine()` calls `sync_to_engine()`, then
  `load_file()`.
- `Godot/data/DevicePreset.gd`: presets are `DeviceInstance.to_json()`, so anything in `to_json()`
  is in presets.
- `Godot/devices/builtin/SamplerDefaultView.gd`: builds a `SampleDisplay` plus control groups
  bound by parameter name (`_knobs`, `_segments`, `_checks`, `POINT_PARAMS`). It commits undo with
  `PropertyCommand` + `HistoryUtil.record`.
- `Godot/devices/builtin/sampler/SampleDisplay.gd`: a waveform with handles and playheads, with no
  knowledge of `DeviceInstance` (spec 021, 2.1).
- `Godot/devices/DeviceViewFactory.gd`: `BUILTIN_WINDOW_SCENES` / `BUILTIN_COMPANION_SCENES`.
  `devices/frame/DeviceFrame.gd` creates Window views, and `devices/device_lane/DevicePanel.gd`
  creates Companion views.
- `Godot/devices/DeviceDropUtil.gd`: `can_drop_on_device()` / `drop_on_device()` accept a single
  `Asset`. `Browser._get_drag_data()` hands over an `Array[Asset]` for multi-selections.
- `Godot/history/`: `PropertyCommand` (callable, mergeable) and `HistoryUtil.record()` /
  `execute_many()`.
- `Godot/components/VPiano.gd`: a vertical-only keyboard that takes velocity from the horizontal
  position.
- `PopupMenu.theme_type_variation = &"ContextMenuList"` is the context-menu style
  (`EqCurveEditor._build_menus`).
- ADRs:
  - 0002 (audio thread contract), 0006 (self-synchronizing models), 0008 (device sleep):
    followed.
  - 0005 (normalized parameters): zones are **not** parameters (see Approach), so their OSC
    arguments use real units. This doesn't contradict 0005, which governs parameters. A new ADR
    records the choice (T-030).

## Approach

**One playback path, two zone sources.** `SamplerDevice` gets a `Zone` type that carries
everything a voice needs: PCM, resolved `Regions`, loop mode, reverse, root, tune, gain, key
tracking, and in multisample mode also ranges, fades and group. Single-sample mode keeps one
implicit zone, `single`, whose fields are rebuilt from the device params whenever a relevant
param changes. Today's single-sample behaviour then comes through the same render code
unchanged, and existing tests keep passing. Multisample mode uses `zones: Vec<Zone>`. Each voice
stores a zone index (`SINGLE_ZONE` for the implicit one), and `RenderCtx` loses its per-sample
fields and reads them from the voice's zone. Zone matching, fades, round robin and group mute/solo
live in a new pure module, `sampler_zones.rs`, which can be unit-tested without audio.

**Zones are device state, not parameters.** Godot owns the zone model, `SamplerMultisample` on
`DeviceInstance`. It sends whole-zone and whole-group snapshots over OSC
(`zone/{zid}/set`, `zone_group/{gid}/set`), which makes syncing idempotent: `sync_to_engine()`
just re-sends everything. Zone and group ids are small ints that Godot allocates per device and
persists. Each zone's file loads through the existing AFS path with a `zone_id` attached, so
waveforms reach Godot over the existing `/audiofile/*` replies, routed by `req_id` to the zone's
own `AudioSourceInfo`.

**Undo by snapshot.** Every multisample edit records one `PropertyCommand` whose old and new
values are `SamplerMultisample.snapshot()` dictionaries, applied by `restore()`. `restore()`
diffs by zone id and sends only what changed: a set for changed zones, remove for gone ones, and
load plus set for new or re-pathed ones. A drag snapshots at drag start and records once at the
end. Knob edits on the focused zone record mergeable single-zone snapshots.

**Rejected alternatives:**

- *sfizz backend* (decided in requirements): every edit would need a full SFZ reload, and the
  playheads and modulators would be lost.
- *Per-zone settings as dynamic parameters*: the parameter list would change size as zones are
  added. Automation lanes and modulation routes would point at ids that disappear, and
  `/builtin/info` metadata is static. Not worth it for settings the requirements say aren't
  automatable.
- *A separate "Multisampler" device*: REQ-011/012/013 want one device that switches modes, so
  presets, drops and chains don't have to swap devices.
- *An orientation option on `VPiano`*: it is tied into `LaneLayout`, note maps and the clip
  editor, and its velocity axis runs across the key. The zone map draws its own horizontal key
  strip (about 80 lines) with the velocity-by-height rule from REQ-043.

## Thread and ownership

| State | Owner thread | Reached from | Real-time safe |
|---|---|---|---|
| `SamplerDevice.zones: Vec<Zone>` (settings + `Option<SampleBuffer>`) | command thread writes under the state lock (`zone/*` commands, `LoadDeviceSample` with a zone id) | audio callback reads under its bounded `try_lock` (note-on, render) | yes. `Vec::reserve(MAX_ZONES)` runs on the command thread when multisample mode turns on, so the audio thread never grows it |
| `SamplerDevice.single: Zone` | command thread (param `apply`, `set_sample`) | audio callback | yes, the same struct as today's fields |
| `SamplerDevice.groups: Vec<ZoneGroup>` (gain, mute, solo, play mode, `rr_next`, `last_zone`), `any_solo` cache | command thread under the lock. `rr_next` / `last_zone` are written by the audio callback at note-on | audio callback | yes. Reserved to `MAX_GROUPS` (64) with the zones |
| `match_scratch: Vec<u16>` (zone indices matching a note-on) | audio callback | — | yes. Allocated once with capacity `MAX_ZONES` (512) when multisample mode turns on, then only `clear()` / `push()` within capacity |
| `rng: u32` (xorshift for Random) | audio callback | — | yes |
| `Voice.zone: u16`, `Voice.trigger: u64` | audio callback | — | yes. `Voice` stays `Copy` |
| `focused_zone: u32` (for playheads) | command thread under the lock | audio callback in `playheads_payload` | yes |
| Zone PCM being replaced or removed | built on an AFS worker and moved in via the command | freed on the **command thread** under the lock, as `set_sample` does today | not on the audio thread. One `free()` per buffer under the lock, the same cost as today |
| `PendingDevice.zone_id: Option<u32>` | main thread (`server.rs`) | — | n/a |
| Godot `SamplerMultisample` and zones' `AudioSourceInfo` | Godot main thread | views via signals | n/a |

Removing a zone kills its voices first, then `swap_remove`s it. Voices that pointed at the moved
last index are remapped. All of that is O(voices), done under the lock.

Note-on in multisample mode does one pass over the zones that pushes matching indices into
`match_scratch` (O(zones), no allocation, at most 512 range checks). For each distinct group
among the matches it then applies All, Round robin or Random, and allocates voices with
`allocate_voice()`.

## Data and protocol changes

### OSC (Godot → engine), all under `/channel/{id}/device/{path}/`

| Address | Args | Meaning |
|---|---|---|
| `multisample` | `i:0_or_1` | Switch mode. Kills voices. `1` reserves the zone and group capacity. `0` clears the zones and groups |
| `zone/{zid}/set` | `i:key_lo i:key_hi i:vel_lo i:vel_hi i:root f:tune_semitones f:gain_linear f:start f:end i:reverse i:loop_mode f:loop_start f:loop_end f:crossfade i:key_fade_lo i:key_fade_hi i:vel_fade_lo i:vel_fade_hi i:group_id` | Create or replace zone `zid`'s settings. Points are 0–1 over the file as in single mode. `crossfade` is a fraction of the loop, 0–1 (the Crossfade parameter's % / 100). `tune_semitones` = tune + fine/100. `group_id` 0 = Ungrouped. Ranges are clamped and ordered by the engine. Ignored unless in multisample mode |
| `zone/{zid}/load_file` | `s:path s:req_id` | Load the zone's sample through AFS (as `load_file`, with the zone id) |
| `zone/{zid}/remove` | — | Remove the zone and its voices |
| `zone_group/{gid}/set` | `f:gain_linear i:mute i:solo i:play_mode` | Create or replace a group. `play_mode` 0 = All, 1 = Round robin, 2 = Random. `gid` 0 = Ungrouped (always exists) |
| `zone_group/{gid}/remove` | — | Remove a group. Its zones fall back to group 0 (Godot re-sends them too) |
| `focus_zone` | `i:zid` | Which zone's voices the `"playheads"` stream reports |
| `audition` | `i:note i:velocity i:on` | Play a note into this device directly (zone map piano). Queued like `send_note_event` at frame 0 and marks activity |

### OSC (engine → Godot)

| Address | Args | Meaning |
|---|---|---|
| `{device}/zone/{zid}/loading_state` | `s:state` | `loading`, `ready` or `failed:{reason}`, per zone. Re-sent for every zone by `state/get` |

`/audiofile/decode/ready` and `/audiofile/waveform/ready` are unchanged. They are keyed by `req_id`.

### Engine types

- `AudioCommand`: `SetSamplerMode`, `SetSamplerZone`, `RemoveSamplerZone`, `SetSamplerZoneGroup`,
  `RemoveSamplerZoneGroup`, `SetSamplerFocus` and `AuditionDevice`, applied through a new
  `with_sampler(state, channel_id, &path, |s| …)` helper like `with_layer`. `AuditionDevice`
  works on any device: it sends the note through `send_note_event` at frame 0, as
  `AuditionLayerSlot` does for a slot, so the Sampler needs no `audition` method.
  `BeginLoadDeviceSample`, `LoadDeviceSample` and `FailDeviceSampleLoad` gain
  `zone_id: Option<u32>`.
- `EngineStatus::SamplerZoneLoadingState { channel_id, device_path, zone_id, state }`.
- `"playheads"` payload: unchanged format. In multisample mode it lists only voices whose
  zone is `focused_zone`, normalized over that zone's frames.

### Godot model

- `SamplerMultisample` (RefCounted), on `DeviceInstance.multisample` (null until a Sampler first
  needs it):
  - Data: `active: bool`, `zones: Array[SamplerZone]`, `groups: Array[SamplerZoneGroup]`,
    `focused_zone_id`, `next_zone_id`, `next_group_id`.
  - Signals: `mode_changed`, `zones_changed` (add/remove), `zone_changed(zid)`,
    `groups_changed`, `focus_changed(zid)`.
  - Setters: `set_zone_fields(zid, dict)`, `add_files(paths, at_key)`, `remove_zones(ids)`,
    `set_focus(zid)`, `add_group(name)`, `rename_group`, `remove_group`, `set_group_fields`,
    `move_to_group(ids, gid)`.
  - Undo and sync: `snapshot()` / `restore()`, and `sync_to_engine()`.
  - Each setter updates state, sends OSC through the owning `DeviceInstance.osc_addr()` and
    emits a signal (ADR 0006).
- `SamplerZone` (RefCounted):
  - Data: `id`, `path`, `name` (file basename without extension, renamable later), ranges,
    per-zone settings, `group_id`.
  - Load state: `source: AudioSourceInfo`, `loading_state`.
  - Persisted by `to_json()` / `from_json()`.
- `SamplerZoneGroup` (RefCounted): `id`, `name`, `gain`, `mute`, `solo`, `play_mode`. JSON is a
  keyed object, so spec 024 can add `"output"` without a format break.
- `DeviceInstance`:
  - `to_json()` writes `"multisample": multisample.to_json()` when `multisample != null` and it
    is active or has zones. `from_json()` restores it.
  - `sync_to_engine()` calls `multisample.sync_to_engine()` after the params: mode, groups,
    zones (`set`, then `load_file`), focus.
  - `load_file()` on a Sampler in multisample mode delegates to `multisample.add_files()`, so
    the AI `LoadDeviceFileTool` and presets behave.
  - New `audition(note, velocity, on)`.
  - A `zone/{zid}/loading_state` handler routes to the zone. It is registered where
    `_on_loading_state_received` is.
- `Project`: `track_source_request(source: AudioSourceInfo, req_id)` plus a lookup that
  `_waveform_for_req()` checks after clips and devices.

### Persisted format (`.sonara`, presets)

```json
"multisample": {
  "active": true, "focused_zone": 3, "next_zone_id": 5, "next_group_id": 2,
  "groups": [{"id": 1, "name": "Soft", "gain": 1.0, "mute": false, "solo": false, "play_mode": 1}],
  "ungrouped": {"gain": 1.0, "mute": false, "solo": false, "play_mode": 0},
  "zones": [{"id": 3, "path": "/abs/Piano_C3.wav", "name": "Piano_C3", "group": 1,
             "key": [0, 62], "vel": [1, 127], "root": 60, "tune": 0.0, "fine": 0.0, "gain": 1.0,
             "start": 0.0, "end": 1.0, "reverse": false, "loop_mode": 0,
             "loop_start": 0.0, "loop_end": 1.0, "crossfade": 0.0,
             "key_fade": [0, 0], "vel_fade": [0, 0]}]
}
```

A missing `"multisample"` key means single-sample mode. `loaded_file_path` stays the single-mode
file and is cleared when converting to multisample (restored by undo).

## File-by-file change list

### Engine

| File | Change |
|---|---|
| `Engine/src/audio/devices/sampler_zones.rs` (new) | Pure helpers and types: `ZoneRanges` (key, velocity, fades); `fade_gain(x, lo, hi, fade_in, fade_out)` (equal-power, REQ-030); `ZoneGroup` (gain, mute, solo, `PlayMode { All, RoundRobin, Random }`, `rr_next`, `last_zone`); `select_zones(zones, groups, any_solo, note, vel, rng, out: &mut Vec<u16>)` doing match + mute/solo + All/RR/Random without allocating; `velocity_to_midi(f32) -> u8`. Unit tests |
| `Engine/src/audio/devices/mod.rs` | `pub mod sampler_zones;` |
| `Engine/src/audio/devices/sampler.rs` | Add `Zone` (settings + `Option<SampleBuffer>` + `Regions` + `req_id` + `group` + `key_track`). Replace `sample`/`regions` with `single: Zone`, rebuilt by `refresh_single_zone()` from `Params` in `apply()` and `set_sample()`. Add `zones`, `groups`, `any_solo`, `match_scratch`, `rng`, `multisample`, `focused_zone`. `Voice` gains `zone: u16`, `trigger: u64`. `note_on()` branches: single → today's logic on `single`; multi → `select_zones` → one voice per match with gain = volume × vel amount × zone gain × group gain × fades. `note_off()` releases every held voice of the note with the oldest `trigger`. `RenderCtx`/`render_active_voices`/`read_voice` take the zone per voice (sample, regions, loop mode, root for filter key tracking). `refresh_pitch` and `increment_for` are per zone. `playheads_payload` filters by `focused_zone`. New pub methods: `set_multisample`, `set_zone`, `remove_zone`, `set_zone_group`, `remove_zone_group`, `set_focus`, `begin_zone_load`, `set_zone_sample`, `fail_zone_load`, `resend_zone_states`. Module doc updated. Tests (see Test plan) |
| `Engine/src/audio/commands.rs` | New `AudioCommand` variants and `with_sampler` helper. `zone_id: Option<u32>` on the three sample-load commands, routed to `set_sample` / `set_zone_sample` etc. `EngineStatus::SamplerZoneLoadingState`. The `state/get` handling re-sends zone states |
| `Engine/src/osc/server.rs` | `handle_device_message` arms for every address in the table above. `PendingDevice.zone_id`. `begin_device_sample_load` takes `zone_id: Option<u32>`. `handle_afs_event` forwards it. Status → `{device}/zone/{zid}/loading_state` |
| `Engine/src/audio/devices/drum_machine.rs` | No change expected (`set_sample` keeps its signature). Compile check only |

### Godot: model

| File | Change |
|---|---|
| `Godot/data/SamplerMultisample.gd` (new) | The model above |
| `Godot/data/SamplerZone.gd` (new) | Zone data, JSON, OSC arg packing (`to_osc_args()`), per-zone load with waveform retry (same constants as `DeviceInstance._watch_waveform`) |
| `Godot/data/SamplerZoneGroup.gd` (new) | Group data and JSON |
| `Godot/data/DeviceInstance.gd` | `multisample` var, JSON, `sync_to_engine()` hook, `load_file()` delegation, `audition()`, zone loading-state routing |
| `Godot/data/Project.gd` | `track_source_request()` and lookup in `_waveform_for_req()` |

### Godot: logic

| File | Change |
|---|---|
| `Godot/devices/builtin/sampler/ZoneLayout.gd` (new) | Static, pure. `parse_root(file_name) -> int` (REQ-020 forms; −1 if none). `layout(new_zones, existing_roots, at_key)` (halfway ranges, consecutive fallback, mixed). `assign_velocity`, `assign_note`, `distribute_velocity(zones, lo, hi, stretch)`, `distribute_notes(...)` returning new ranges per zone id. `set_root_from_name` |
| `Godot/devices/builtin/sampler/SamplerActions.gd` (new) | One undo step each: `drop_files(inst, paths, at_key)` (REQ-011/012/015), `convert_to_multisample(inst)` (REQ-013, copies params into the zone), `convert_to_single(inst)` (REQ-014, writes params from the focused zone), `apply_batch(inst, op, ids, opts)`, `delete_zones`, `move_to_group`. Uses `HistoryUtil.execute_many` with param `PropertyCommand`s and a snapshot command |
| `Godot/devices/DeviceDropUtil.gd` | `can_drop_on_device` / `drop_on_device` accept an `Array` of audio `Asset`s for a Sampler and route to `SamplerActions.drop_files` (a single asset in multisample mode also adds a zone) |

### Godot: views

| File | Change |
|---|---|
| `Godot/devices/builtin/sampler/SampleDisplay.gd` | `title` property (zone name label, top-left, clipped, emits `title_clicked` when clicked). Optional placeholder action button (`placeholder_action` text, `placeholder_action_pressed` signal) for "Create Multisample". `_can_drop_data`/`_drop_data` for `Asset` or `Array` of audio assets, emitting `assets_dropped(assets)`. Still knows nothing about `DeviceInstance` |
| `Godot/devices/builtin/SamplerDefaultView.gd` | `@export var show_display := true` (false = Companion). In multisample mode: the display shows the focused zone's source, title and points; `ZONE_FIELDS` retargets Root/Tune/Fine/Reverse/Loop Mode/Crossfade and the display points to the focused zone through `SamplerMultisample.set_zone_fields`, with a mergeable zone-snapshot undo; those groups get a "Sample" badge in the zone accent color; Key Track stays visible and drives zones. Companion + multisample: a `ZoneStrip` replaces the display. Listens to `mode_changed`, `focus_changed`, `zone_changed`. Handles `assets_dropped` and the placeholder action. Context menu on the display: "Convert to Multisample" / "Convert to Single Sample" |
| `Godot/devices/builtin/SamplerCompanionView.tscn` (new) | Root with `SamplerDefaultView.gd`, `show_display = false` |
| `Godot/devices/builtin/SamplerWindowView.gd` / `.tscn` (new) | `DeviceView`: `MultisampleEditor` (hidden in single mode) above a `SampleDisplay` bound like the Panel's (shared helper below). Playheads subscription in `_on_view_shown` / `_on_view_hidden` |
| `Godot/devices/builtin/sampler/SampleDisplayBinder.gd` (new) | Moved out of `SamplerDefaultView`: source binding, `_update_waveform`, playhead subscription, point-drag commits (param or focused zone). Used by the Panel and Window views so they behave the same (REQ-003) |
| `Godot/devices/builtin/sampler/MultisampleEditor.gd` (new) | `ZoneGroupBar` on top, `HSplitContainer` [`ZoneList` \| `ZoneMap`]. Owns view-local `selected_ids` and the visible-group set, and forwards focus to the model |
| `Godot/devices/builtin/sampler/ZoneGroupBar.gd` (new) | All / Ungrouped / group toggle buttons (click = only, Ctrl-click = add/remove), each with M/S toggles. Right-click menu: Rename, Delete, Play mode (submenu), Gain… "+" adds a group |
| `Godot/devices/builtin/sampler/ZoneList.gd` (new) | Search `LineEdit` + `ItemList` (`SELECT_MULTI` gives Ctrl/Shift for free). Right-click → `ZoneBatchMenu`. Delete / Ctrl+A. Missing zones are shown dimmed with the reason as a tooltip |
| `Godot/devices/builtin/sampler/ZoneMap.gd` (new) | Draws the velocity × key grid, zone rects (group-tinted, selected and focused colors, missing hatch), labels rotated −90° when taller than wide and clipped, and the horizontal key strip. Hit testing: edges (±4 px, resize cursors) → body. Click cycles among overlapping zones at the same point; right-click lists the zones under the pointer plus `ZoneBatchMenu`. Drags move or resize the selection in whole keys and velocity steps, clamped. Key strip click → `device.audition(note, vel_from_height)` and release on mouse-up. Drop target for files (key under pointer). Pure helpers `zones_at(pos)`, `edge_at(pos)` and `drag_result(...)` for tests |
| `Godot/devices/builtin/sampler/ZoneBatchMenu.gd` (new) | Builds the shared batch `PopupMenu` (`theme_type_variation = &"ContextMenuList"`) and opens `ZoneBatchDialog` for assign and distribute |
| `Godot/devices/builtin/sampler/ZoneBatchDialog.gd` (new) | `PopupPanel` (`PrimaryPanel` variation): range lo/hi spin boxes (note names for keys), a "single value" toggle, a Stretch/Gaps option for distribute, and Apply |
| `Godot/devices/builtin/sampler/ZoneStrip.gd` (new) | Focused zone's name, group dropdown, key range, velocity range, gain, key fades and velocity fades as compact spin boxes and knobs |
| `Godot/devices/DeviceViewFactory.gd` | Register `sonara.builtin.sampler` in `BUILTIN_WINDOW_SCENES` and `BUILTIN_COMPANION_SCENES` |

### Docs

| File | Change |
|---|---|
| `docs/subsystems/osc-protocol.md` | Every address above, the zone `loading_state`, the Sampler section (modes, zone selection, playheads in multisample mode) |
| `docs/subsystems/godot-device-views.md` | Sampler section: Window/Companion views, multisample editor, `SampleDisplayBinder` |
| `docs/adr/0017-sampler-zones-are-device-state.md` (new) | Zones are device state sent as real-unit snapshots, not parameters. Not automatable. Relation to 0005 and 0011 |
| `CONTEXT.md` | Glossary: Multisample mode, Zone, Zone group, Focused zone |
| `AGENTS.md` | Built-in devices line: Sampler multisample (one clause) |
| `TODO.md` | Backlog entry pointing at this spec |

## Migration and compatibility

- Projects and presets without `"multisample"` load in single-sample mode. Single-mode param IDs,
  mappings and `loaded_file_path` are unchanged.
- A project saved with zones and opened by an older build loses the zones (the key is ignored)
  and loads as an empty single-sample Sampler. That's acceptable for a dev build, and noted in
  TODO.
- An engine without these messages ignores unknown device addresses (logs a warning). No
  handshake change.
- DAWproject export: in multisample mode `loaded_file_path` is empty, so the Sampler exports with
  no file. That's out of scope (requirements), and the transfer report gets one line saying
  multisample zones weren't exported.

## Test plan

- **Unit (engine), `cargo test sampler`:**
  - `sampler_zones`:
    - `fade_gain_edges` (REQ-030 example ≈ 0.707; 0 at the edges; 1 outside the fades)
    - `select_matches_key_and_velocity` (REQ-016)
    - `mute_and_solo_filter` (REQ-031)
    - `round_robin_cycles` (1, 2, 3, 1)
    - `random_never_repeats_and_covers_all` (100 hits, REQ-032)
    - `select_does_not_allocate` (capacity unchanged after 1000 note-ons)
  - `sampler.rs`:
    - `single_mode_unchanged_through_zone_path` (existing tests stay green, plus a render
      comparison against a fixture)
    - `multisample_plays_matching_zone_only`
    - `zone_key_track_follows_device_param` (REQ-018)
    - `device_tune_ignored_in_multisample` (REQ-017)
    - `note_off_releases_all_stacked_voices`
    - `voices_cap_counts_zone_voices` (REQ-019)
    - `remove_zone_remaps_voices`
    - `stale_zone_load_ignored`
    - `playheads_only_focused_zone` (REQ-024)
    - `mode_switch_kills_voices`
- **Unit (OSC parse):** `cargo test zone_osc`: `zone/{zid}/set` with 19 args → `SetSamplerZone`
  with clamped, ordered ranges. Short argument lists are rejected with a warning.
- **Godot (`Godot/tests/`, run via `Godot/tests/run_all.sh sampler`):**
  - `test_sampler_zone_layout.gd`: `parse_root` cases (`Piano_C3`, `C#3`, `Db3`, `c-1`, `pad-060`,
    `kick` → −1); REQ-020 example ranges; fallback and mixed layouts; every batch op including
    uneven splits, more zones than steps, Stretch vs Gaps (REQ-047 example).
  - `test_sampler_multisample.gd`:
    - model setters emit signals
    - JSON round-trip (REQ-027), including a preset and an old project without the key
    - `snapshot`/`restore` diff (only changed zones re-sent; OSC captured via a test transport)
    - REQ-012 keeps the old sample
    - REQ-013 / REQ-014 conversions copy values both ways
    - one undo per drop, batch op and convert
    - `load_file` delegation in multisample mode
    - zone `loading_state` "failed" marks the zone missing (REQ-028)
  - `test_sampler_zone_map.gd`:
    - `zones_at` / `edge_at` hit testing
    - click cycling through three stacked zones (REQ-046)
    - move and resize clamping and never-empty ranges (REQ-045)
    - label rotation decision (REQ-044)
    - key strip velocity from height (REQ-043)
    - list search filter and shared selection (REQ-042)
    - group filter click vs Ctrl-click (REQ-041)
  - `test_sampler_view.gd` (extend): Window view and Companion view are created by the factory;
    Companion has every Panel control and no display (REQ-002); the Window view's display drag
    updates the Companion knob (REQ-003); the editor is hidden in single mode (REQ-040);
    placeholder button converts (REQ-010); per-zone knobs follow focus (REQ-022); the zone strip
    shows in Companion + multisample (REQ-023).
  - Existing `test_device_drop.gd`, `test_device_presets.gd`, `test_waveform_view.gd` still pass.
    `test_device_drop.gd` gains an `Array[Asset]` → multisample case.
- **Live** (engine + Godot):
  - Drop 3 named piano samples on a Sampler, play across the keyboard, and check the roots and
    ranges.
  - Stack two velocity layers and play soft and hard.
  - Round-robin group: repeated hits alternate.
  - Solo and mute groups.
  - Open the window: drag zones while holding notes (no clicks or dropouts), check playheads
    on the focused zone only, save and reopen.
  - Rename a file on disk, reopen, and check the zone shows missing.

## Risks

| Risk | Mitigation |
|---|---|
| Restructuring `RenderCtx` to per-voice zones changes single-mode sound | The single-mode render-comparison test against today's output before the refactor (T-003 records the fixture first) |
| Note-on cost with 256+ zones and stacked RR groups | O(zones) pass with scratch, no allocation; a `#[test]` timing guard on 512 zones × 64 note-ons; live check for dropout warnings in `Engine/logs/last_warn.log` |
| RAM with many zones (all PCM in memory) | Documented limit (requirements). The log prints total zone PCM MB after each zone load so the cost is visible |
| Large UDP burst on project load (19-arg zone messages × N + loads) | Same burst problem as waveforms. The zone waveform retry handles missed replies, and `zone/*/set` is idempotent and re-sent on reconnect. A 256-zone sync is about 30 KB, under the 64 KB Godot receive queue noted in `CommandWorker::scan_plugins` |
| Modulation assigned to Root/Tune/Start does nothing in multisample mode | `ModAssign` stays attached (single mode needs it). The "Sample" badge and tooltip say these controls edit the focused sample. Noted in the ADR |
| Snapshot undo on a 512-zone Sampler copies a big Dictionary per edit | Snapshots are plain data (around 512 × 20 fields); the drag records once. Knob edits use single-zone snapshots |

## Open questions

Resolved (2026-10-06):

- [x] **Changing focus without the window:** accepted and added to REQ-021. `SampleDisplay`
  emits `title_clicked`. `SamplerDefaultView` opens a `ContextMenuList` `PopupMenu` of zones
  sorted by root key and calls `SamplerMultisample.set_focus`.
