@tool
## App-wide colour access. Almost every colour comes from the generated theme (spec 024): read a
## palette role with `role(&"accent_primary")`. The constants below are the few fixed values the
## theme builder uses and that must not follow the accent (meter warning, clip and peak hold).
class_name UiColors extends RefCounted

## The meter palette. `METER_LOW` is the legacy "safe" colour of the old mixer meter; new meters
## use the `accent_primary` role for it.
const METER_LOW := Color(0.728, 0.8, 0.08)
const METER_WARN := Color(0.8, 0.416, 0.08)
const METER_CLIP := Color(0.8, 0.08, 0.08)
const METER_BG := Color(0.07, 0.07, 0.07)
const METER_HOLD := Color(0.96, 0.96, 0.96)


## A palette role (`Sonara/colors/<name>` in the project theme), e.g. `&"accent_primary"`,
## `&"solo"`, `&"border_selected"`. Reads the project theme on every call, so cache the result
## and refresh it on `NOTIFICATION_THEME_CHANGED` instead of calling this from a draw loop.
## Returns magenta for an unknown role, so a typo is visible.
static func role(name: StringName) -> Color:
	var theme := ThemeDB.get_project_theme()
	if theme != null and theme.has_color(name, &"Sonara"):
		return theme.get_color(name, &"Sonara")
	push_warning("UiColors.role: unknown role '%s'" % name)
	return Color.MAGENTA
