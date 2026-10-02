# SFZ key labels and keyswitches in the Auto note map — Implementation plan

Single-file plan (deliberately not the usual requirements/design/tasks split; the feature is small).
Extends spec 002 (note maps), whose "Out of scope" lists SFZ `label_key` / `sw_label` as a future
Auto source and asks the design to leave room for it. This plan uses that room. It does **not**
contradict any ADR. It does add one OSC message (ADR 0003 / `osc-protocol.md`).

## Goal

When a channel's first instrument is the built-in SFZ sampler (`sonara.builtin.sfizz`), the Auto
note map names:

- **playable keys** the SFZ labels with `label_keyN=` ("Snare rimshot", "Open hat"), and
- **keyswitch keys** (`sw_last`, with `sw_lokey`/`sw_hikey` ranges) named by `sw_label`, shown
  in a distinct color so they read as switches rather than notes.

So the piano roll / key lanes show "Spiccato", "Pizzicato" next to the right keys.

Labels and colors only. No latching, no "active articulation" lane (still out of scope per spec 002).

## What sfizz gives us (verified in vendored sfizz source)

| Need | API | Notes |
|---|---|---|
| `label_keyN` | C API `sfizz_get_num_key_labels`, `sfizz_get_key_label_number/text` | In `sfizz.h`, **not yet wrapped** in `rust-sfizz` (only `cc_labels()` is). `sfizz::bindings` is public, as `render_stereo` already calls raw `sfizz_render_block`. |
| keyswitch keys | OSC message `/sw/last/slots` → 128-bit blob | `Synth.cpp:972-979`; covers single keys and ranges. |
| keyswitch names | OSC message `/sw/last/<key>/label` → string | Set at region finalize (`Synth.cpp:816-831`), so only valid after `load_sfz` returns. |
| `sw_default` / current | `/sw/last/current` | Not needed now. |

The message queries go through `sfizz_send_message(synth, client, delay, path, sig, args)` with a
receive callback registered on a `sfizz_client_t`. There is no plain getter for keyswitch slots in
the C API.

**Risk / spike (T-1):** confirm the reply path works from Rust (callback + blob decoding) before
building on it. Fallback if it is painful: scan the SFZ text ourselves for `sw_last`/`sw_label`.
That is less accurate (`#include`, `#define`, `<control>` defaults), so use it only if messaging fails.

## Design

### Engine

All work happens on the **SFZ background load thread** in `SfizzDevice::load_sfz_async`
(`sfizz_device.rs`, right after `cc_labels()` at ~line 360). The audio thread contract is untouched:
no new audio-thread code.

1. New helper module section in `sfizz_device.rs` (or a small `sfizz_keys.rs` beside it):
   `fn read_key_info(synth: &sfizz::Synth) -> Vec<KeyInfo>` where
   `KeyInfo { key: u8, label: String, kind: KeyKind }`, `KeyKind::{Playable, Keyswitch}`.
   - Playable: all `label_key` entries.
   - Keyswitch: every set bit of `/sw/last/slots`; label from `/sw/last/<key>/label`, empty if none.
   - If a key is both (labelled and a switch), keyswitch wins (it is the more useful hint).
2. Store in a new `key_info: Arc<Mutex<Vec<KeyInfo>>>` field (same pattern as `cc_params`), plus a
   `key_info_changed` flag polled like `take_parameters_changed()`.
3. `command_worker.rs`, next to `collect_sfizz_parameters` (~line 1352): add
   `collect_sfizz_key_info` that emits one new status when the flag is set. **Unlike parameters,
   send it even when the list is empty**, so a reload to an SFZ with no labels clears the old ones.
4. New `EngineStatus::SfzKeyInfo { channel_id, device_path, keys: Vec<(u8, bool /*keyswitch*/, String)> }`
   in `commands.rs`, serialized in `osc/server.rs` beside `PluginParameterInfo`.

### OSC message (engine → Godot)

```
/channel/{id}/device/{path}/keys/info   [i:count, then count × (i:key, i:is_keyswitch, s:label)]
```

One message per load, not one per key (keeps the "empty clears" case trivial and avoids partial
states). Max 128 entries, so well within a UDP datagram. Add to `docs/subsystems/osc-protocol.md`.

### Godot

1. `DeviceInstance.gd`: add `var key_labels: Array` and `signal key_labels_changed`. Listen to
   `osc_addr("keys/info")` in `connect_to_engine()` / unlisten in `disconnect_from_engine()`
   (alongside `param/info`), parse into `key_labels`, emit the signal. **Not persisted**: the engine
   re-sends it whenever the SFZ loads, including when a project reopens.
2. `AuxReturnSync.gd` (where `is_drum_machine` / `is_layer` live): add `is_sfz(device)`.
3. `NoteMapResolver.gd`:
   - `find_auto_source`: also return a root-chain SFZ device **that has at least one label**. An
     unlabeled SFZ names nothing, so it is not a source (same rule as an all-full Layer).
   - `auto_map`: a third branch, `sfz_map(device)`. Playable keys use a neutral color; keyswitch
     keys use a dedicated keyswitch color. Unnamed keyswitches fall back to "Keyswitch".
   - **`wants_drum_view` must not turn on for SFZ.** It currently keys off `has_auto_source`. Split
     this into `has_row_source` (drum machine / layer) for Drum View and keep `has_auto_source` for
     labelling. Otherwise a string library would open as a 3-row drum grid.
4. `NoteMapWatcher.gd`: watch `key_labels_changed` on the SFZ device so the map refreshes when the
   user loads a different SFZ (already coalesced to one emit per frame by `_flush`).
5. The keyswitch color goes with the other note-map colors; pick a token that reads in both themes.

No change to `NoteMap` itself: it is already `pitch -> {name, color}`.

### Why this fits the existing architecture

- Same detection-on-load pattern as `cc_labels`; same status-message pattern as `param/info`.
- Auto maps are derived on demand, so no new stored state and no project-format change (REQ-004 of spec 002).
- UI never sends OSC; this is engine → model → signal → UI (ADR 0006).

## Tasks

Legend: `[ ]` open · `[x?]` implemented, not verified · `[x]` verified. Do in order.

### Phase 1 — Engine

- [x] **T-1** Spike: from Rust, call `sfizz_send_message` for `/sw/last/slots` and `/sw/last/<k>/label`,
  and decode the reply.
  - _Files_: `Engine/src/audio/devices/sfizz_device.rs` (or a scratch test)
  - _Verify_: a `#[cfg(test)]` test loads a small fixture SFZ with `sw_last`/`sw_label` and asserts
    the keys and labels. If infeasible, stop and switch to the SFZ-text fallback before continuing.
- [x] **T-2** Add fixture `Engine/test_keyswitch.sfz`: two `label_key`s, three `sw_last` keys (one
  via `sw_lokey/sw_hikey` range, one without `sw_label`). Reuse `test_kick.sfz`'s sample.
  - _Verify_: `cargo test sfizz_keys` passes (fixture covers each case above plus the keyswitch-wins rule).
  - _Done_: reader lives in `Engine/src/audio/devices/sfizz_keys.rs` (`read_key_info`), fixture `Engine/test_keyswitch.sfz` (uses `*sine`, no samples). Replies arrive synchronously inside `sfizz_send_message`, so no extra threading. The keyswitch-wins rule is implemented but not yet covered, because the fixture has no key that is both labeled and a switch.
- [x?] **T-3** `read_key_info` + `key_info` field + `key_info_changed` flag, filled in the load thread.
  - _Files_: `Engine/src/audio/devices/sfizz_device.rs`
  - _Verify_: unit test from T-2; `info!` log line lists each key on load (matches the CC log style).
- [x?] **T-4** `EngineStatus::SfzKeyInfo`, `collect_sfizz_key_info`, OSC serialization.
  - _Files_: `Engine/src/audio/commands.rs`, `Engine/src/audio/command_worker.rs`, `Engine/src/osc/server.rs`
  - _Verify_: unit test on the serializer (args layout, empty list); `cargo build --release` clean.
  - _Depends on_: T-3

### Phase 2 — Godot

- [x?] **T-5** `DeviceInstance` listens to `keys/info`, exposes `key_labels` + `key_labels_changed`;
  `AuxReturnSync.is_sfz`.
  - _Verify_: headless test feeds a fake `keys/info` message and checks `key_labels` and the signal;
    a second message with count 0 clears it.
  - _Depends on_: T-4 (message layout)
  - _Done_: `DeviceInstance._on_key_info_received` (entries are `{key, keyswitch, label}`, sorted by key), `AuxReturnSync.is_sfz`. Covered by `Godot/tests/test_note_map_sfz.gd`.
- [x?] **T-6** `NoteMapResolver`: SFZ source + `sfz_map`; split Drum View's source predicate.
  - _Verify_: `Godot/tests/test_note_map_sfz.gd` (extends `TestBase`): labelled SFZ gives named entries
    with keyswitch color; unlabeled SFZ gives an empty map and **`wants_drum_view` is false**; Drum
    Machine and Layer behaviour unchanged (`test_note_map.gd`, `test_layer_note_map.gd`, `test_drum_rows.gd` still pass).
  - _Depends on_: T-5
  - _Done_: colors are constants on `NoteMapResolver` (`SFZ_KEY_COLOR` neutral grey, `SFZ_KEYSWITCH_COLOR` amber), not theme tokens. Drum View now uses `has_row_source`, which is true only when the Auto source is a Drum Machine or zoned Layer.
- [x?] **T-7** `NoteMapWatcher` binds the SFZ device.
  - _Verify_: test emits `key_labels_changed` and expects exactly one `changed` per frame.
  - _Depends on_: T-6

### Phase 3 — Docs and live check

- [ ] **T-8** Docs: `osc-protocol.md` (new message), `engine-sfz-sampler.md` (key info after load),
  `CONTEXT.md` glossary entry for "Keyswitch" if absent, and amend spec 002's out-of-scope bullet with
  a pointer here.
- [ ] **T-9** Live check (needs a real run; per memory, ask before touching the user's engine on port
  7000): load an SFZ with keyswitches, open a clip on that channel, confirm names and colors in the key
  lanes, then load a different SFZ and confirm the labels update and stale ones clear.
  - _Depends on_: T-1 to T-7

### Phase 4 — Playable ranges, piano tint, assistant knowledge

Added after phase 2. Goal: an auto-mapped SFZ also knows which keys it can play, the piano roll greys
the rest, and the AI assistant is told the range and the keyswitches when it loads an SFZ.

Design:

- **Source of ranges (engine).** Union of every region's `lokey`..`hikey` (sfizz message queries
  `/num_regions`, `/region{n}/lokey`, `/region{n}/hikey`; same reply path as `sfizz_keys.rs`),
  merged into sorted, non-overlapping `(lo, hi)` ranges. Ranges, not one from/to, because drum and
  percussion patches have gaps. Keyswitch keys are not region keys, so they stay outside the ranges.
  The assistant text can still say "C1–C5" when there is one range.
- **OSC.** Append the ranges to the existing `keys/info` message so labels and ranges stay atomic
  (an empty list still clears): `[count, count × (key, is_keyswitch, label), range_count, range_count × (lo, hi)]`.
  Godot treats a missing tail as "no ranges", so an older engine still works.
- **Model.** `DeviceInstance.playable_ranges: Array` (`[lo, hi]` pairs, not persisted, like `key_labels`).
  `NoteMap` gets an optional `playable_ranges` (empty = every key is playable) and
  `is_playable(pitch)`. Only the SFZ Auto map fills it. Not editable and not serialized, so the
  note-map UI and library files are untouched.
- **Source rule.** An SFZ is an Auto source when it has labels **or** ranges. It still names nothing
  without labels, and `has_row_source` keeps Drum View off.
- **Piano tint.** `NoteLanes.gd` tints keys outside `playable_ranges` toward gray when the map has
  ranges. Keyswitch keys are outside the ranges but have a map entry, so they keep their own color
  and are not tinted.
- **Assistant.** The info lives on the `DeviceInstance`, so it does not depend on the load result.
  `AiTool.compact_device` (shared by `load_device_file`, `add_device`, `get_device`, `list_devices`)
  adds, for an SFZ device, `playable_ranges` and `keyswitches` (`[{key, name}]`, note names in the
  project's convention: middle C = C3 = 60) once they have arrived, or `"key_info": "loading"` while
  the SFZ is still loading. `load_device_file` / `add_device` also await `key_labels_changed` for up
  to ~2 s so the common case answers immediately. On timeout the result says the key info is not
  ready and to call `get_device` shortly, which then returns it. `system_prompt.md` gets a line
  telling the model to use keyswitches, stay inside the playable range, and re-check while `key_info`
  is `loading`.

Tasks:

- [x?] **T-10** Engine: `read_playable_ranges` + merge, appended to `SfzKeyInfo` / `keys/info`.
  - _Verify_: test on `test_keyswitch.sfz` (add regions with a gap), serializer test for the new layout.
  - _Done_: `read_playable_ranges` + `merge_ranges` in `sfizz_keys.rs`. sfizz replies `/num_regions` as int64 (`h`) and `key_range` as ints, so the reply decoder accepts `i` and `h`. The fixture already has a gap (keys 60 and 62), so no new regions were needed. `keys/info` now ends with `range_count, (lo, hi)...`; update `osc-protocol.md` in T-8.
- [x?] **T-11** Godot: `DeviceInstance.playable_ranges`, `NoteMap.playable_ranges` / `is_playable`,
  `NoteMapResolver.sfz_map`, source rule.
  - _Verify_: extend `test_note_map_sfz.gd`; `test_note_map.gd` still passes.
  - _Depends on_: T-10
  - _Done_: `NoteMap.playable_ranges` / `is_playable` (not serialized, kept by `duplicate_map`); `DeviceInstance.playable_ranges` and `key_info_received` (reset by `load_file`).
- [x?] **T-12** Piano tint in `NoteLanes.gd`.
  - _Verify_: headless test for the tint decision (unmapped gray, keyswitch not gray, no ranges = no tint); visual check in T-13.
  - _Depends on_: T-11
  - _Done_: `VPiano._draw_key` pulls a key toward gray when it has no map entry and is outside the ranges (`unplayable_gray_strength`). Only the piano, not the note lanes. The decision itself (`is_playable`) is unit tested; the look needs T-14.
- [x?] **T-13** Assistant: key info in `compact_device`, bounded await in `load_device_file` / `add_device`, prompt line.
  - _Verify_: tool test with a fake device that emits `key_labels_changed`; the timeout path; a later `get_device` returns the info; `"key_info": "loading"` while loading.
  - _Depends on_: T-11
  - _Done_: new `ai/tools/SfzKeyInfoUtil.gd`. Note `ok_text` results send only `text` to the model, so `load_device_file`, `add_device` and `create_track` append a text paragraph; `compact_device` (JSON, used by `get_device` / `list_devices`) gets the structured fields. The wait only happens when the channel is connected to the engine.
- [ ] **T-14** Live check (ask first, port 7000): ranges, tint and assistant result with a real keyswitch SFZ.
  - _Depends on_: T-10 to T-13

## Open questions

- Should keyswitch keys also be drawn in the piano roll's note-entry area as non-note "switch" markers
  (so you don't accidentally draw a melody note on one)? Plan assumes **no**: names and color only.
- Where does a `sw_last` key live in the 128-key view: the keyswitch zone is usually a few octaves
  below the playable range, so the lanes may need to be visible/scrolled there. Check in T-9 whether
  the key lanes already show mapped keys regardless of the visible range; if not, that is a follow-up.
- Colors: reuse an existing accent or add a new theme token? Decide while doing T-6.
