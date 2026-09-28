---
question: What do people generally like and dislike about commonly used effects (EQ, compressor, distortion, chorus, phaser, filters, delay, reverb) — to inform planning built-in devices for a DAW?
date: 2026-09-28
sources:
  - https://www.production-expert.com/production-expert-1/plugin-designs-why-we-love-some-and-hate-others
  - https://www.musicradar.com/music-tech/plugins/the-biggest-driver-right-now-is-people-wanting-everything-fast-predicting-the-future-evolution-of-plugin-design
  - https://blog.landr.com/skeuomorphism-plugins/
  - https://www.kvraudio.com/forum/viewtopic.php?t=541318
  - https://producerhive.com/buyer-guides/daw/are-ableton-live-stock-plugins-good/
  - https://loststoriesacademy.com/blogs-and-tutorials/abletons-native-devices-are-a-philosophy-of-music-production
  - https://buchertaudio.com/blog/five-eq-modes
  - https://mixprotege.com/forums/discussion/eq-plugin-quality/
  - https://www.kvraudio.com/forum/viewtopic.php?p=9012406
  - https://musictech.com/reviews/plug-ins/fabfilter-pro-q-4-review/
  - https://www.soundonsound.com/reviews/fabfilter-pro-q-4
  - https://www.musicradar.com/news/best-compressor-plugin
  - https://prod.fabfilter.com/products/pro-c-3-compressor-plug-in
  - https://delosdsp.com/manuals/delos-c-manual.pdf
  - https://manuals.goodhertz.com/3.13/vcme/
  - https://www.kvraudio.com/forum/viewtopic.php?t=585390
  - https://gearspace.com/threads/distortion-and-saturation-taking-over-the-plug-world.1467334/
  - https://gearspace.com/threads/im-tired-of-the-same-saturation-plugins-again-and-again-where-is-the-progress.1427877/
  - https://buchertaudio.com/blog/what-makes-saturation-musical
  - https://www.kvraudio.com/forum/viewtopic.php?t=563410
  - https://producelikeapro.com/blog/soundtoys-decapitator-grade-a-saturation/
  - https://gearspace.com/board/electronic-music-instruments-and-electronic-music-production/849872-your-favorite-chorus-plug.html
  - https://www.eventideaudio.com/forums/topic/disappointing-modfactor-chorus/
  - https://forum.kemper-amps.com/forum/thread/62271-chorus-not-very-chorusy/
  - https://gearspace.com/threads/help-me-find-a-phaser-plugin.1466697/
  - https://www.kvraudio.com/forum/viewtopic.php?t=227983
  - https://www.kvraudio.com/forum/viewtopic.php?t=581996
  - https://monosounds.studio/serum-2-filters-explained/
  - https://www.soundonsound.com/reviews/polyverse-music-filterverse
  - https://lordreverb.com/plugins/meldaproduction-mturbofilter-review/
  - https://violetrecording.com/best-delay-plugins/
  - https://www.soundonsound.com/techniques/six-practical-uses-delay
  - https://blog.dubspot.com/best-reverb-plugins-2026
  - https://www.kvraudio.com/forum/viewtopic.php?t=460183
  - https://vi-control.net/community/threads/comparing-reverbs-valhalla-waves-relab-reverb-foundry.117008/
confidence: medium
open_questions:
  - Forum/review evidence skews to experienced producers (Gearspace/KVR/SOS); mass-market beginners are sampled less and want different things.
  - No hard usage data — this is stated preference, not measured behaviour.
  - Preference by genre (EDM vs mixing/mastering vs guitar) is only partly separable from the sources.
---

# What users like and dislike about common effects — briefing for built-in DAW device planning

## Answer (the short version)

Across every device category, the same three axes decide whether people love or hate a plugin:

1. **Speed vs. depth.** The dominant trend is toward *fewer controls, faster results* — "give them one dial and a result they want" — with depth hidden behind progressive disclosure. But too little control produces "no sweet spots," which is a distinct, loudly-voiced complaint. The winning shape is **simple by default, deep on demand**.
2. **Understandability / honest feedback.** People dislike tools they can't reason about. They reward useful metering (gain-reduction history, analyser, per-band solo, detector audition), discoverable controls, and sane defaults — and they punish skeuomorphic knobs, buried menus, and confusing control conventions.
3. **Signal quality done right.** Aliasing/oversampling, "digital harshness" from undeclared saturation, and noise are the recurring technical grievances. CPU efficiency and stability are cited as decisive, often above sound quality, for builders like FabFilter.

Device-specific "must-haves" that emerged repeatedly:

| Device | What users ask for | What they hate |
| --- | --- | --- |
| EQ | Fast workflow, spectrum analyser, dynamic + **spectral** bands, mid/side, band solo, slopes, auto-gain, natural/linear-phase options | Cluttered UI, mixed corrective+creative on one curve, thin cuts, CPU cost, tiny controls |
| Compressor | Clear visualisation of *when/why/how*, measured auto-gain, auto-release, sidechain + sidechain EQ, detector audition, M/S, multiple styles sharing one layout | Opaque controls, backwards 1176-style knobs, intrusive preset managers, too much baked-in colour |
| Distortion / saturation | Character/variety, level-dependent behaviour, EQ pre/post shaping, oversampling control | Aliasing with no OS switch, static "painted-on" waveshaping, 2–5 kHz harshness, oversaturation on every bus |
| Chorus | Lush-but-controllable, vintage models, wet-path low-pass, delay-time control, mono-compatible | Too much/obnoxious wobble OR too weak, slapback artefacts, noise, no wet filtering |
| Phaser | Sweet spots, stage-count choices, **manual/automatable sweep**, envelope follower, HP/LP, long rates | "No sweet spots," LFO-locked phase, static presets |
| Filters | Many types, integrated drive/saturation, **resonance compensation** (bass stays fat), serial/parallel routing, modulation | Clean digital filters going thin/nasty at high resonance, overwhelming UI, no onboarding/tooltips, CPU |
| Delay | Tempo sync + note divisions, feedback-path filters, modulation, ping-pong/width, ducking, character | Needing mental arithmetic for divisions, hiss/noise, sterile repeats, mud with no filtering |
| Reverb | Character options, decay-rate EQ, ducking, IR import, natural *and* effect modes | Stock reverbs "weak," metallic/resonant artefacts, "glued-on" rather than believable space |

---

## 1. Cross-cutting UX and DSP lessons

### 1a. Simplicity and decision fatigue
- The clearest market signal: *"The biggest driver right now is people wanting everything fast... if you give them a Manley Massive Passive EQ, they're not touching it,"* and a pro-designed plugin's goal is *"as few choices as possible but in a powerful way"* — one dial that gives a result you'd want again. ([MusicRadar](https://www.musicradar.com/music-tech/plugins/the-biggest-driver-right-now-is-people-wanting-everything-fast-predicting-the-future-evolution-of-plugin-design))
- Reduced cognitive load is the top criterion in a cited study of plugin evaluation; current interfaces feel "overwhelming and mentally exhausting," especially to beginners. ([MusicRadar](https://www.musicradar.com/music-tech/plugins/the-biggest-driver-right-now-is-people-wanting-everything-fast-predicting-the-future-evolution-of-plugin-design))
- Ableton's stock devices are widely praised *because* they are functional building blocks, not vintage emulations: simple, uniform, clearly purposed, "each one has a clear purpose" — and unified UI across devices makes the whole set faster to learn. ([Lost Stories Academy](https://loststoriesacademy.com/blogs-and-tutorials/abletons-native-devices-are-a-philosophy-of-music-production); [ProducerHive](https://producerhive.com/buyer-guides/daw/are-ableton-live-stock-plugins-good/))
- **Counterpoint worth planning for:** simplicity without sweet spots is a real failure mode. A user hunting a phaser specifically complained the stock Logic phaser "just awful... seems that it has no sweet spots," and asked for slow rates, HP/LP, envelope follower, depth/rate. ([Gearspace](https://gearspace.com/threads/help-me-find-a-phaser-plugin.1466697/))

### 1b. Skeuomorphism vs. flat/functional UI
- Rotary knobs are poorly suited to mouse and touch: "the rotating motion is not natural or ergonomic in digital environments," since users actually drag vertically. ([Interface design for audio production — grid-based control, AAU thesis on exa.ai](https://exa.ai/library/publication/dy0584dfk1f))
- Skeuomorphic plugin design "subconsciously pushes you in a particular direction" and can compromise usability, especially for original (non-emulation) designs; interfaces that mirror hardware front panels also convince users they hear "warmth" that may not exist. ([LANDR](https://blog.landr.com/skeuomorphism-plugins/))
- Practical control advice for developers: group related controls, don't use a rigid grid, make hitboxes bigger than the visual control, support shift-for-fine-adjust, show value readouts, keep mouse-over behaviour consistent, and lay controls out in the order people adjust them. ([KVR DSP forum](https://www.kvraudio.com/forum/viewtopic.php?t=541318))
- Context matters: for graded hardware emulations, faithful layouts help experienced users; for your *own* designs, flat/functional wins. The MOD Audio community explicitly asked for an optional "simple/node" view *alongside* skeuomorphic skins — the moderator's summary: keep both, default to functional. ([MOD Audio forum](https://forum.mod.audio/t/state-of-the-current-plugin-ui-ux/7878))

### 1c. Useful visual feedback and metering
- "Rich visual feedback... unless it tells you something useful, it's just pretty pictures." Praised specifics: gain-reduction **history plots** ("one of the most significant ways plugins are demonstrably better than their hardware counterparts"), a piano keyboard over EQ frequencies, slower meter ballistics that match perception, and resizable/compact/full-screen modes (e.g. FabFilter C2 compact mode, Sonnox "Ears Only"). ([Production Expert](https://www.production-expert.com/production-expert-1/plugin-designs-why-we-love-some-and-hate-others))
- Inter-plugin communication (an "Instance List" letting one plugin window edit all its instances; cross-track heat maps) is called out as a genuine workflow gain. ([Production Expert](https://www.production-expert.com/production-expert-1/plugin-designs-why-we-love-some-and-hate-others))

### 1d. Presets, CPU, stability
- Good factory presets matter: "A great delay lets you audition a usable starting point in seconds and then tweak, rather than building every patch from scratch." ([Violet Recording](https://violetrecording.com/best-delay-plugins/))
- But preset management is a friction point: a top compressor was dinged for an "intrusive preset manager." ([MusicRadar](https://www.musicradar.com/news/best-compressor-plugin))
- CPU efficiency and long-term stability are cited as decisive advantages, often more than sound: FabFilter is praised as "the most stable, issues free, CPU friendly, and long term updated plugins I have," and its EQ is "extremely CPU-optimized." ([KVR](https://www.kvraudio.com/forum/viewtopic.php?p=9012406); [FabFilter Pro-Q 4](https://www.fabfilter.com/products/pro-q-4-equalizer-plug-in))
- The reverse — CPU cost and scaling problems at 4K — is a common complaint (e.g. Molot "UI at 4K on Windows scales awkwardly"; Filterverse "CPU-intensive... use it for sound design and then resample"). ([Blogarama review](https://www.blogarama.com/arts-and-entertainment-blogs/1426833-jeff-zaret-blog/80724316-molot-review-week-verdict-for-2026-tech-side-workflows); [Sounds of Revolution](https://www.sounds-of-revolution.com/review-polyverse-filterverse/))

### 1e. Aliasing / oversampling (a live expectation)
- A stated 2024 expectation: *"In 2024, really good aliasing suppression should be standard... I'm not buying plugins anymore that are limited to 2x or 4x."* ([Gearspace](https://gearspace.com/threads/im-tired-of-the-same-saturation-plugins-again-and-again-where-is-the-progress.1427877/))
- **Counterevidence (important for planning):** oversampling is not automatically better. Extra processing "can alter the signal through its reconstruction filters"; some devs oversample only the saturation stage to save CPU and note the crossover difference "doesn't do any harm"; and some users genuinely *prefer* the sound of aliased/1× distortion. So: offer the option, don't force it. ([Gearspace](https://gearspace.com/threads/distortion-and-saturation-taking-over-the-plug-world.1467334/); [FabFilter forum](https://prod.fabfilter.com/forum/topic/1738/rumoured-aliasing-in-your-plugins))
- Technical framing to design against: harmonics generated above Nyquist fold back into the audible band — a 10 kHz source's 3rd harmonic at 30 kHz can reappear at 14 kHz at 44.1 kHz, landing in the ear's most sensitive 2–4 kHz region and causing fatigue. ([KVR](https://www.kvraudio.com/forum/viewtopic.php?t=585390))

---

## 2. EQ

**Likes**
- **Workflow is king.** FabFilter Pro-Q is the de-facto standard and is praised above all for workflow, UI, and stability — explicitly not for "sound": "it doesn't have a sound... what makes ProQ above the crowd: workflow, features, GUI, coding." ([KVR](https://www.kvraudio.com/forum/viewtopic.php?p=9012406))
- Feature checklist users reward: spectrum analyser (hideable), **dynamic EQ**, mid/side and per-band channel targeting, band solo, wide slope control (continuous up to 96 dB/oct, brickwall), high band count, Auto Gain, Natural/Linear phase, EQ Match, **Spectrum Grab**, resizable/full-screen/scaling, and now **spectral dynamics** for resonance handling and de-essing. ([MusicTech Pro-Q 4 review](https://musictech.com/reviews/plug-ins/fabfilter-pro-q-4-review/); [SOS Pro-Q 4](https://www.soundonsound.com/reviews/fabfilter-pro-q-4))
- Workflow accelerators users actively like: **EQ Sketch** (draw the curve, refine after) and the **Instance List** (edit all instances from one window, with live thumbnails). One reviewer: "in a matter of seconds, you can draw in the basic frequency curve." ([MusicTech](https://musictech.com/reviews/plug-ins/fabfilter-pro-q-4-review/); [SOS](https://www.soundonsound.com/reviews/fabfilter-pro-q-4))
- Surgical vs. character mental model: users separate a "Swiss Army knife" EQ for cuts (many sweepable bands, steep HP/LP) from colour EQs for boosts (Pultec-style). Most also say clean parametric EQs sound essentially the same and choose on *non-sound* factors: CPU, GUI, metering, band-solo, slope range, M/S, mono-maker, tilt, hardware mapping. ([Mix Protégé](https://mixprotege.com/forums/discussion/eq-plugin-quality/))

**Dislikes**
- Cramming corrective cuts and creative boosts onto one curve "makes the whole picture hard to read"; bands clutter the UI and "slow down the workflow significantly." ([Buchert Audio](https://buchertaudio.com/blog/five-eq-modes); [KVR](https://www.kvraudio.com/forum/viewtopic.php?p=9012406))
- Stock EQs are seen as having "very little character" and, in some cases, failing to cut fully (high-pass slope surprises). ([Modern Mixing](https://modernmixing.com/blog/2014/06/19/plugins-do-make-a-difference/); [Mix Protégé](https://mixprotege.com/forums/discussion/eq-plugin-quality/))
- Expert panes with "minuscule controls"; cost ($179 is "out of reach" for many); one reviewer still reaches for Soothe2 for broadband resonance work — i.e. spectral EQ is a bonus, not a full replacement. ([SOS](https://www.soundonsound.com/reviews/fabfilter-pro-q-4); [MusicTech](https://musictech.com/reviews/plug-ins/fabfilter-pro-q-4-review/))

**Design directions suggested by sources (partly advocacy, treat with care):** layer-based EQ separating corrective and shaping; phase layers; harmonic/overtone layers; perception-tuned macro controls (tilt/weight/presence); gentler curves and emphasis on interaction for mix-bus use. ([Buchert Audio](https://buchertaudio.com/blog/five-eq-modes)) *Note: this is a vendor blog arguing for its own product architecture — useful as a hypothesis, not established user consensus.*

---

## 3. Compressor

**Likes**
- **Making compression legible.** The most-praised modern trait is an interface that shows exactly what's happening: "the large animated level/knee display visualizes exactly when, why and how compression is applied," plus peak/loudness meters and a circular sidechain meter that makes threshold-finding trivial. ([FabFilter Pro-C 3](https://prod.fabfilter.com/products/pro-c-3-compressor-plug-in))
- **Convenience features users reward:** intelligent/measured auto-gain (RMS-matched, "makeup is measured, not estimated"), auto-release (program-adaptive), auto-threshold, variable knee, hold, lookahead with host delay compensation, M/S, stereo link control, a Mix knob for parallel/NY compression with bit-exact dry, and multiple compression styles sharing one knob layout so auditioning never interrupts the workflow. ([FabFilter Pro-C 3](https://prod.fabfilter.com/products/pro-c-3-compressor-plug-in); [Janski](https://janskimusic.com/plugins/janski-compressor/); [DELOS C manual](https://delosdsp.com/manuals/delos-c-manual.pdf))
- **Sidechain done properly:** external sidechain with its own low-cut/high-cut/bell shaping, an Off/Listen/On audition stage, and M/S or stereo detector source. "Listen" so you can hear the trigger is repeatedly provided by serious designs. ([DELOS C](https://delosdsp.com/manuals/delos-c-manual.pdf); [ZL Audio](https://zl-audio.github.io/plugins/zlcompressor/manual/); [Goodhertz VCME](https://manuals.goodhertz.com/3.13/vcme/))
- Metering specifics: circular GR dial with peak-hold, split input/output waveform with a "GR reflection line," post-process clipper. ([DELOS C](https://delosdsp.com/manuals/delos-c-manual.pdf))

**Dislikes**
- Opaque controls; the notorious **backwards attack/release** on 1176-style plugins "left many bewildered" — and it is kept anyway for authenticity. ([Production Expert](https://www.production-expert.com/production-expert-1/plugin-designs-why-we-love-some-and-hate-others))
- Too much baked-in colour; some "may not want the compressor to colour the sound this much." ([MusicRadar](https://www.musicradar.com/news/best-compressor-plugin))
- Intrusive preset management; occasional UI-scaling friction. ([MusicRadar](https://www.musicradar.com/news/best-compressor-plugin))

**Design directions:** assume users want (a) to *see* gain reduction history and *hear* the detector, (b) auto-gain/auto-release as defaults, (c) several characters behind one stable layout, (d) a sidechain filter + audition path. Treat "clean" and "coloured" as separate devices or clearly separable modes.

---

## 4. Distortion / Saturation

**Likes**
- Character and variety: five modelled styles + Tone knob + a "Punish" over-the-top mode made Decapitator a bestseller. ([Produce Like A Pro](https://producelikeapro.com/blog/soundtoys-decapitator-grade-a-saturation/))
- **Level- and performance-dependent behaviour** is what separates "musical" from "mechanical": harmonics should grow dynamically with the input and shift balance with drive, rather than a fixed transfer curve. ([Buchert Audio](https://buchertaudio.com/blog/what-makes-saturation-musical))
- Perceptual shaping matters — a flat harmonic profile sounds harsh because 2–5 kHz is perceptually loudest; even vs odd harmonics map to "warm" vs "edgy." Tools that account for Fletcher-Munson perception, and those offering **band-specific** saturation, win praise. ([Buchert Audio](https://buchertaudio.com/blog/what-makes-saturation-musical); [Gearspace](https://gearspace.com/threads/distortion-and-saturation-taking-over-the-plug-world.1467334/))
- Practical workflow tip echoed by users: EQ before and after distortion, because real drive circuits have EQ curves baked in. ([Gearspace](https://gearspace.com/threads/distortion-and-saturation-taking-over-the-plug-world.1467334/))

**Dislikes**
- **Aliasing.** Decapitator is the famous example; forum tests show it, though "at an inaudible level" per some, and cumulative effects are debated. The recurring demand is a user-visible oversampling control (and 8×/16× modes). ([Produce Like A Pro](https://producelikeapro.com/blog/soundtoys-decapitator-grade-a-saturation/); [Gearspace](https://gearspace.com/threads/distortion-and-saturation-taking-over-the-plug-world.1467334/))
- Static waveshaping that "sounds like it was painted on top of a recording" rather than being part of it. ([Buchert Audio](https://buchertaudio.com/blog/what-makes-saturation-musical))
- **Oversaturation culture.** "Producers adding in saturation to the point where it's just audio haze... muddling up the response," and skepticism that blanket console/tape saturation on every bus actually helps. ([KVR](https://www.kvraudio.com/forum/viewtopic.php?t=563410))
- Samey, marketing-driven releases: "tired of the same saturation plugins again and again"; the honest view that most new saturation tools "sell convenience" — essentially presets you could build from distortion + EQ. ([Gearspace](https://gearspace.com/threads/im-tired-of-the-same-saturation-plugins-again-and-again-where-is-the-progress.1427877/))

---

## 5. Chorus

**Likes**
- Lush but controllable; vintage models (Boss CE-1/CE-2, Roland Dimension D, Juno/Sylenth choruses, TAL free chorus, Valhalla Übermod). "I usually set the width kinda high, along with the depth and rate kinda low." ([Gearspace](https://gearspace.com/board/electronic-music-instruments-and-electronic-music-production/849872-your-favorite-chorus-plug.html))
- **Wet-path low-pass/tone control** is explicitly identified as the source of "analog warmth," and **delay-time control** as essential to dial in the right amount of warble (down toward ~4 ms flirts with flanging). ([Eventide forum](https://www.eventideaudio.com/forums/topic/disappointing-modfactor-chorus/))
- Multi-voice topologies (Dimension-style two-voice out-of-phase) are prized; making the algorithm's structure understandable helps users tweak. ([Eventide forum](https://www.eventideaudio.com/forums/topic/disappointing-modfactor-chorus/))

**Dislikes**
- **The two-sided failure:** either "obnoxiously wobbly and fizzy," too much character, slapback artefacts from too-long delay times — *or* too subtle/weak ("the Chorus on the KPA very weak... can't quite get there"). ([Gearspace](https://gearspace.com/board/electronic-music-instruments-and-electronic-music-production/849872-your-favorite-chorus-plug.html); [Eventide](https://www.eventideaudio.com/forums/topic/disappointing-modfactor-chorus/); [Kemper forum](https://forum.kemper-amps.com/forum/thread/62271-chorus-not-very-chorusy/))
- Noise is a real (hardware-derived) complaint; and mono-only users get an "anemic" version if the algorithm assumes stereo. ([Gearspace JX-3P](https://gearspace.com/board/electronic-music-instruments-and-electronic-music-production/763922-noisy-roland-jx3p-chorus-normal.html); [Eventide](https://www.eventideaudio.com/forums/topic/disappointing-modfactor-chorus/))
- **Design implication:** users want ONE control that can swing from subtle to extreme without artefacts, and they want it to sound good in mono.

---

## 6. Phaser

**Likes**
- Classic emulations with identifiable character (MXR Phase 90/95, Small Stone, Mu-Tron Bi-Phase) and *sweet spots*; stage-count switching (2/4/6/12) changes the effect meaningfully and is valued. ([The Gear Forum](https://thegearforum.com/threads/let%E2%80%99s-talk-phasers.4729/); [Gearspace](https://gearspace.com/threads/help-me-find-a-phaser-plugin.1466697/))
- A strongly-repeated request: **manual, MIDI-controllable, automatable sweep** instead of an LFO that dictates the phase position — "The only thing most phasers can't do is a manual sweep... I'm never satisfied with just having the plugin dictate where in phase it wants to be." ([KVR Sanford Phaser thread](https://www.kvraudio.com/forum/viewtopic.php?t=227983))
- Wanted extras: envelope follower, HP/LP to place the effect in the mix, long rates (1–20 s), light resonance use. ([Gearspace](https://gearspace.com/threads/help-me-find-a-phaser-plugin.1466697/))
- Stereo/quad options and antiphase modulation are liked; Valhalla Delay's built-in phasers get cult praise. ([KVR](https://www.kvraudio.com/forum/viewtopic.php?t=581996))

**Dislikes**
- "No sweet spots" stock phasers (Logic called out); phasers that only sound like themselves when you wanted flanging; complexity without payoff. ([Gearspace](https://gearspace.com/threads/help-me-find-a-phaser-plugin.1466697/))
- Under-the-radar quality tools go unnoticed — a reminder that discoverability/presets matter as much as DSP.

---

## 7. Filters

**Likes**
- Many filter types + **non-linearity/drive built in**: "Most filters in this collection are non-linear... each filter model sounds different according to the level of audio pushed into it," and users are invited to drive them on purpose. ([Filterverse manual](https://polyversemusic.com/downloads/manuals/Filterverse%20Manual.pdf))
- **Resonance compensation** — bass staying fat as resonance climbs — is singled out as doing "real work." ([LordReverb MTurboFilter review](https://lordreverb.com/plugins/meldaproduction-mturbofilter-review/))
- Routing flexibility: serial/parallel/hybrid slots, per-oscillator assignment (Serum 2), which changed users' bass patches more than new filter types did. ([Serum 2 filters — Monosounds](https://monosounds.studio/serum-2-filters-explained/))
- The exact complaint serum-1-era users had is instructive: "turn up resonance on a digital 24 dB low pass and the low end goes thin while the resonant peak gets nasty." Analog-style types "fix precisely that." ([Monosounds](https://monosounds.studio/serum-2-filters-explained/))
- Good presets + educational manual praised (Filterverse). ([SOS Filterverse](https://www.soundonsound.com/reviews/polyverse-music-filterverse))

**Dislikes**
- Overwhelm and steep learning curve; CPU spikes with heavy chains/high quality; missing **in-plugin tooltips/onboarding** ("The modular designer scripting language has no in-plugin tutorial... documentation feels like it was written for engineers, not producers"). ([BPP Filterverse](https://bedroomproducersblog.com/2025/09/24/filterverse-review/); [LordReverb](https://lordreverb.com/plugins/meldaproduction-mturbofilter-review/))
- No real-time visual feedback on routing/topology ("You can hear what's happening. Seeing it requires more mental modelling than it should"). ([LordReverb](https://lordreverb.com/plugins/meldaproduction-mturbofilter-review/))
- Self-oscillation is loved but needs guarding ("Be careful with this feature!"); switching from a saturating filter to a linear one can spike levels. ([Filterverse manual](https://polyversemusic.com/downloads/manuals/Filterverse%20Manual.pdf))

---

## 8. Delay

**Likes / must-haves (near-universal)**
- **Tempo sync with easy note divisions** (dotted-eighth, triplet, straight) — "non-negotiable for modern production... you want to switch between divisions without doing maths." ([Violet Recording](https://violetrecording.com/best-delay-plugins/))
- **Filtering in the feedback path** — "the single biggest reason delays turn a mix to mud"; HP ~120–250 Hz, LP ~5–10 kHz on vocal delays. ([Violet Recording](https://violetrecording.com/best-delay-plugins/); [SOS](https://www.soundonsound.com/techniques/six-practical-uses-delay?amp=))
- Modulation (anti-static repeats), ping-pong/stereo width, **ducking**, character models (tape/BBD darkening repeats), and presets that give a usable starting point fast. ([Violet Recording](https://violetrecording.com/best-delay-plugins/); [Output](https://output.com/blog/best-delay-plugins))
- Workflow: tap-tempo pad, ms/BPM toggle, low CPU, "quickest path from idea to print." ([Waves H-Delay review](https://www.wavespluginreviews.com/waves-delay-audio-plugins/waves-h-delay-hybrid-delay-plugin-review/))

**Dislikes**
- Hiss/noise when engaging "analog" modes (H-Delay's analog knob at certain settings). ([Waves H-Delay review](https://www.wavespluginreviews.com/waves-delay-audio-plugins/waves-h-delay-hybrid-delay-plugin-review/))
- Division UX failures: Timeless 3's delay-time knob with a hidden division tab was widely disliked versus "normal knobs like Valhalla and Echoboy." ([KVR](https://www.kvraudio.com/forum/viewtopic.php?p=9012406))
- Sterile, bright, full-frequency repeats that compete with the source instead of sitting behind it. ([SOS](https://www.soundonsound.com/techniques/six-practical-uses-delay?amp=))

**Send-vs-insert:** sources consistently recommend a send/aux, 100% wet, automate the send — worth supporting natively. ([SOS](https://www.soundonsound.com/techniques/six-practical-uses-delay?amp=))

---

## 9. Reverb

**Likes**
- Character over purity for many: Valhalla VintageVerb's hardware-inspired modes at $50 are the most-recommended value pick; Eventide Blackhole for huge creative tails. ([Dubspot 2026](https://blog.dubspot.com/best-reverb-plugins-2026))
- Pro-R 2's **Decay Rate EQ** ("shape decay time across the frequency spectrum using parametric EQ bands... feels intuitive and musical"), plus ducking, a Thickness knob, Freeze, and **IR import** bridging algorithmic and convolution. ([Dubspot](https://blog.dubspot.com/best-reverb-plugins-2026))
- Long-term free updates and low prices build fierce loyalty (Valhalla). ([KVR](https://www.kvraudio.com/forum/viewtopic.php?t=460183))

**Dislikes**
- **Stock DAW reverbs are a known weak point** — a common reason users buy third-party ("the reverb in Bitwig... isn't all that great"). ([KVR Valhalla thread](https://www.kvraudio.com/forum/viewtopic.php?t=460183)) *This is directly relevant: a strong built-in reverb is a competitive wedge.*
- Metallic / standing-wave artefacts (VVV "can sound a bit metallic"), and "glued to the sound" tails that don't create a believable space vs. dedicated engines (HD Cart, Sonsig praised instead). ([KVR](https://www.kvraudio.com/forum/viewtopic.php?t=460183); [VI-Control](https://vi-control.net/community/threads/comparing-reverbs-valhalla-waves-relab-reverb-foundry.117008/))
- Heavily-coloured verbs that "imprint their own sound" are loved by some, hated by others — argues for offering multiple distinct algorithms rather than one. ([KVR](https://www.kvraudio.com/forum/viewtopic.php?t=460183))

---

## Bottom line for planning

- **Default to fast and legible; make depth optional.** Ship preset-driven, low-cognitive-load front panels with an "expert" pane (FabFilter-style progressive disclosure) rather than either extreme.
- **Invest in feedback and metering** — GR history, detector audition, analyser with band solo, piano-key overlay, live transfer curves. These are repeatedly cited as the concrete ways software beats hardware.
- **Non-negotiables per device:** tempo-sync + feedback filters + ducking (delay); wet-path LPF + delay-time + mono-safe staging (chorus); manual/automatable sweep + stage options (phaser); resonance compensation + drive (filter); measured auto-gain + sidechain EQ + audition (compressor); dynamic/spectral bands + M/S + band solo (EQ); level-dependent, perceptually-shaped saturation with a visible OS option (distortion); multiple believable algorithms + decay-rate EQ + IR import (reverb).
- **Engineer the signal path for clean-over-loud:** declarable/optional oversampling, no hidden noise, CPU-conscious algorithms.
- **A genuinely good built-in reverb (and chorus/phaser, both often called out as weak stock items) buys credibility** for the whole stock suite.

---

## Counterevidence & gaps

- **Sample bias.** The vivid "I want less" evidence comes from experienced-user forums (Gearspace, KVR) and pro reviews (SOS, MusicRadar); the "give me simple" evidence comes from developer interviews and beginner-facing outlets. Both are real, but they represent different populations. A stock device suite likely needs to serve both — which is exactly the "simple surface, deep core" synthesis above, not a contradiction.
- **Some sources are vendor blogs** arguing for their own architecture (Buchert Audio on layered EQ and perceptual saturation). Their technical claims (Fletcher-Munson sensitivity, even/odd harmonics) are mainstream, but the specific product prescriptions are marketing. Marked as such above.
- **Aliasing is genuinely contested** within the community — some call it inaudible in context; some prefer the sound. Treat "aliasing is always bad" as a hypothesis, not a fact.
- **No quantitative data.** This brief is stated preference and opinion; there is no usage telemetry. Genre-specific optimisation (EDM vs. mixing/mastering vs. guitar) is only partly separable from the evidence.
- **Not investigated here:** built-in *instruments* (synths/samplers), modulation matrix conventions, MIDI/automation UX, and platform/licensing constraints (CLAP/VST3/AU) — relevant to a DAW roadmap but outside the question asked.