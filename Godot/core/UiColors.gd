## App-wide colour tokens. New components default to these; the existing controls still carry
## their own defaults until the theme follow-up (spec 015 §2.6).
class_name UiColors extends RefCounted

## Theme primary, the mixer fader's fill.
const PRIMARY := Color("#624d99")
## Secondary accent (the teal `alt_fill_color` in MixerChannel).
const PRIMARY_ALT := Color(0.21, 0.85, 0.62)
const TRACK_BG := Color(0.07, 0.07, 0.07)
const HANDLE := Color.WHITE_SMOKE

## The mixer strip's meter palette. `METER_LOW` is the legacy "safe" colour; new meters use
## PRIMARY for it.
const METER_LOW := Color(0.728, 0.8, 0.08)
const METER_WARN := Color(0.8, 0.416, 0.08)
const METER_CLIP := Color(0.8, 0.08, 0.08)
const METER_BG := TRACK_BG
const METER_HOLD := Color(0.96, 0.96, 0.96)
