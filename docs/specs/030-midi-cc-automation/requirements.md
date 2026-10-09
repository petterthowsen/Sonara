# MIDI CC automation — Requirements

Amends [003-automation](../003-automation/requirements.md): REQ-015 (the picker's per-device `CC`
group) and the `Piano / CC1 Mod Wheel` example in REQ-017. Delivers the "later CC-lane feature"
that REQ-016 anticipated.

## Problem

An automation lane can only drive a parameter a device lists. For the SFZ sampler that means a CC
shows up in the lane picker only when the loaded patch names or uses it, so a track cannot
automate, say, CC11 on a patch that never mentions it. Every other instrument (built-ins, CLAP,
VST3) offers no CC lanes at all, although a MIDI CC is a property of the channel's MIDI stream,
not of a device. In addition, a CC that arrives live from a keyboard or the virtual keyboard
never reaches the instrument today. Composers working with orchestral libraries (CC1 dynamics,
CC11 expression, CC73 attack) notice first.

## Scope

| | |
|---|---|
| Subsystem | both (Engine delivers the CC; Godot picks, draws and persists the lane) |
| Touches real-time audio thread | yes — CC values are resolved and delivered inside the audio callback |
| Adds or changes an OSC message | yes — a new lane target spelling on the existing `/track/{id}/automation/*` messages; no new address |
| Changes a persisted format (`config.json`, `.sonara`, `assets.json`) | yes — `.sonara` lane targets; lanes saved against a device's CC parameter must migrate (REQ-007) |

## Requirements

### REQ-001 — Any MIDI CC can be automated on any channel

The lane picker shall offer every MIDI controller number from 0 to 119 as an automation target on
a track's linked channel, whatever instrument the channel holds, and whether or not that
instrument declares the controller.

- **Acceptance:** Godot test builds the picker for a channel with a built-in synth and for one
  with an SFZ that uses only CC1, and asserts CC11 and CC74 are offered in both.
- **Example:** an empty SFZ patch on the channel; the picker still lists `CC11 Expression`.

### REQ-002 — Controllers 120–127 are not automatable

The lane picker shall not offer controller numbers 120 to 127 (the channel mode messages: all
sound off, reset controllers, local control, all notes off, omni and poly modes).

- **Acceptance:** Godot test asserts none of 120–127 appears in the picker, and that parsing a
  lane target for one of them fails.

### REQ-003 — A CC lane drives the channel's instrument

WHILE a lane on a CC target has points and is not bypassed, the audio callback shall deliver the
lane's value at the current tick as a controller change to the same devices that receive the
channel's notes, and a device that does not use that controller shall ignore it without error.

- **Acceptance:** Rust test: a channel whose first device records controller changes receives the
  lane's value on every buffer in which it changed, and a device that implements nothing receives
  nothing and does not fail. Live — a lane on CC1 audibly changes the dynamics of a VPO patch.
- **Example:** points CC1 = 0.0 at tick 0 and 1.0 at tick 960; at tick 480 the device receives
  CC1 ≈ 0.5.

### REQ-004 — CC values have 14-bit resolution

The system shall carry a CC lane's value as 14-bit (0–16383) from the lane to the device, and a
device shall receive the full 14 bits when it can accept them. A device limited to MIDI 1.0
messages shall receive the most significant 7 bits.

- **Acceptance:** Rust test: a lane value of 0.5 reaches a recording device as 8192 of 16383; a
  byte-based device receives 64. SFZ test: sfizz receives the unquantized-to-7-bit value.
- **Example:** a slow CC1 ramp over four bars reaches the SFZ sampler in steps of 1/16383, not
  1/127.

### REQ-005 — Automation applies while stopped and at once on seek

WHEN the playhead is moved while the transport is stopped, the audio callback shall deliver the
CC lane's value at the new tick, as other lanes do (003 REQ-008).

- **Acceptance:** Rust test: seek to a tick inside a ramp while stopped, run one buffer, assert
  the recording device received the value at that tick.

### REQ-006 — Releasing a lane restores the controller

WHEN a CC lane is bypassed, loses all its points, or is deleted, the system shall return the
controller to the value it had before the lane took over, if the device exposes that value, and
shall otherwise send nothing.

- **Acceptance:** Rust test: a device with a known CC value of 0.25; a lane drives it to 0.9;
  bypassing the lane returns the device to 0.25. A device with no known value gets no message.
- **Example:** the SFZ "CC1 Mod Wheel" knob is at 0.5; the lane runs to 1.0; deleting the lane
  returns CC1 to 0.5.

### REQ-007 — Lanes saved against a device's controller parameter become CC lanes

A device parameter is a *controller parameter* when its id is a MIDI controller number: every
parameter of the SFZ sampler, labelled (Parameters tab) or not (CC tab).

WHEN a project is loaded whose lane targets a controller parameter, the system shall load it as
a CC lane for that controller on the channel, with its points, curves, colour and bypass state
unchanged.

- **Acceptance:** Godot test loads a project dictionary containing a `device/0/param/1` lane on
  an SFZ sampler, and asserts the lane's target is the CC1 channel target with the same points.
  A second lane that would give the track two lanes for one controller is dropped with a logged
  warning.
- **Example:** a saved lane `device/0/param/73` (SFZ CC73 Attack) loads as `CC73 Attack`.

### REQ-008 — The picker offers controllers once, not per device

The lane picker shall not list a device's controller parameters under that device; they are
reached through the MIDI CC entries (REQ-001, REQ-009). A device with nothing else automatable
shall have no entry of its own.

- **Acceptance:** Godot test asserts an SFZ sampler contributes no device submenu, and that a
  built-in synth's submenu holds its own parameters only.

### REQ-009 — Instrument-labelled controllers come first, with their labels

WHERE the channel's instrument labels or uses a controller (an SFZ with `label_cc73=Attack`),
the picker shall list those controllers first, under the instrument's labels, followed by the
remaining controllers named from the shared lookup (003 REQ-016). The list shall be searchable
and shall omit controllers that already have a lane on the track.

- **Acceptance:** Godot test: an SFZ labelling CC73 and CC72 yields `Attack` and `Release` at
  the head of the CC list; a track with a CC1 lane no longer offers CC1.
- **Example:** `Attack (CC73)`, `Release (CC72)`, then `CC0 Bank Select` … `CC119`.

### REQ-010 — A CC lane is identified by its controller

A CC lane's header shall read the controller number and name, with the instrument's label where
there is one.

- **Acceptance:** Godot test on the lane label for CC1 (`CC1 Mod Wheel`), CC74, and an unassigned
  number (`CC3`).

### REQ-011 — One lane per controller per track

The system shall allow at most one CC lane per controller per track.

- **Acceptance:** Godot and Rust tests: a second create for the same controller is refused.

### REQ-012 — Unchanged values are not re-sent

WHILE a CC lane's value is unchanged at 14-bit resolution since the previous buffer, the audio
callback shall not deliver it again.

- **Acceptance:** Rust test: a flat lane delivers once and then nothing across 100 buffers
  (003 REQ-011).

### REQ-013 — Live CC reaches the instrument

WHEN a controller change arrives live on a channel (a MIDI keyboard or the virtual keyboard), the
audio callback shall deliver it to the same devices as a lane would, at its frame offset.

- **Acceptance:** Rust test: a CC queued on the channel's live queue reaches a recording device
  with the frame offset the scheduler computed. Live — moving a keyboard's mod wheel changes an
  SFZ patch.
- **Example:** CC1 value 64 from a keyboard arrives as 64/127.

### REQ-014 — A live CC and a lane do not fight

WHILE a CC lane is driving a controller, the lane's value shall take precedence over a live CC
for that controller.

- **Acceptance:** Rust test: with a lane active on CC1, a live CC1 is not delivered; with the
  lane bypassed it is.

### REQ-015 — CC lanes survive a project round-trip and are undoable

CC lanes shall save and load with the project and every edit to one shall be undoable, as for
other lanes (003 REQ-022, REQ-023).

- **Acceptance:** Godot test: create, edit, save, reload; undo and redo restore each step.

### REQ-016 — CC lanes survive DAWproject export and import

WHEN a project with CC lanes is exported to DAWproject, each lane shall be written as an
automation of that controller on the track's channel, and WHEN such a file is imported it shall
become a CC lane again.

- **Acceptance:** Godot DAWproject round-trip test: a CC1 lane with three points comes back as
  a CC1 lane with points within 2 % of the range (`docs/subsystems/dawproject.md`).

## Non-functional

- **Real-time safety:** resolving, deduplicating and delivering a CC must not allocate, block,
  do I/O or take a lock the callback cannot `try_lock`. Per-lane cost is one cursor step
  (003 REQ-010).
- **Latency / performance:** delivery is at most one buffer behind the lane's tick, as for other
  lanes; live CC keeps the one-buffer live latency notes have.
- **Compatibility:** an older project loads (REQ-007); a project saved with CC lanes will not
  load those lanes in an older build, which reports them as unresolvable and keeps their data
  (003 REQ-024).

## Out of scope

- CC events stored in MIDI clips (recording, editing, playback).
- CC learn, pitch bend, channel pressure, polyphonic aftertouch, program change, RPN and NRPN.
- MIDI 2.0 messages.
- CC delivery to VST3 plugins (follow-up spec: needs `IMidiMapping` in the plugin host). A CC lane
  on a channel whose instrument is a VST3 plugin is created and saved, and has no audible effect.
- Automating a parameter that is not a controller (those stay device parameters).

## Open questions

None. Resolved with the user:

- [x] **LSB for byte-based plugins:** MSB only (7-bit). No LSB message is ever sent (REQ-004).
- [x] **REQ-006 without a known base:** nothing is sent and the last automated value stays.
- [x] **Scope:** live CC delivery (REQ-013, REQ-014) and DAWproject round-trip (REQ-016) stay in this spec.
