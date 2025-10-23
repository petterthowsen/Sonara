---
trigger: always_on
---

# Overview

Sonara is a Linux-First DAW built using a Rust Audio Engine and Godot Front End.

Audio engine is in ./Engine while the godot project is in ./Godot

see ./Engine/README.md for details on the rust side.

OSC is used for communication between backend audio and godot front end.

## Conventions

- Middle C = C3 = Midi #60
- 960 PPQ standard