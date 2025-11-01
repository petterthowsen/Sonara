# Sonara Audio Engine – Performance Checklist (Rust engine + Godot UI over OSC)

> Prioritize items **top → bottom** in each section. Check things off as you implement them.

---

## 0) Baseline Hygiene (do these first)
- [X] **No allocations in the audio thread.** Pre-allocate all buffers, voices, and temp workspaces at init.
- [X] **No locks in the audio thread.** Replace `Mutex/RwLock` with single-producer–single-consumer (SPSC) **lock-free ring buffers** for UI ⇄ audio comms.
- [ ] **No logging/formatting in the callback.** Push counters to a telemetry buffer; format/print on a non-RT thread.
- [X] **Process in fixed blocks** (e.g., 64/128). Never traverse the graph per sample.
- [X] **Avoid transcoding**: adopt a single canonical sample format (prefer **f32, non-interleaved**) end-to-end.

---

## 1) Data Layout & DSP Hot Path
- [ ] Convert per-voice structs to **Structure of Arrays (SoA)** for contiguous access and fewer cache misses.
- [ ] **SIMD**: batch sample ops with `std::simd` (stable) or `wide`. Start with mixers, gains, biquads, saturators.
- [ ] **Precompute**: filter coeffs, envelopes step values, LUTs for `sin/cos/tanh`. Avoid `powf`/`sin` per sample.
- [ ] **Denormals**: enable FTZ/DAZ at engine start to prevent subnormal stalls.
- [ ] **Tight loops**: mark tiny math as `#[inline(always)]` (judiciously; verify with profiles).
- [ ] **Temporary buffers**: allocate once per worker and reuse; avoid per-node scratch allocations.

---

## 2) Graph Execution & Concurrency
- [ ] **Topologically sort** the DSP graph once; keep a flat vector of node execution records.
- [ ] **Buffer routing cache**: resolve channel maps & fan-in/fan-out offline; no lookups in the callback.
- [ ] **Parallelism**: split independent subgraphs/tracks to a **fixed RT thread pool**. Each worker owns its buffers (no atomics on hot path).
- [ ] Use **work queues** prefilled per block to minimize scheduling overhead.
- [ ] **Zero-copy** between nodes where possible; process in-place when producers are single-consumer.

---

## 3) UI (Godot) ⇄ Engine (OSC) Bridge
- [ ] **SPSC mailboxes** for: parameter changes → audio; meters/telemetry → UI. OSC encode/decode **off** the RT thread.
- [ ] **Coalesce parameter changes per block**; apply at block boundaries, not per sample.
- [ ] **Throttle UI updates**: meters/spectra at **20–30 FPS** max; send **RMS + peak** + short history bucketed/decimated.
- [ ] **Monotonic timestamps + sequence IDs** in messages to resolve reordering/skips.
- [ ] **Batch messages**: one parameter frame per track/device per block; avoid N tiny packets.
- [ ] **Back-pressure**: if UI falls behind, drop oldest meter frames (never block the audio side).

---

## 4) Plugin Hosting (CLAP-first; VST/LV2 similar)
- [ ] **Strict RT rules**: host must not call plugin methods that can block from the audio thread.
- [ ] **In-place processing** preferred; share engine’s pre-allocated buffers with plugins (no copies).
- [ ] **Fixed block size** negotiation: set and keep stable to maximize plugin internal optimizations.
- [ ] **Worker thread**: use CLAP worker for heavy plugin tasks; never route to RT thread.
- [ ] **Parameter cache**: resolve param IDs → indexes once; avoid string lookups during process.
- [ ] **Bus layouts** cached per plugin configuration; reconfigure only on graph changes.

---

## 5) Scheduling, Priority & Affinity (Linux)
- [ ] **RT priority** for the audio thread (`SCHED_FIFO` via `rtkit`/PipeWire/JACK). Verify with `chrt -p <pid>`.
- [ ] **CPU governor** to `performance`; disable turbo downclocking for stability during sessions.
- [ ] **CPU affinity**: pin the audio thread to a dedicated core (or 2 HT siblings). Pin UI/IO to other cores.
- [ ] **IRQ affinity**: route the audio interface IRQ to the **same CPU** as the audio thread for cache locality.
- [ ] **NUMA awareness (if multi-socket)**: bind engine memory & thread to the same NUMA node as the IRQ.
- [ ] **Memory locking**: `mlockall(MCL_CURRENT|MCL_FUTURE)` to prevent RT page faults (ensure limits).

> Keep these tunings behind a “**Low-latency Mode**” toggle and document system prerequisites.

---

## 6) I/O & Latency Policy
- [ ] Start conservative (e.g., 256/512 fpp), then **auto-probe down** to 64/128 if CPU headroom allows.
- [ ] **Consistent sample rate** across engine, plugins, and interface; avoid SRC in the hot path.
- [ ] **Safety offsets**: when scheduling MIDI, add a small **look-ahead** equal to 1 block for jitter immunity.
- [ ] **Click-free state changes**: ramp gains/envelopes over a few samples; schedule graph changes at block edges.

---

## 7) Build & Toolchain
- [ ] **Release builds** with `-C target-cpu=native -C opt-level=3 -C lto=thin -Z perf-prof` (adapt flags per stable toolchain).
- [ ] **panic=abort** in the engine binary; no unwinding in RT.
- [ ] Use **`#[cold]`** for error paths; **`#[inline(never)]`** for large rarely-hit code to help icache.
- [ ] Strip symbols in release; keep a separate “with debug symbols” artifact for profiling.

---

## 8) Telemetry & Profiling (without violating RT)
- [ ] **Lightweight counters** in the audio thread: block time (ns), overrun count, node timings (approx, bucketed).
- [ ] **Scope sampling**: instrument a tiny, branch-free timestamp capture to a ring buffer; consume on a debug thread.
- [ ] Provide a **/perf overlay** in Godot: audio load %, xruns, worst-block time, per-device % (from non-RT thread).
- [ ] Use system profilers for off-RT analysis: `perf`, `sysprof`, `Tracy` (with manual zones from non-RT threads).
- [ ] **Synthetic scenes**: ship benchmarks (N tracks × M devices) to reproduce hotspots quickly.

---

## 9) Device Implementations (examples to optimize early)
- [ ] **Mixers/panners**: SIMD gains, deinterleave/reinterleave once at graph edges only.
- [ ] **Filters**: transposed-direct-form II biquads with SIMD; pre-warped coeffs; process by blocks.
- [ ] **Delays/reverbs**: circular buffers with power-of-two masks; SIMD FIR partitions; late-reverb partitioned FFT with block sizes > 256.
- [ ] **Compressors/limiters**: rectification and envelope followers in SIMD; denormal guards on near-zero signals.
- [ ] **Analyzers**: window+FFT in background worker; UI gets **downsampled magnitudes** (log-binned).

---

## 10) Godot UI Performance (so UI never starves audio)
- [ ] Cap redraws to monitor refresh; **no redraw on every meter tick**—only when data changes.
- [ ] **_draw()** for heavy visuals (grids, scopes) with cached paths/meshes; avoid many child Controls for dense grids.
- [ ] **Spectrum/oscilloscope**: decimate points; send ~256–512 bins to UI, not full FFT.
- [ ] Debounce layout thrashers (resizes/zoom); do not compute expensive paths on every frame.

---

## 11) Fault Tolerance & Glitch Resistance
- [ ] **XRUN recovery**: skip non-essential work next block (e.g., UI telemetry) after an overrun.
- [ ] **Guarded plugin calls**: if a plugin misbehaves, auto-bypass and keep engine alive.
- [ ] **Atomic scene swaps**: prepare new graphs off-thread, swap pointers at block boundary.

---

## 12) Ops & Presets
- [ ] **Performance profiles**: 
  - *Safe*: big buffer, single-core, UI rich.
  - *Studio*: mid buffer, RT, pinned, UI throttled.
  - *Live*: small buffer, RT, pinned, UI minimal, analyzer off.
- [ ] **Self-check** command prints current scheduling, governor, IRQ mapping, and warns on misconfig.

---

## 13) “Nice to Have” (Advanced / Risky — implement after the above)
- [ ] **PREEMPT_RT kernel** or low-latency kernel flavor for <3ms roundtrip goals.
- [ ] **CPU isolation** (`isolcpus=`, `nohz_full=`, `rcu_nocbs=`) for a dedicated audio core.
- [ ] **NUMA-pinned allocators** and hugepages for large convolution tails (measure first).
- [ ] **Ahead-of-time plan caching**: pre-compiled DSP plans per graph topology & SR/block size.

---

## Quick Code Sketches (for reference)

**Audio thread creation (RT + affinity)**
```rust
let builder = std::thread::Builder::new().name("audio-rt".into());
let handle = builder.spawn(|| {
    // 1) Raise priority (via rtkit/DBus helper or direct pthread if permitted)
    // 2) Pin to core:
    if let Some(core_ids) = core_affinity::get_core_ids() {
        core_affinity::set_for_current(core_ids[0]);
    }
    // 3) Run audio loop (no allocs/locks/logging)
    run_audio_callback();
}).unwrap();
