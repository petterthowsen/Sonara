# Audio → stems → MIDI → Sonara

Research notes (2026-09-16) on turning an existing track — Suno output, a
bounced demo, anything — into editable Sonara clips. Target shape:

```
source audio  →  stem separation  →  per-stem audio→MIDI  →  Sonara clips
```

Everything below runs **locally** and is open source. Nothing here needs a
hosted service.

MVSEP (mvsep.com) was evaluated and **excluded**: it is a closed cloud service
(API keys + credit tiers, GPU work on their infrastructure). Only its *training*
repo, [ZFTurbo/Music-Source-Separation-Training](https://github.com/ZFTurbo/Music-Source-Separation-Training),
is open source — the service itself is not.

## Tool table

| Stage | Tool | Licence |
|---|---|---|
| Separate vocals / drums / bass / other | Demucs v4 `htdemucs`, driven by the `audio-separator` CLI | code MIT; weights disputed ("scientific purposes only" claim in Demucs v4 README) |
| Clean-licence fallback separator | Spleeter 4-stem | MIT code; weight status still open (deezer/spleeter issue #898) |
| Keys / guitar / bass / pads → MIDI | Spotify **basic-pitch** | Apache-2.0, ships an ONNX export ⇒ commercial use fine |
| Piano specifically | **Transkun** (MVSEP's own changelog calls it SOTA piano audio-to-MIDI) | open source |
| Vocals melody | basic-pitch mono, or torchcrepe / omnizart `vocal` | MIT |
| Drums → MIDI (kick / snare / toms / hats / cymbals) | **ADTOF-pytorch** | code MIT-ish; **model weights CC BY-NC-SA 4.0 (non-commercial)**. omnizart `drum` is MIT |

Demucs → ADTOF is exactly the pipeline the local tool
[DrumLab](https://github.com/DomekRomek/DrumLab) wraps (AGPL-3.0), so that
combination is proven end-to-end on a desktop machine, not just in papers.

Full ranking and SDR/hardware detail for the separation half:
`~/.hermes/profiles/researcher/workspace/reports/2026-09-16-stem-separation-linux-daw.md`.

## The last hop: MIDI into Sonara

There is currently **no `.mid` file importer** in the repo. MIDI appears as
(1) hardware input devices / keyboard, and (2) the assistant-facing clip text
format — drums grid, pitched grid, event list (see
[`clip-text-format.md`](clip-text-format.md)). `docs/ai-integration.md` lists
raw `.mid` bytes under "what to skip" for the chat assistant.

Two ways to close it:

1. **Converter** — transcriber emits `.mid`, a small script reads it with a
   MIDI library and emits Sonara clip-text (notes + ticks → grid or event
   list), then the existing write tools place the clips. No engine change.
2. **Real importer** — add `.mid` parsing to the Rust engine. Note maps
   ([`specs/002-note-maps`](specs/002-note-maps/requirements.md)) already
   provide the mapping table, and the engine is 960 PPQ, so tick conversion is
   straightforward.

The converter gets you results today; the importer is the proper long-term
answer (drag a `.mid` onto a track like any other DAW).

## Quality expectations

- Transcribe the **isolated stem**, never the mix.
- Separation artefacts and reverb tails make transcription approximate. Bass,
  drums and vocal melody land roughly right; pads and strings come out as mush.
- Expect hand work on velocities and timing.
- Chain the separation if you want a specific target (e.g. pull the vocal
  first, then transcribe the instrumental), rather than asking one model for
  everything.

## Licence fork

- **Local / personal use**: run any of the above, including ADTOF.
- **Bundled in a shipped Sonara**: you're down to basic-pitch (Apache-2.0) plus
  a permissive separator; ADTOF's non-commercial weights and the disputed /
  unstated separator weight licences rule the rest out unless you licence or
  retrain them.
