# test_timeline_clip_render_inset.gd
# A clip draws its body (rounded stylebox border) and header band itself; the note/waveform
# renderer is a child, so its drawing paints over the parent. At low track heights the notes used
# to cover the clip's 1px border because the renderer spanned the whole rect. It must instead sit
# inside the border and below the header band.
#
# Run: godot --headless --path Godot -s tests/test_timeline_clip_render_inset.gd -- --test
extends TestBase

const CLIP_SCENE := "res://arranger/timeline/clip/TimelineClip.tscn"


## Minimal stand-in for Timeline: only ticks_to_pixels is used to lay the clip out.
class FakeTimeline:
	var grid_helper = null

	func ticks_to_pixels(ticks: int) -> float:
		return float(ticks) * 0.1


func suite_name() -> String:
	return "TimelineClip renderer inset"


func run_tests() -> void:
	var clip_script: GDScript = load("res://data/Clip.gd")
	var instance_script: GDScript = load("res://data/ClipInstance.gd")

	var clip = clip_script.new()
	clip.type = clip_script.ClipType.MIDI
	var instance = instance_script.new()
	instance.clip = clip
	instance.duration_ticks = 3840

	var ui: Control = (load(CLIP_SCENE) as PackedScene).instantiate()
	get_root().add_child(ui)
	ui.custom_minimum_size = Vector2(384, 30)
	ui.size = Vector2(384, 30)
	ui.bind_to_clip_instance(instance, FakeTimeline.new())
	await process_frame

	var renderer: Control = ui.get("clip_renderer")
	var header: float = ui.get("header_height")
	_assert(renderer.position.x >= 1.0, "renderer starts inside the left border (x=%.1f)" % renderer.position.x)
	_assert(renderer.position.y >= header, "renderer starts below the header band (y=%.1f, header=%.1f)" % [renderer.position.y, header])
	_assert(renderer.position.x + renderer.size.x <= ui.size.x - 1.0 + 0.01, "renderer ends inside the right border")
	_assert(renderer.position.y + renderer.size.y <= ui.size.y - 1.0 + 0.01, "renderer ends inside the bottom border (bottom=%.1f, clip=%.1f)" % [renderer.position.y + renderer.size.y, ui.size.y])

	ui.queue_free()
