## Log-frequency axis for plots (the EQ's curve editor, and the Compressor's sidechain filter view
## later). Maps Hz to x inside `rect` and draws the vertical grid, its labels and an optional
## piano strip. Holds no data and sends nothing, so any Control can own one.
##
## Middle C = C3 = MIDI note 60 (project convention).
class_name FreqAxis extends RefCounted

const MIN_HZ := 20.0
const MAX_HZ := 20000.0

## Labelled grid lines.
const MAJOR_HZ: Array[float] = [20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0, 20000.0]
## Faint lines in between.
const MINOR_HZ: Array[float] = [
	30.0, 40.0, 60.0, 70.0, 80.0, 90.0, 300.0, 400.0, 600.0, 700.0, 800.0, 900.0,
	3000.0, 4000.0, 6000.0, 7000.0, 8000.0, 9000.0,
]

## The plot area the axis maps into (x and width are what matter).
var rect := Rect2(0, 0, 100, 100)
var min_hz := MIN_HZ
var max_hz := MAX_HZ


func hz_to_x(hz: float) -> float:
	var t := log(clampf(hz, min_hz, max_hz) / min_hz) / log(max_hz / min_hz)
	return rect.position.x + rect.size.x * t


func x_to_hz(x: float) -> float:
	var t := clampf((x - rect.position.x) / maxf(rect.size.x, 1.0), 0.0, 1.0)
	return min_hz * pow(max_hz / min_hz, t)


## Frequency of a MIDI note (A4 = note 69 = 440 Hz).
static func note_hz(note: int) -> float:
	return 440.0 * pow(2.0, (note - 69) / 12.0)


## Note name with C3 = 60, e.g. "C3", "A#2".
static func note_name(note: int) -> String:
	const NAMES := ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
	return "%s%d" % [NAMES[posmod(note, 12)], floori(note / 12.0) - 2]


static func is_black_key(note: int) -> bool:
	return posmod(note, 12) in [1, 3, 6, 8, 10]


## "20", "500", "1k", "2.5k", "20k".
static func format_hz(hz: float) -> String:
	if hz >= 1000.0:
		var k := hz / 1000.0
		return "%dk" % int(k) if is_equal_approx(k, roundf(k)) else "%.1fk" % k
	return "%d" % int(roundf(hz))


## Vertical grid lines over `rect`, with labels along the bottom edge of the plot.
func draw_grid(ci: CanvasItem, font: Font, font_size: int, minor_color: Color, major_color: Color, label_color: Color) -> void:
	for hz in MINOR_HZ:
		var x := hz_to_x(hz)
		ci.draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), minor_color, 1.0)
	for hz in MAJOR_HZ:
		var x := hz_to_x(hz)
		ci.draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), major_color, 1.0)
		if hz <= min_hz or hz >= max_hz or font == null:
			continue
		var text := format_hz(hz)
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		ci.draw_string(font, Vector2(x - width / 2.0, rect.end.y - 3.0), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, label_color)


## A piano keyboard along `strip`, one key per semitone on the log axis (only notes inside the
## axis range), with the C keys labelled.
func draw_piano_strip(ci: CanvasItem, strip: Rect2, font: Font, font_size: int) -> void:
	var half_step := pow(2.0, 1.0 / 24.0)
	var white := Color(0.82, 0.82, 0.84, 0.9)
	var black := Color(0.1, 0.1, 0.12, 0.95)
	var seam := Color(0, 0, 0, 0.5)
	# White keys first, then black keys on top.
	for note in range(0, 128):
		var hz := note_hz(note)
		if is_black_key(note) or hz / half_step > max_hz or hz * half_step < min_hz:
			continue
		var x0 := hz_to_x(hz / half_step)
		var x1 := hz_to_x(hz * half_step)
		ci.draw_rect(Rect2(x0, strip.position.y, maxf(x1 - x0, 1.0), strip.size.y), white)
		ci.draw_line(Vector2(x0, strip.position.y), Vector2(x0, strip.end.y), seam, 1.0)
	for note in range(0, 128):
		var hz := note_hz(note)
		if not is_black_key(note) or hz / half_step > max_hz or hz * half_step < min_hz:
			continue
		var x0 := hz_to_x(hz / half_step)
		var x1 := hz_to_x(hz * half_step)
		ci.draw_rect(Rect2(x0, strip.position.y, maxf(x1 - x0, 1.0), strip.size.y * 0.62), black)
	if font == null:
		return
	for note in range(0, 128, 12):
		var hz := note_hz(note)
		if hz < min_hz or hz > max_hz:
			continue
		ci.draw_string(font, Vector2(hz_to_x(hz) + 2.0, strip.end.y - 2.0), note_name(note),
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.15, 0.15, 0.18))
