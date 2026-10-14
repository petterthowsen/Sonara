# test_grid_levels.gd
# Headless tests for GridHelper's line levels: bars thinning out when zoomed far out, levels
# fading in, and line weight following rank among the visible levels.
#
# Run: godot --headless --path Godot -s tests/test_grid_levels.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Grid levels"


func run_tests() -> void:
	_grid_script = load("res://components/GridHelper.gd")
	_test_bars_thin_out()
	_test_levels_fade_in()
	_test_weight_follows_rank()
	_test_each_tick_once()
	_test_snap_matches_visible_lines()


# Loaded at runtime: GridHelper depends on Project.gd, which names autoloads that don't resolve
# when a -s script is compiled.
var _grid_script: GDScript


func _grid(ppb: float) -> Object:
	var g: Object = _grid_script.new(960, 4, 4, 128.0)
	g.min_line_spacing = 10.0
	g.pixels_per_beat = ppb
	return g


func _bars(lines: Array) -> Array[int]:
	var out: Array[int] = []
	for l in lines:
		if l.type == _grid_script.GridLineType.BAR and l.alpha >= 1.0:
			out.append(l.bar_number)
	return out


func _test_bars_thin_out() -> void:
	# 2 px per beat: bars are 8 px apart, far under the bar threshold, so they group
	var far: Array = _grid(2.0).get_visible_grid_lines(0.0, 1000.0)
	var bars := _bars(far)
	_assert(bars.size() > 1, "far out still shows bars")
	_assert(bars[1] - bars[0] >= 4, "far out bars are grouped: %s" % str(bars.slice(0, 4)))
	_assert((bars[0] - 1) % (bars[1] - bars[0]) == 0, "groups start on bar 1, 1+n, ...")
	var near := _bars(_grid(60.0).get_visible_grid_lines(0.0, 1000.0))
	_assert(near[1] - near[0] == 1, "zoomed in every bar shows")
	var labels := 0
	for l in _grid(60.0).get_visible_grid_lines(0.0, 1000.0):
		if l.labeled:
			labels += 1
	_assert(labels > 0, "zoomed in bars are numbered")


func _test_levels_fade_in() -> void:
	# Beats appear at 10 px (alpha 0) and are at full strength by 20 px
	var lo: Array = _grid(10.0).get_visible_grid_lines(0.0, 400.0)
	var beat_alpha := -1.0
	for l in lo:
		if l.type == _grid_script.GridLineType.BEAT:
			beat_alpha = l.alpha
	_assert(is_equal_approx(beat_alpha, 0.0), "a new beat level starts invisible (%f)" % beat_alpha)
	var hi: Array = _grid(20.0).get_visible_grid_lines(0.0, 400.0)
	for l in hi:
		if l.type == _grid_script.GridLineType.BEAT:
			beat_alpha = l.alpha
	_assert(is_equal_approx(beat_alpha, 1.0), "and is fully in at twice the spacing (%f)" % beat_alpha)


func _test_weight_follows_rank() -> void:
	# Strength: finest level faintest, coarser levels stronger, bars strongest
	var lines: Array = _grid(140.0).get_visible_grid_lines(0.0, 600.0)
	var best := {}
	for l in lines:
		best[l.type] = l.weight
	_assert(best[_grid_script.GridLineType.BAR] > best[_grid_script.GridLineType.BEAT], "bars outweigh beats")
	_assert(best[_grid_script.GridLineType.BEAT] > 0.0, "beats outweigh the finest subdivision")
	var lone: Array = _grid(2.0).get_visible_grid_lines(0.0, 600.0)
	var strongest := 0.0
	for l in lone:
		strongest = maxf(strongest, l.weight)
	_assert(strongest < 0.7, "a lone bar level stays quiet (%f)" % strongest)


func _test_each_tick_once() -> void:
	for ppb in [3.0, 12.0, 30.0, 90.0, 300.0]:
		var g := _grid(ppb)
		var seen := {}
		var dup := false
		for l in g.get_visible_grid_lines(0.0, 1500.0):
			var key := int(roundf(l.x * 100.0))
			dup = dup or seen.has(key)
			seen[key] = true
		_assert(not dup, "no tick is drawn twice at %s px/beat" % ppb)


## Issue #118: the snap step is the finest level drawn with real strength; a level just
## fading in (alpha near 0) is not a snap target.
func _test_snap_matches_visible_lines() -> void:
	# 1/2 beat lines reach the 10 px threshold at 20 px/beat; they are at full strength at 40.
	var g := _grid(21.0)  # 1/2 beat at 10.5 px: fade 0.05, effectively invisible
	_assert(g.get_snap_interval() == 960, "a barely-faded-in 1/2 beat is not a snap step (%d)" % g.get_snap_interval())
	g = _grid(30.0)  # 1/2 beat at 15 px: fade 0.5
	_assert(g.get_snap_interval() == 480, "a half-faded 1/2 beat is a snap step (%d)" % g.get_snap_interval())
	# Whatever snap_ticks returns lies on a drawn line (alpha >= SNAP_MIN_FADE) or a bar.
	for ppb in [12.0, 21.0, 30.0, 45.0, 90.0, 200.0, 400.0]:
		var gg := _grid(ppb)
		var snap: int = gg.get_snap_interval()
		var lines: Array = gg.get_visible_grid_lines(0.0, 4000.0)
		var finest := 0
		for l in lines:
			if l.alpha >= _grid_script.SNAP_MIN_FADE:
				finest = maxi(finest, 1)
		var snapped: int = gg.snap_ticks(int(snap * 2.6))
		_assert(snapped == snap * 3, "rounds to nearest at %s px/beat (%d)" % [str(ppb), snapped])
		var x: float = gg.ticks_to_pixels(snapped)
		var on_line := false
		for l in lines:
			if absf(l.x - x) < 1.0 and l.alpha >= _grid_script.SNAP_MIN_FADE:
				on_line = true
		_assert(on_line or snapped % (960 * 4) == 0, "snap target is a drawn line at %s px/beat" % str(ppb))
