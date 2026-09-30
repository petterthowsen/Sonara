---
type: research-report
topic: daw-design
status: final
projects:
  - sonara
source: ~/.hermes/profiles/researcher/workspace/reports/2026-09-28-synth-plugin-features-likes-dislikes.md
date: 2026-09-28
question: What do people value most in synth plugins (must-have features), what is nice-to-have but not essential, and what are the common complaints/pain points — to inform a built-in synth device for a DAW?
confidence: medium
note: Ranks by category durability, not by naming winners — model-specific claims (which synth ships which engine/browser) age fast and should be re-checked before acting. Preserve that framing; do not extract a "best synths" list from this.
tags:
  - synth
  - daw-design
  - ui-ux
  - cpu-performance
  - mpe
  - sonara
related:
  - "[[Piano roll and MIDI editing features users value]]"
  - "[[What users like and dislike about built-in DAW devices]]"
  - "[[Real-Time Physical Modeling Techniques for Audio Synthesis of Bowed Strings]]"
sources:
  - https://gearspace.com/board/electronic-music-instruments-and-electronic-music-production/1242088-wavetable-synthesizers-why.html
  - https://splice.com/blog/optimizing-serum-cpu-efficiency
  - https://monosounds.studio/serum-2-cpu-optimization
  - https://www.16sounds.com/blog/synthesizers-plugins-and-cpu-usage
  - https://www.kvraudio.com/forum/viewtopic.php?t=559152
  - https://www.kvraudio.com/forum/viewtopic.php?t=487838
  - https://www.kvraudio.com/forum/viewtopic.php?t=628368
  - https://tech.yahoo.com/audio/articles/ultimate-soft-synth-showdown-serum-105553312.html
  - https://monosounds.studio/best-wavetable-synth-2026
  - https://musictech.com/guides/buyers-guide/pigments-7-vs-absynth-6-vs-serum-2-which-super-synth-should-you-buy
  - https://www.xferrecords.com/forums/general/serum-resizable-gui
  - https://community.native-instruments.com/discussion/14902/super-8-gui-bug-impossible-to-use-in-ableton-live-with-a-4k-monitor
  - https://forums.steinberg.net/t/cubase-issues-with-hidpi-and-vst3-plugins-of-some-developers/764809
  - https://forum.vital.audio/t/1-5-1-clap-synth-ui-only-fills-half-the-window-on-hidpi-in-bitwig-macos/10162
  - https://forum.synapse-audio.com/viewtopic.php?p=120157
  - https://docs.native-instruments.com/ni-tech-manuals/absynth-6-user-guide/en/browser-page
  - https://sonicbloom.net/optimise-ableton-live-12-browser
  - https://goldmidi.com/community/threads/aliasing-quietly-wrecks-the-top-end-of-your-synths.75890
  - https://tonalux.org/blog/blep-minblep-polyblep-antialiased-oscillators
  - https://forum.arturia.com/t/arturia-internal-upsampling-policy-2024/2380
  - https://www.attackmagazine.com/technique/synth-secrets/what-is-a-modulation-matrix-how-does-it-work
  - https://dreyandersson.com/music-production-terms/modulation-matrix
  - https://www.bitwig.com/learnings/5-things-you-can-do-with-msegs-248
  - https://jamesm.blog/music-production/mpe-deep-dive
  - https://gearspace.com/threads/whats-the-deal-with-mpe-synths.1385603
  - https://lostsynapse.store/articles/laura-vs-serum-vital-and-pigments
  - https://www.bitwig.com/polymer
  - https://prod.fabfilter.com/forum/topic/7352/stuck-notes-in-twin-3
  - https://synthanatomy.com/2026/09/imfmsynth-an-8-operator-0-algorithm-fm-synthesizer-with-wavetables.html
open_questions:
  - No quantitative survey of synth-feature preference exists; this is forum/press consensus, weighted toward experienced producers and toward complaint-driven posting.
  - Whether Sonara will expose a host-level modulation system (which would promote CLAP host modulation from nice-to-have to must).
  - How much MPE depth matters for Sonara's actual audience (it is a player's feature, less relevant to programming-first users).
  - Genre weighting is only partly separable — EDM/bass vs cinematic/ambient users value different things.
  - Model-specific claims (which synth ships which engine/browser) age quickly and should be re-checked before acting.
---

# Synth plugins: what users value, want, and complain about

Status: final (2026-09-28).

## Answer (short version)

The praise clusters are consistent and ranked below by how often they recur and how hard
they are defended. Two things dominate, and neither is a headlining synthesis feature:

1. **It must sound good and have character** — this is the gate everything else passes
   through. "First and foremost sound. If it doesn't sound good, it's not ever going to be
   recorded, and then just becomes dead weight and gets sold. Ease of use/UI is a close
   second."[1]
2. **It must not fight you** — fast, legible workflow: drag-and-drop modulation, a browser
   that finds sounds, no menu-diving. The single most-repeated praise for modern synths is
   mod assignment you can *see*.[8][10][22]

Then three more that decide whether a synth gets used or resold: **CPU discipline**,
**filters that stay musical**, and a **GUI that scales to a modern display**. The complaints
section is almost the exact inverse of this list — which is the useful signal: people do not
complain that a synth lacks granular synthesis, they complain that it eats a core, aliases in
the top octave, looks blurry on a 4K screen, or buries its presets.

For a **built-in DAW synth** specifically, two constraints sharpen the picture: it will run
on many tracks at once (so CPU and voice management move from "nice" to "essential"), and it
can never shift blame to a third-party installer, so the pricing/licensing/anti-piracy pain
points that dominate plugin complaints simply don't apply — but the HiDPI, browser and undo
pain points land entirely on the host.[11][13][15]

## Must-have features (table stakes)

**1. A real sound, with character.** Analog/VA character, filter behaviour and gain staging
matter more than the "analog" label; producers judge on how the synth sits in a mix, not the
marketing.[1] A tired-but-trusted subtractive synth still earns its place because "it pretty
much always sounds good."[8]

**2. A modern oscillator section + custom wavetable import.** Classic waveforms are assumed;
the gating question buyers actually ask is *"can I import my own wavetables?"* and *"can the
synth generate them?"*.[1] Wavetable import is now expected even in free/stock instruments —
Bitwig's stock Polymer reads Serum- and WaveEdit-compatible `.wt` files.[27]

**3. Filters: multiple types, slopes, and resonance that stays musical.** Buyers look for
filter *variety* (analogue, ladder, digital, comb, Sallen-Key) and "a useful selection of
shapes and slopes for each model."[8][27] High resonance that goes thin/harsh is a specific,
recurring complaint.[1] (This overlaps the sibling findings on effects devices, where resonance
compensation and integrated drive were the same ask.)

**4. Anti-aliasing done properly — a clean top end.** Aliasing "quietly wrecks the top end":
folded partials land as inharmonic fizz/glassiness on bright patches, and the tell is ghost
tones sliding *down* as you play up.[18] The fix is band-limited oscillators (BLEP/MinBLEP/
PolyBLEP), mip-mapped wavetables, or oversampling.[19][18] Serum markets "ultra-clean
oscillators" as a headline feature for exactly this reason.[19] Ordering matters too: "once
you have aliasing, you can't get rid of it" — it must be prevented in the oscillator, not
filtered out later.[18][19]

**5. Modulation depth *with fast assignment*.** Envelopes and LFOs are the floor; the modern
expectation is a mod matrix (or equivalent) with drag-and-drop routing, and increasingly
multi-segment/curve generators (MSEGs).[21][22][23] The design details that get praised:
colour-coded/visual routing so you can see what modulates what at a glance, editable response
curves, and the ability to modulate modulators ("meta-modulation").[22][10] Pigments is widely
cited as the benchmark precisely because "it surfaces what Serum's mod matrix buries."[22][10]

**6. A preset browser that actually finds sounds.** Tags, text search, favourites, and
audition-on-browse are the expected baseline.[16] The browser is explicitly a purchase
criterion: "a fast preset browser is a factor I consider when choosing a synth to use in the
moment," and users of Dune 3 describe "going through presets is a pain" while praising Zebra 2
and u-he browsers.[15] Serum's library was criticised as "not that helpful" beyond simple
categorisation plus preview.[10]

**7. CPU discipline and voice management.** This is the loudest technical complaint (see
below). The must-have is not "low CPU" in the abstract but *predictable* CPU: sensible default
polyphony, a voice cap, voice stealing, and a quality/oversampling control.[2][3] Steve Duda's
diagnosis of Serum CPU complaints: they come "first and foremost … from heavy voice count
compounded by not watching poly limits sensibly," and "7 unison is the sweet spot."[2] Massive
is credited for capping voice count and auto-redistributing, which prevents CPU spikes.[2]

**8. A resizable, HiDPI-crisp GUI.** Non-negotiable now. Serum shipped without a scalable GUI
for years and the thread is a case study in the resulting anger — "the very tiny UI makes this
otherwise impressive synth completely unusable for me" — until the resizable GUI landed and
users called it "a life saver on high DPI screens."[11]

**9. Undo/redo.** No longer optional; the absence is treated as a defect. Adding "full undo and
redo capabilities" was listed as a headline improvement in Serum 2.[22]

**10. Expression support (MPE / poly aftertouch).** By 2026 "most major soft synths support
it," and it has moved from niche to expected.[24][25] The catch is depth: a thin implementation
routes per-note pressure to existing mod destinations, while a real one lets each MPE
dimension drive independent envelopes/routings — you can tell them apart by holding pressure
on one note of a chord and watching whether the others stay put.[24][25]

## Nice-to-have (valued, but not gating)

These differentiate and delight, but nobody leads their complaint with their absence. Ranked
roughly by how close they are to becoming must-haves.

**1. Multi-engine / hybrid synthesis.** The clear 2025–26 direction: a synth that ships only
wavetable is now seen as single-purpose. Serum 2 added Sample, Multisample, Granular and
Spectral engines on top of wavetable; Pigments spans eight engines including an additive
"Harmonic" mode and a physical-modelling "Modal" engine.[8][9] Extra engines are a real
purchase argument — Pigments can layer a granular texture against a virtual-analog bass in one
instance where Serum needs two.[9]

**2. Cross-modulation baked in (FM/AM/sync/ring/waveshaping).** Buyers ask "Does it have FM?
AM? Wavefolding/Bending?" — but the same buyer notes these are often "not needed, you can bake
these into your wavetable."[1] Valued, rarely decisive.

**3. Advanced/chaos modulation and random generators.** Free-drawable LFOs, chaos-based LFOs
(Lorenz/Rössler) and sample-and-hold are now selling points on flagship synths, valued for
non-repeating movement.[22] Powerful, but a minority of users ever reach for them.

**4. Flexible/parallel signal routing.** Multi-bus FX, serial-or-parallel filters, and modular
routing (Phase Plant's whole pitch) reward depth-seeking sound designers; the same architecture
is *penalised* by everyone else as slower to start from.[9] Strongly bimodal — a clear strength
for one audience, an obstacle for another.

**5. Arpeggiator / step sequencer, ideally with MIDI out.** A "powerful arpeggiator" and
per-step note/length/velocity are listed among headline features, and being able to send the
arp/sequencer out as MIDI to drive other synths is a genuine bonus.[8][22]

**6. Macro controls.** Eight mappable macros are now standard on flagship synths and are
praised as a way to make a complex patch playable.[8]

**7. Integration with the host's modulation system; CLAP host modulation.** Synths that accept
the DAW's own modulators (rather than only their internal ones) fit deeper into a host like
Bitwig.[22][29] Relevant if the host has a modulation system to expose.

**8. Microtuning (MTS-ESP) and MIDI 2.0 readiness.** Microtuning is a niche-but-loyal
audience's dealbreaker; some synths now ship it as a bullet point alongside undo/redo and UI
scaling updates.[29][26] MIDI 2.0's per-note resolution is arriving slowly and mostly
future-proofing for now.[25]

**9. Preset discovery aids beyond search.** "Similar preset" suggestions (Pigments), a Mutator
that morphs toward tag descriptions, and guided/interactive tutorials are increasingly cited as
pleasant differentiators.[10][16]

**10. A preset/tutorial ecosystem.** Serum's dominance is explicitly *not* its features but its
network: "every preset pack, every tutorial, every YouTube walkthrough and every collaborator …
already speaks Serum."[26][9] A built-in synth cannot manufacture this, which is worth knowing
before competing on features alone.

**11. Standalone operation and offline/account-free use.** Absence of a standalone is listed as
a limitation of Serum.[2] A small but vocal minority treat "pay once, own it, no account,
offline activation, no telemetry" as a purchase criterion in its own right.[26]

## Common complaints and pain points

**1. CPU usage — by far the loudest.** "Since the update dropped, high Serum 2 CPU usage is
the complaint I hear more than any other."[3] Reviewers list "Can hit your CPU hard" as Serum's
main con.[2] Vital is called "VERY high in CPU" by users in a thread specifically about finding
light instruments.[7] The heaviest offenders — u-he Diva, Repro, Softube Modular — get threads
about being unusable on weaker machines.[6][4] Two things to note: the cost is *variable* (it
depends on patch, voices, unison, release tails, effects), so meters swinging wildly confuses
users,[5] and much of it is self-inflicted — voices multiply everything, so unison 16 on a
four-note chord is 64 voices before any effect.[3] Practical mitigations users are told to
apply: cap polyphony to what the part needs, drop unison to 3–7, keep oversampling at 2×, and
shorten amp release.[2][3] Both Serum 1 and Massive show CPU rising with voice count and
oversampling.[2] A recurring counter-take ("if CPU usage is an issue, you need a new system")
exists but is a minority view in these threads.[7]

**2. Aliasing / a dirty top end.** Bright, high-pitched patches on naive or under-engineered
oscillators produce inharmonic fizz, glassiness or metallic ringing that "has no musical
relationship to the note you actually played," and it cannot be removed once generated.[18][19]
FM and high-resonance settings are the usual triggers.[18][19] Arturia was publicly criticised
for internal upsampling shortcomings — audible aliasing as low as MIDI note 72 on one preset at
44.1 kHz, and rolling off everything above ~17 kHz at 44.1 kHz.[20] Caveat: this is an informed
user's measurement in a vendor forum, not a lab report.

**3. GUI scaling / HiDPI breakage.** A huge, recurring, cross-vendor complaint: tiny GUIs,
blurry bitmaps ("Auto-scaling" = bitmap stretching), cropped editors, windows that grow on each
reopen, and blank regions.[11][12][13][14] Native Instruments' Super 8 was reported "impossible
to use in Ableton Live with a 4K monitor" — either "sooooo tiny" or mostly black with controls
detached from the visible UI.[12] The root causes are split between plugins (JUCE VST3
`checkSizeConstraint` mishandling) and hosts (Ableton's HiDPI support was long criticised;
Cubase had its own scaling pathologies).[13][14] Some users' only workaround is to switch HiDPI
*off* entirely.[13] The lesson for a host: resizing and DPI moves between monitors must be
handled correctly, because users largely cannot fix it themselves.[13][14]

**4. Weak preset browsers.** "Going through presets is a pain … a 'search' function by tags and
favorites is a must today."[15] Reported specifics: browsers too small, favourites that don't
sort or sync across machines, and losing your place when the mouse strays onto the synth
GUI.[15] Serum's browser is called a weakness versus competitors.[10] Live 12's move to
tag-based browsing was itself contentious — some users found it *worse* than the old folder
structure and said it "stopped me from making music at all."[17] So "tags" is not automatically
the answer; discoverability is the goal and both folders and tags can fail it.

**5. Menu-diving and opaque routing.** Synths with deep but hidden routing get dinged for it:
Massive X's "complex routing menu" is described as requiring you to "dig in deep," and Serum's
mod matrix "buries" what Pigments surfaces visually.[8][9][22] The complaint is not depth —
it's depth you can't see.

**6. Copy protection, accounts, and blurring.** iLok-style schemes and account/activation
friction are resented; one UADx bug even blurred the GUI when unlicensed.[13] A competing synth
markets itself explicitly on the opposite: "pay once, own it, and not have an account … offline
activation, no telemetry."[26]

**7. Ecosystem lock-in / no preset portability.** Serum patches (.fxp) don't open in Phase
Plant, Pigments or Spire; parameters aren't portable.[9] Great for incumbent lock-in, resented
by switchers — and a caution for a built-in synth: an open, documented preset format is a
kindness the incumbents don't extend.

**8. Paid updates and abandonment.** Charging for a version upgrade draws fire (Absynth's $120
update was scored against it), while free/lifetime-update policies are used as selling
points.[10]

**9. Smaller but real defects.** Stuck notes when auditioning arpeggiator presets and browser
favourites that stay unfixed for years (Twin 3).[28] Small things, but they erode trust in a
synth's browser and arp — both of which are must-haves above.

**10. Thin/harsh filters at high resonance.** Echoed from the sibling effects research: clean
digital filters that "go thin/nasty" at high resonance are a specific, repeated complaint, and
resonance compensation (keeping bass fat) is the requested fix.[1]

## What this means for a built-in DAW synth

The must-have list above is generic; a *built-in* device changes the weighting, because it will
appear on many tracks in a project and it cannot rely on a third-party ecosystem.

**Prioritised for a first-party stock synth:**

| Priority | Do this | Because |
| --- | --- | --- |
| Must | **Effortful CPU/voice discipline** — efficient default patch, sane poly cap + voice stealing, a quality/oversampling control (2× default, 4× on render), and always-on SIMD in the oscillator path | CPU is the #1 complaint, and a stock synth multiplies it across every track. Refusing to offer a low-quality/economy mode was publicly criticised in a competing product.[3][2][6] |
| Must | **Correct-by-construction anti-aliasing** (band-limited oscillators, mip-mapped wavetables) | It cannot be patched in later — "once you have aliasing, you can't get rid of it" — and a dirty top end is a trust killer.[18][19] |
| Must | **Resizable, HiDPI-correct GUI** including live re-scaling when the window moves between monitors | Users cannot work around host/DPI failures themselves; this is a host responsibility.[11][13][14] |
| Must | **A fast browser wired into the DAW's own tagging** (tags + folders + favourites + audition) | Browser quality is a stated purchase criterion; a bad one "stopped me from making music."[15][17] Serum's and Dune 3's browsers are the cautionary examples.[15][10] |
| Must | **Visual, drag-and-drop modulation + undo/redo integrated with DAW undo** | The most-repeated modern praise; and undo is now expected, not optional.[22][10] |
| Should | **Sound character** — invest in the filter and analog flavour | It is the gate everything else passes through, and the one thing users say can't be fixed later.[1] |
| Should | **Wavetable import** (Serum/WaveEdit `.wt` and standard WAV) | Cheap way to inherit the incumbents' wavetable libraries, and a gating question for buyers.[1][27] |
| Should | **MSEG / curve generators and meta-modulation** | Increasingly expected; drives the "evolving sound" use case.[22][23][21] |
| Should | **MPE + polyphonic aftertouch with real depth** | Now expected in major soft synths, but "supports MPE" spans thin *MPE-aware* to true per-note routing.[24][25] |
| Should | **Open, documented preset format** | Incumbent formats are locked; portability is a kindness and a differentiator.[9] |
| Could | Multi-engine (granular/spectral/modal), modular routing, arp/sequencer with MIDI out, macros, microtuning | Valued by depth-seekers, not gating for most, and the modular/multi-engine direction is bimodal — it *slows down* preset-first users.[8][9][29] |

**Two structural advantages to press.** First, as a built-in device you have **no copy
protection, no installer, no account and no telemetry** — which is exactly the friction a
competitor markets against.[26][13][2] Don't reintroduce it. Second, a host can offer
**host-level modulation into the synth** (the Bitwig model, where one LFO can modulate any
device on the track), which is something a plugin-only synth cannot match.[22][27]

**One strategic caution.** Serum's grip is ecosystem, not features — "every preset pack, every
tutorial … already speaks Serum."[26][9] A built-in synth cannot win that fight by adding more
engines. It should win on the things plugins structurally can't do: flawless host integration,
DPI correctness, undo, a browser that shares the DAW's tags, and *predictable* CPU on a project
with 30 synth tracks. Compete where the plugins are weak, not where Serum is strong.

## Caveats and gaps

- **Evidence skews experienced and complaint-driven.** The forums and review outlets that
  dominate these sources (Gearspace, KVR, Ableton/NI/Steinberg forums, Sound On Sound, MusicTech)
  over-represent experienced producers, and people post about problems more than about
  satisfaction — so the complaints list is likely *louder* than the true frequency.[1][5][6][15]
- **Stated preference, not measured behaviour.** No quantitative survey of synth-feature
  preference surfaced; this is forum/press consensus, weighted toward loud online communities.
- **Some sources are content-marketing.** Vendor-adjacent blogs (e.g. a wavetable-synth
  round-up, a Serum-CPU guide) were used for direction and specific, checkable claims, not for
  rankings.[3][9]
- **The Arturia aliasing figures are a user measurement** in a vendor forum, not a lab
  report — treated as a signal, not a fact.[20]
- **Fast-moving field.** Model-specific statements (which synth has which engine, which browser
  is best) age quickly; the *categories* here are more durable than the named examples.
- **Genre dependence is only partly separable.** EDM/bass users value different things from
  cinematic/ambient composers; the sources blend them.[9][10]
- **Open questions for Peter:** does Sonara intend to expose a host-level modulation system
  (which would make synth-side "CLAP host modulation" a must rather than a nice-to-have)?[29]
  How large a factory preset library is budgeted (it is repeatedly a tie-breaker)?[10][15]
  And which audience — preset-browsers or patch-builders — is the primary target, since the
  routing-depth decision splits them?[9]

## Sources

[1] https://gearspace.com/board/electronic-music-instruments-and-electronic-music-production/1242088-wavetable-synthesizers-why.html
[2] https://splice.com/blog/optimizing-serum-cpu-efficiency
[3] https://monosounds.studio/serum-2-cpu-optimization
[4] https://www.16sounds.com/blog/synthesizers-plugins-and-cpu-usage
[5] https://www.kvraudio.com/forum/viewtopic.php?t=559152
[6] https://www.kvraudio.com/forum/viewtopic.php?t=487838
[7] https://www.kvraudio.com/forum/viewtopic.php?t=628368
[8] https://tech.yahoo.com/audio/articles/ultimate-soft-synth-showdown-serum-105553312.html
[9] https://monosounds.studio/best-wavetable-synth-2026
[10] https://musictech.com/guides/buyers-guide/pigments-7-vs-absynth-6-vs-serum-2-which-super-synth-should-you-buy
[11] https://www.xferrecords.com/forums/general/serum-resizable-gui
[12] https://community.native-instruments.com/discussion/14902/super-8-gui-bug-impossible-to-use-in-ableton-live-with-a-4k-monitor
[13] https://forums.steinberg.net/t/cubase-issues-with-hidpi-and-vst3-plugins-of-some-developers/764809
[14] https://forum.vital.audio/t/1-5-1-clap-synth-ui-only-fills-half-the-window-on-hidpi-in-bitwig-macos/10162
[15] https://forum.synapse-audio.com/viewtopic.php?p=120157
[16] https://docs.native-instruments.com/ni-tech-manuals/absynth-6-user-guide/en/browser-page
[17] https://sonicbloom.net/optimise-ableton-live-12-browser
[18] https://goldmidi.com/community/threads/aliasing-quietly-wrecks-the-top-end-of-your-synths.75890
[19] https://tonalux.org/blog/blep-minblep-polyblep-antialiased-oscillators
[20] https://forum.arturia.com/t/arturia-internal-upsampling-policy-2024/2380
[21] https://www.attackmagazine.com/technique/synth-secrets/what-is-a-modulation-matrix-how-does-it-work
[22] https://dreyandersson.com/music-production-terms/modulation-matrix
[23] https://www.bitwig.com/learnings/5-things-you-can-do-with-msegs-248
[24] https://jamesm.blog/music-production/mpe-deep-dive
[25] https://gearspace.com/threads/whats-the-deal-with-mpe-synths.1385603
[26] https://lostsynapse.store/articles/laura-vs-serum-vital-and-pigments
[27] https://www.bitwig.com/polymer
[28] https://prod.fabfilter.com/forum/topic/7352/stuck-notes-in-twin-3
[29] https://synthanatomy.com/2026/09/imfmsynth-an-8-operator-0-algorithm-fm-synthesizer-with-wavetables.html

---
*Report: researcher profile, 2026-09-28. Community-consensus briefing; not a quantitative study.
Filed into the vault by librarian from the researcher's report workspace. Ranked by category
durability, deliberately not naming "best synths" — model-specific claims age fast.*
