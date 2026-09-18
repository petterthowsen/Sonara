# Code Style & Rules

1. Files should never be more than 1000 lines.
2. DRY: Extract common logic into utility functions
3. Encapsulate behavior inside classes/structs, expose intent via methods, and keep collaborators explicit.
4. KISS: Prefer simple boring solutions over clever tricks - especially hacky workarounds.
6. Fail fast and ensure transparency (logging etc).

## Gathering Documentation

You can get docs via context7:
- `/prokopyl/clack` for clack (clap library)
- `/websites/rs_dasp_0_11_0_dasp` for DASP library
- `/websites/rs_signalsmith-dsp_0_0_2_signalsmith_dsp` for Signalsmith DSP library
- `/websites/llm-docs_ams3_cdn_digitaloceanspaces_godot_4_2_2` for Godot Engine
- `/henquist/rubato` for rubato audio resampler
- `/pdeljanov/symphonia` for symphonia audio decoder

Full Source code for clack is also available via ../clack
