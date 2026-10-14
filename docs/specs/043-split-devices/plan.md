# Mid/Side Split and L/R Split — Implementation Plan

Two built-in audio effects that split the signal into two device slots (spec 040), run each slot,
and sum the results. Both share one engine implementation.

## Devices

| | Mid/Side Split | L/R Split |
|---|---|---|
| ID | `sonara.builtin.ms_split` | `sonara.builtin.lr_split` |
| Name | "Mid/Side Split" | "L/R Split" |
| Slot 0 (`SlotKind::Audio`) | `mid` "Mid" | `left` "Left" |
| Slot 1 (`SlotKind::Audio`) | `side` "Side" | `right` "Right" |
| Slot 0 input | `(M, M)` with `M = (L+R)/2` | `(L, 0)` |
| Slot 1 input | `(S, −S)` with `S = (L−R)/2` | `(0, R)` |
| Output | `level_0 · slot0_out + level_1 · slot1_out` | same |

The output is a plain sum of the two slot outputs (as in Bitwig). With empty slots and unity
levels this reconstructs the input exactly: `M + S = L`, `M − S = R`, and `(L, 0) + (0, R) = (L, R)`.
A stereo effect in a slot may spread into the other side; that's intended. Users who want a slot
processed as mono put a Utility (Mono) first in it.

## Parameters

| ID | Name | Group | Range | Default |
|---|---|---|---|---|
| 0 | `{A} Gain` | `{A}` | `linear(-60, 24)` dB, −60 = silence (as Utility) | 0 |
| 1 | `{A} Solo` | `{A}` | `Kind::Bool` | off |
| 2 | `{B} Gain` | `{B}` | same as 0 | 0 |
| 3 | `{B} Solo` | `{B}` | `Kind::Bool` | off |

`{A}`/`{B}` are the slot names ("Mid"/"Side", "Left"/"Right"), so each device has its own
`SPECS` table.

Solo works like Multiband's (`multiband.rs` `update_levels`): when any slot is soloed, a slot
that isn't soloed targets level 0, otherwise its level is its gain. Each slot's level is a
`SmoothedParam` with a 10 ms ramp. A slot that is soloed out **keeps running its chain**, so tails
and compressor state don't jump when it's unsoloed.

## Engine

### 1. `Engine/src/audio/devices/effects/split.rs`

- `enum SplitMode { MidSide, LeftRight }` and one `SplitDevice` holding the mode, `ParamValues`,
  the two smoothed levels, gain/solo state, a `DeviceSlots`, two stereo interleaved scratch
  buffers (`buf_a`, `buf_b`, `max_frames * 2` each), the latency alignment delays (step 5) and a
  `TailSleep`.
- Two `&'static [SlotSpec]` tables (`MS_SLOTS`, `LR_SLOTS`) and two constructors
  (`SplitDevice::mid_side(sr, max_frames)`, `SplitDevice::left_right(sr, max_frames)`).
- `AudioDevice` impl: `device_slots()`, `as_slots()` / `as_slots_mut()` and the
  `DeviceContainer` children exactly as in `delay.rs` (`device_slots` around line 780). Slots are
  fixed: `insert_child` refuses, `remove_child` / `move_child` do nothing (handled by
  `DeviceSlots`).
- `prepare`: grow `buf_a` / `buf_b` and call `self.slots.prepare`.
- `reset`: reset the levels, alignment delays and `self.slots.reset()`.

### 2. `process_block`

Per block, check `self.slots.is_live(0)` and `is_live(1)` once.

1. **Pass-through path:** neither slot is live, both levels are steady at 1.0 and nothing is
   soloed → copy input to output. This keeps empty slots sample-identical (M/S round-trips through
   floats otherwise differ by an ulp).
2. **Plain path:** neither slot is live → compute the two split signals per frame and sum them
   with the smoothed levels. No chain calls.
3. **Slot path:** fill `buf_a` / `buf_b` with the split signals, run each live slot's chain in
   place (`self.slots.chain_mut(i).process_block`), align latency (step 5), then sum
   `level_0 · buf_a + level_1 · buf_b` into the output.

The audio-thread rules apply: no allocation, everything preallocated in `new` / `prepare`.
Blocks longer than the scratch are processed in chunks, as Reverb Wet FX does.

### 3. Async devices in a slot (VST3)

Both slots are `SlotKind::Audio`, so they accept async-block devices. Follow Reverb Wet FX
(`reverb.rs` `has_async_blocks` / `begin_block` / `finish_block`, around line 1414):

- `has_async_blocks()` is true while either slot is live and holds an async device
  (`self.slots.has_async(i)`).
- `begin_block` runs the whole block (split, both slots, sum) into scratch and returns true.
  `finish_block` copies it out.

### 4. Sleep

The device has no tail of its own. It stays awake while either slot chain is awake, for example
because a delay or reverb in a slot is still ringing. Delegate `update_sleep_state` to the slot
chains and sleep only when both report sleeping. Check how `reverb.rs` handles the Wet FX tail
(test `sleep_waits_for_wet_fx_tail`) and mirror it.

### 5. Latency (spec 042 part D)

If one slot reports latency (a lookahead compressor, say), the two halves no longer line up and
the sum comb-filters. Follow Multiband (`multiband.rs` `latency_frames` / `update_latency`,
around line 559):

- `latency_frames()` is the max of the two live slots' latencies.
- `update_latency` updates both chains and sets an alignment delay of `max − own` on each
  slot's output.
- The pass-through and plain paths must delay by the same latency (Multiband's `thru`), so
  toggling a slot's bypass doesn't jump in time.

### 6. Registration

- `effects/mod.rs`: `pub mod split;`
- `factory.rs`: add both IDs to `EFFECT_IDS` and both arms to `create_effect`.
  `effect_conformance.rs` then covers them automatically.

## Godot

No code is expected. `/builtin/info` already carries the slot block, and Godot builds the slot
keys, drop rules, lane brackets and Simple View slot tiles from it (`data/DeviceSlots.gd`).
Verify in the running app:

- Both devices appear in the browser under audio effects.
- The Simple View shows Gain/Solo for each slot and the "Slots" tile column.
- Dropping an effect onto a slot tile or bracket inserts it into that slot. Dropping an
  instrument or note effect is refused.
- Save and reload a project with devices in both slots: the slots are restored.

A custom panel view (the two slot tiles side by side, each with its gain knob and solo button)
is optional and comes last (see `DeviceViewFactory.gd` for registration).

## Tests

Engine (`mod tests` in `split.rs`):

- Slot keys, names and kinds for both devices.
- Empty slots: output equals input sample for sample, both modes.
- M/S: solo Side on a mono input (`L == R`) gives silence. Solo Mid on `(1, −1)` gives silence.
- L/R: solo Left gives `(L, 0)`. Solo Right gives `(0, R)`.
- Gain −6 dB on Mid scales only the mid component (decode the output and check M and S).
- A gain device in the Side slot widens the image (S grows, M unchanged).
- Soloed-out slot still runs: a counting test device in it still sees blocks.
- Latency: a delay-reporting test device in one slot. The output equals the input delayed by
  that latency (empty other slot), and `latency_frames()` reports it.
- Async: an async test device in a slot makes `has_async_blocks()` true, and the output matches
  the synchronous path.
- Sleep: a tail-holding device in a slot keeps the split awake.

Godot (`Godot/tests/test_split_devices.gd`): a new instance of each has the expected slot keys
in order, and `DeviceSlots.accepts` rejects an instrument.

## Docs

- `AGENTS.md`: add both devices to the built-in device list and to the slotted devices line.
- `docs/subsystems/engine-architecture.md` "Device slots": add the split devices (audio slots,
  summed output, latency alignment).
- No OSC change.
