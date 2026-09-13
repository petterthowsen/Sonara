# Engine Timing Checklist

Here's a **concise but complete reference checklist** for ensuring your implementation is "correct" and sample-accurate.

---

## 🧭 General Concepts

| Concept | Description |
|---------|-------------|
| **Block-based engine** | The audio callback processes _N_ samples at a time (the "block size"). The engine never processes individual samples in real time, only fixed chunks. |
| **PPQ (Pulses Per Quarter)** | A tempo-based tick resolution used for MIDI/timeline positions (960 PPQ = 960 ticks per quarter note). |
| **Sample clock** | The fundamental high-resolution time base. All positions in PPQ or seconds ultimately resolve to a sample position. |
| **Tempo map** | A mapping between PPQ ↔ samples that changes dynamically with tempo and time signature automation. |

* * *

## 🧩 The Core Principle

Everything must ultimately resolve to **sample positions**.

> ✅ The DAW should maintain a master transport position in both **samples** and **PPQ**, and be able to convert precisely between them at any time.

So each audio block has:

- **Start sample position**
- **End sample position**
- **Start PPQ position** (derived from tempo map)
- **Duration in PPQ**

That allows per-block computation of:

- Which notes/events fall inside the block
- Exact sample offsets within the block
    

* * *

## ⚙️ The Processing Loop (Per Audio Callback)

Here’s the _canonical_ approach:

### 1. Determine Block Timing

```rust
let block_start_sample = transport.current_sample_position;
let block_end_sample = block_start_sample + block_size;
let sample_rate = engine.sample_rate;
let bpm = tempo_map.get_tempo_at_sample(block_start_sample);

// Convert to PPQ
let start_ppq = tempo_map.samples_to_ppq(block_start_sample);
let end_ppq = tempo_map.samples_to_ppq(block_end_sample);
```

### 2. Gather Events for This Block

Collect all events (MIDI, automation, etc.) whose PPQ position falls between `start_ppq..end_ppq`.

For each event:

```rust
let event_sample_offset = tempo_map.ppq_to_samples(event.ppq_position) - block_start_sample;
```

Clamp that to `0..block_size-1`.

> ✅ This guarantees sample-accurate event placement even though MIDI is expressed in PPQ.

### 3. Dispatch Events at Correct Offsets

- Feed per-sample or per-offset events into plugin voices or automation envelopes.
- Many plugins support sample offsets within process blocks (e.g., CLAP, VST3 `ProcessEvents`).

> 💡 Each plugin should receive events with a _sample offset_ relative to the start of its processing block.

### 4. Process Block

Process audio devices in dependency order:

```rust
for device in graph_topology_order {
    device.process(block_start_sample, block_size, event_list_for_device);
}
```

### 5. Advance Transport

At the end of the block:

```rust
transport.current_sample_position += block_size;
transport.current_ppq_position = tempo_map.samples_to_ppq(transport.current_sample_position);
```

* * *

## 🎵 Handling Tempo & Automation Changes

A good DAW does _sample-accurate tempo mapping_, not per-block.

That means:

- You can't assume tempo is constant across a block.
- Tempo automation might occur mid-block.
- The `samples_to_ppq()` and `ppq_to_samples()` functions should integrate over the tempo curve if it changes inside the block.

✅ Most DAWs use a **tempo map spline** (or pre-sampled curve) to do this efficiently.

* * *

## 🧠 Sample-to-PPQ Conversion

At constant tempo:

```rust
let samples_per_beat = (sample_rate * 60.0) / bpm;
let samples_per_tick = samples_per_beat / ppq;
```

At variable tempo:

```rust
let ppq_position = integrate_over_tempo_curve(samples);
```

* * *

## 📋 Accuracy Checklist

| Component | Description |
|-----------|-------------|
| [ ] **Sample-accurate event offsets** | Convert PPQ → sample offsets per event. |
| [ ] **Stable transport clock** | Master `current_sample_position` increments by block size per callback. |
| [ ] **High-resolution tempo map** | Allows PPQ↔sample conversion at arbitrary positions. |
| [ ] **Per-block start/end PPQ positions** | Derived from tempo map; avoids drift. |
| [ ] **Quantized scheduling (pre-roll)** | Events are queued ahead of audio callback to ensure no late dispatch. |
| [ ] **No floating-point accumulation drift** | Use integer sample counters, not continuous floats. |
| [ ] **Sub-block precision for note ons/offs** | Pass sample offsets to plugins (don't quantize to block). |
| [ ] **Timebase sync with Godot/UI** | Expose PPQ/sample position via OSC for meters and transport display. |

* * *

## ⚖️ Common Pitfalls

| Issue | Fix |
|-------|-----|
| ❌ Using floats for sample positions | Use `u64` integers for sample counters. |
| ❌ Quantizing events to block boundaries | Always compute intra-block offsets. |
| ❌ Assuming constant tempo | Support tempo automation curves. |
| ❌ Using system time instead of audio clock | Always derive from sample counter, not wall clock. |
| ❌ PPQ drift due to rounding | Recalculate PPQ/sample mapping from tempo map every block. |

* * *

## 🧩 Optional Enhancements

- **Sample-accurate automation curves** (interpolated across block)
- **Lookahead scheduling** for latency compensation
- **Audio graph parallelism** (using sample-block job system)
- **Offline render mode** with smaller or variable block sizes for higher accuracy

