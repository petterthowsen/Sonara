---
trigger: model_decision
description: When working on Godot UI App
globs: Godot/**/*.gd
---

# Godot Architecture

## Editor.gd
Entry-point is editor/Editor.gd and tscn file and initializes together a series of major UI loosely-coupled self-contained systems: Arranger, Mixer, Clip Editor etc.

## Data model layer
data/ contains self-synchronizing (via osc) data models (Project, Track, Channel, Clip, ClipInstance etc.)

## Components
in ./components A set of small reusable custom UI controls such as Meters, Sliders, RotaryKnobs etc.


## OSC

AudioEngineOSC.gd is a Low-level OSC transport class with `send` and `listen` interface.


## Lifecycle and OSC syncing
1. Editor.gd initializes a `Project`
2. Project establishes connection to audio engine via AudioEngineOSC.
3. Project.create_track and similar methods call OSC and emit signals
4. Engine > Godot: UI listens to project/track/channel/clip signals and update UI
5. Godot > Engine: UI callbacks call set_[prop] setters on data objects to auto-sync to audio enine.