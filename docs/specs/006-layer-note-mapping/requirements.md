# Layer Note Mapping — Requirements

## Problem

A drum kit built from several instruments (say bass drum, snare and cymbals SFZs, or samplers, or
CLAP plugins) can't be played from one clip on one track with each instrument on its own mixer
channel. The Drum Machine gives each pad its own return channel, but a pad answers to exactly one
note. A cymbals instrument with crash 1, crash 2 and ride on three keys needs three pads, three
copies of the instrument and three channels. The Layer container holds whole instruments, but every
slot receives every note, so it can't split a keyboard, move an instrument's notes to other keys, or
combine kits whose key layouts collide. Users notice this when they try to write orchestral or
acoustic drum loops, and also when they want an ordinary keyboard split (bass on the left hand,
piano on the right).

## Scope

| | |
|---|---|
| Subsystem | Both. Engine (Layer MIDI routing, Layer extra outputs), Godot (data model, a new mapping window, Layer device view) |
| Touches real-time audio thread | yes. Layer MIDI routing and Layer extra outputs run on the audio callback |
| Adds or changes an OSC message | yes. Setting a slot's note map, and turning a slot's separate output on or off |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes. Layer slots in `.sonara` gain a note map and a separate-output flag. Older projects have neither and load with today's behaviour (REQ-016) |

## Terms

- **Slot**: a Layer child (a slot chain), as in `CONTEXT.md`. It can hold any instrument: SFZ,
  sampler, Polysynth or CLAP plugin. Nothing in this spec depends on which one.
- **Input note**: the MIDI pitch arriving at the Layer, from a clip or live input.
- **Output note**: the pitch a slot's instrument receives.
- **Slot note map**: a slot's routing table. It maps each input note (0–127) to at most one output
  note, or to *nothing* (the slot ignores that input note).
- **Full map**: the default slot note map, where every input note goes to the same output note.
  This is how every Layer slot behaves today.
- **Empty map**: a slot note map that maps no input notes.
- **Zoned slot**: a slot whose note map isn't the full map.
- **Overlap**: an input note that two or more zoned slots map.
- **Mapping window**: the new window where slot note maps are edited.

## Requirements

### Routing

### REQ-001 — Slots receive mapped notes only

WHEN the Layer receives a note-on, it shall send one note-on to each slot whose note map maps that
input note, at that slot's output note, with the incoming velocity and the same sample position.
Slots that map the input note to nothing don't receive it.

- **Acceptance:** engine unit test. Slot A maps 36 → 36, slot B maps 36 → 49, and slot C maps 36 to
  nothing. A note-on on 36 at frame offset 17 reaches A as 36 and B as 49, both at offset 17, and
  doesn't reach C.

### REQ-002 — Note-offs follow their note-ons

WHEN the Layer receives a note-off, it shall send it to each slot and output note that received the
matching note-on. It does this even if the slot's note map changed, the slot was muted, or the slot
moved to another position while the note was held.

- **Acceptance:** engine unit test. Note-on 36 with slot B mapping 36 → 49, change B to map
  36 → 51, then note-off 36. B receives a note-off on 49 and nothing on 51.

### REQ-003 — Full map by default

A new Layer slot shall have the full map, so a Layer with no mapping edits behaves exactly as it
does today.

- **Acceptance:** existing Layer tests in `Engine/src/audio/devices/layer.rs` pass unchanged, and a
  new test checks that a fresh slot forwards all 128 notes to themselves.

### REQ-004 — Live input and playback are routed alike

The Layer shall route live MIDI input (armed channel, virtual keyboard) and clip playback through
the same slot note maps.

- **Acceptance:** live. With the cymbals slot mapping 42 → 49, playing 42 on the virtual keyboard
  and playing a clip note on 42 both sound the cymbals' key 49.

### Separate outputs

### REQ-005 — Slot separate output

WHERE a slot's separate output is on, the Layer shall send that slot's audio to the slot's own
return channel instead of the Layer's main output. The slot's volume, mute and solo still apply
before the audio reaches the return.

- **Acceptance:** engine unit test (the slot's audio appears on its extra output and not on the
  main output) plus a live check: the snare is heard through its own mixer strip, and that strip's
  fader and effects change only the snare.

### REQ-006 — Return channels for separate outputs

WHEN a slot's separate output is turned on, the project model shall create a return channel for it,
named after the slot and nested under the Layer's channel, following the multi-out rules of spec
001 (no timeline track, can't be moved out of its parent, is deleted and restored with its source).
WHEN the separate output is turned off, or the slot is removed, the return channel shall be removed.
Undo shall restore it with its original id and settings.

- **Acceptance:** headless Godot test. Turn separate output on for "Snare": the Layer's channel
  gains one child "Snare" and the track count is unchanged. Set that return to −6 dB, turn separate
  output off, then undo. The return is back with the same id at −6 dB.

### REQ-007 — Where separate outputs are available

IF the Layer isn't the first device on a channel's root chain, THEN the Layer device view shall
disable the separate-output control and explain why in its tooltip.

- **Acceptance:** live. Put a Delay before the Layer: the separate-output toggles are disabled and
  the tooltip says so. Move the Layer to the front and they become enabled.

### Mapping window

### REQ-008 — Opening the mapping window

The Layer device view shall have a control that opens the mapping window for that Layer. The
window shall be a separate, non-modal window that can be resized, and there shall be at most one
per Layer. Opening it again focuses the existing one. WHEN the Layer is removed, its mapping window
shall close.

- **Acceptance:** live. Click "Mapping…" twice: one window, focused. The arranger stays usable
  while it's open. Deleting the Layer closes the window.

### REQ-009 — Window layout

The mapping window shall show a vertical piano of input notes on the left, a vertical piano of the
selected slot's output notes on the right, and a list of the Layer's slots. Both pianos cover all
128 pitches and scroll and zoom together. The output piano highlights the output notes the
selected slot's map uses.

- **Acceptance:** live. Scroll one piano and the other follows. Select "Cymbals", whose map is
  {42 → 49, 44 → 57}: output keys 49 and 57 are highlighted.

### REQ-010 — Showing the maps

WHILE a slot is selected, the mapping window shall draw a connection from each input note the slot
maps to its output note. It shall color each input key by the zoned slot(s) that map it, mark
overlaps, and fade the connections of unselected slots. A full-map slot is shown as a single
"all notes" state instead of 128 lines.

- **Acceptance:** live. With zoned slots Kick (36 → 36) and Snare (36 → 38, 37 → 40) and Snare
  selected, there are lines 36 → 38 and 37 → 40, and key 36 is marked as an overlap. Selecting a
  full-map slot shows the "all notes" state.

### REQ-011 — Editing connections

The mapping window shall let the user, for the selected slot:
- connect an input key to an output key (drag from input to output),
- connect a range of input keys to a range of output keys starting at the dropped key, one to one
  in pitch order,
- disconnect one or more input keys,
- shift a selected set of input keys up or down, keeping their output notes.

Each edit shall update the engine immediately and shall be a single undo step. Editing a full-map
slot first turns it into an empty map, then applies the edit.

- **Acceptance:** headless test for the model operations and undo. Live: on a full-map Cymbals
  slot, drag 42 → 49, play 42 and hear the cymbals' key 49, and play 60 and hear nothing from the
  cymbals. Undo, and the cymbals play every note again.
- **Example:** in the Snare slot select input keys 37–40, shift up 12: they become 49–52 with
  unchanged output notes.

### REQ-012 — Clearing and resetting a slot

The mapping window shall let the user clear the selected slot to an empty map, and reset it to the
full map. Each is a single undo step.

- **Acceptance:** headless test. Clear a slot: it maps nothing. Reset it: it forwards all 128
  notes to themselves. Undo restores the previous map each time.

### REQ-013 — Auditioning

WHEN the user clicks an input key, the mapping window shall play that pitch through the Layer, with
every slot's map applied. WHEN the user clicks an output key, it shall play that pitch on the
selected slot only, with no mapping applied.

- **Acceptance:** live. Clicking input 36 plays the kick. Clicking output 49 with Cymbals selected
  plays the cymbals' key 49 even if no input maps to 49.

### Automatic assignment

Both actions are buttons in the mapping window. Adding a slot never changes any map by itself,
because overlapping full maps are how layering works (a pad stacked on a piano).

### REQ-014 — Resolve overlaps

WHEN the user chooses "Resolve overlaps", the mapping window shall go through the zoned slots in slot
order. A slot that overlaps an earlier slot shall have all its input notes shifted by the same
amount, the smallest shift (up on a tie) that leaves it overlapping no earlier slot. Output notes
are unchanged, and full-map slots are left alone. It is a single undo step.

- **Acceptance:** headless test. Kick maps {36}, Snare maps {36, 37} and Cymbals maps {49, 51}.
  After resolving, Kick keeps {36}, Snare maps {37, 38} (shift +1; −1 would still hit 36), and
  Cymbals is untouched. No input note is mapped by two zoned slots.

### REQ-015 — Distribute

WHEN the user chooses "Distribute", the mapping window shall reassign the input notes of every
zoned slot so the slots sit one after another in slot order, starting at C1 (36), with no gaps. Each
slot's mappings keep their pitch order and their output notes. Full-map slots are left alone. It is
a single undo step.

- **Acceptance:** headless test. Kick {36 → 36}, Snare {38 → 38, 40 → 40}, Cymbals {49 → 49,
  51 → 51, 57 → 57}. After distributing: 36 → Kick 36, 37 → Snare 38, 38 → Snare 40,
  39 → Cymbals 49, 40 → Cymbals 51, 41 → Cymbals 57.

### Persistence

### REQ-016 — Saving and loading maps

The project file shall save each Layer slot's note map and separate-output flag. IF a saved slot
has neither, THEN the project model shall load it with the full map and separate output off.

- **Acceptance:** headless test. A zoned, remapped slot with separate output on survives a save →
  load round trip, and the engine receives the same map after load. A project JSON without the new
  keys loads with full maps.

### Revision 2026-09-29: slot names, colours and routing

Added after the first live pass, at the user's request.

### REQ-017 — Renaming a slot

The Layer device view shall let the user rename a slot in place (double-click its name). The rename
is a single undo step.

- **Acceptance:** live. Double-click "PolySynth" in a slot row, type "Snare" and press Enter: the
  row reads "Snare", and undo puts "PolySynth" back.

### REQ-018 — Slot and return share a name

WHILE a slot's separate output is on, the project model shall keep the slot's name and its return
channel's name equal. Renaming either one renames the other. Project-unique suffixes on the channel
(e.g. "Snare 2") carry over to the slot.

- **Acceptance:** headless test. With separate output on, rename the slot to "Snare": the return is
  "Snare". Rename the return to "Rim": the slot is "Rim". Undo each rename, and both follow.

### REQ-019 — Slot and return share a colour

WHEN a slot's return channel is created, it shall take the slot's colour. WHILE the separate output
is on, changing the slot colour or the return channel colour shall change the other one to match.

- **Acceptance:** headless test. The return is created in the slot's colour. Recolour the return
  to red: the slot colour is red. Recolour the slot to blue: the return is blue.

### REQ-020 — Routing a Layer return

The mixer shall let the user route a Layer slot's return channel to Master or to any valid bus or
group, like a top-level channel. The return stays in the Layer's fold-out. Its route shall survive
turning the separate output off and on again, undo, and save → load. Drum pad and plugin returns
stay locked to their parent.

- **Acceptance:** headless test. Route the Snare return to bus "Perc High": `route_locked()` is
  false for it and true for a drum pad return. Turn separate output off, undo: it still routes to
  "Perc High". Save → load keeps the route. Live: the snare is heard through "Perc High", and the
  Layer channel's own effects still process the non-separate slots once.
- **Note:** this revises spec 001's REQ-001 ("output locked to it") and this spec's REQ-006 for
  Layer returns only.

### Revision 2026-09-29 (b): second live pass

### REQ-021 — Long slot names

The Layer device view shall widen to fit each slot's full name, so a name never runs under the
slot's controls.

- **Acceptance:** headless. A slot renamed to a long name widens its row. Live: the Layer panel
  grows instead of clipping.

### REQ-022 — Slot knob follows the separate output

WHILE a slot's separate output is on, the slot row's volume knob shall show and set its return
channel's volume (dB, as the mixer fader does, undoable). Otherwise it sets the slot's Layer volume.

- **Acceptance:** headless. With OUT on, turning the knob to −6 dB sets the return to −6 dB and
  leaves the slot volume alone, and moving the return's fader moves the knob. With OUT off, the
  knob controls the slot volume again.

### REQ-023 — The return shows the slot's devices

WHILE a slot's separate output is on, the mixer strip and the device lane of its return channel
shall show the slot's device chain first, followed by the return's own devices, as a drum pad
return does (spec 001 REQ-015). Nothing can be placed before the slot chain.

- **Acceptance:** headless. `PadLane.devices(return)` is [slot chain, return devices…], and a drop
  in front of the slot chain is refused. Live: select the Snare return and see the Snare SFZ, then
  its effects.
- *Revised 2026-09-29:* the slot chain itself isn't shown. The lane lists the slot chain's devices
  ([SFZ, EQ…][return devices…]). They're fixed in place from the return's lane, a device dropped
  among them goes into the slot chain, and return devices move only among themselves.
- *Revised again 2026-09-29:* drum pad lanes work the same way (no visible pad chain), which
  replaces spec 001 REQ-017's "the front device plays the pad". The source's devices can be
  reordered among themselves from the lane.

### REQ-024 — Turning OUT on resets the slot volume

WHEN the user turns a slot's separate output on from the slot row, the slot's Layer volume shall
reset to unity in the same undo step, so no hidden cut sits in front of the return's fader.

- **Acceptance:** headless. The slot is at 0.3, OUT goes on, and the slot is at 0.5 with separate
  output on. Undo restores 0.3 with OUT off.

### REQ-025 — Auto note map from a Layer (pulled in from the later phase)

WHILE a channel's note map is Auto and its first Auto source on the root chain is a Layer with at
least one zoned slot, the effective map shall have one entry per input note that a zoned slot maps:
- the slot's name when the slot maps a single note ("Kick");
- otherwise "<slot> <output note>" ("Cymbals C#2");
- names joined with " + " when several zoned slots share the input.
Each entry is coloured in its slot's colour. Full-map slots add nothing, and a Layer with only
full-map slots isn't an Auto source. Such a channel opens in Drum View by default, and an open clip
editor follows mapping, name and colour edits.

- **Acceptance:** headless (`test_layer_note_map.gd`). With Kick {36}, Snare {36→38, 37→40} and
  Cymbals {42→49, 44→51}, the entries are exactly 36 "Kick + Snare D1", 37 "Snare E1",
  42 "Cymbals C#2" and 44 "Cymbals D#2". The watcher fires on a mapping edit, a rename and a
  recolour. Live: the clip editor's Drum View shows those rows.
- **Note:** key labels from the instruments (SFZ `label_key`, CLAP `note-name`) are still a later
  phase.

## Non-functional

- **Real-time safety:** Layer routing on the audio callback does no allocation, locking or I/O. The
  per-slot map and held-note state are fixed-size and allocated when the slot is created. Changing
  a map from the command thread doesn't allocate while the state lock is held.
- **Latency / performance:** routing a MIDI event costs one table lookup per slot. The mapping
  window stays interactive (under one frame per redraw) with 16 slots.
- **Compatibility:** older `.sonara` files load unchanged (REQ-016). The Drum Machine is untouched.
- **Engine mixing:** a multi-out source whose returns all route elsewhere is no longer a route
  target. Its first device must still run exactly once per block (it runs in the aux pass), with
  only its remaining effects running in the device pass.

## Out of scope

- **Later phase: instrument note names.** Key names or played keys from the instruments (SFZ
  `label_key`, CLAP `note-name`). Auto note map entries from slot names came in with REQ-025.
- One input note to several output notes within one slot. Several slots can still share an input
  note (layering).
- Velocity zones, per-slot transpose or octave controls, and key-range crossfades.
- The docked "main window popup" system (showing the mapping window in place of the
  arranger/mixer, with detach). For now the mapping window is a plain window.
- GM-aware automatic assignment.
- Merging the Drum Machine into the Layer.
- Separate outputs for a Layer that isn't first on the root chain (engine limitation from spec 001).

## Open questions

- [x] Automatic assignment is explicit only: "Resolve overlaps" and "Distribute" are buttons, and
      adding a slot never changes a map.
- [x] Slot volume, mute and solo apply before the separate output (REQ-005), as in the Drum Machine.
- [x] The Layer is instrument-agnostic. Played keys and key labels from instruments are a later
      phase, so no requirement depends on them.
