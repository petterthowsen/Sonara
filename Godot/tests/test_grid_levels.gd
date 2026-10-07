# test_grid_levels.gd
# Headless tests for GridHelper's line levels: bars thinning out when zoomed far out, levels
# fading in, and line weight following rank among the visible levels.
#
# Run: godot --headless --path Godot -s tests/test_grid_levels.gd -- --test
extends TestBase


func suite_name() -> String:
	return "Grid levels"


func run_tests() -> void:
	_test_bars_thin_out()
	_test_levels_fade_in()
	_test_weight_follows_rank()
	_test_each_tick_once()


func _grid(ppb: float) -> GridHelper:
	var g := GridHelper.new(960, 4, 4, 128.0)
	g.min_line_spacing = 10.0
	g.pixels_per_beat = ppb
	return g


func _bars(lines: Array) -> Array[int]:
	var out: Array[int] = []
	for l in lines:
		if l.type == GridHelper.GridLineType.BAR and l.alpha >= 1.0:
			out.append(l.bar_number)
	return out


func _test_bars_thin_out() -> void:
	# 2 px per beat: bars are 8 px apart, far under the bar threshold, so they group
	var far := _grid(2.0).get_visible_grid_lines(0.0, 1000.0)
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
	var lo := _grid(10.0).get_visible_grid_lines(0.0, 400.0)
	var beat_alpha := -1.0
	for l in lo:
		if l.type == GridHelper.GridLineType.BEAT:
			beat_alpha = l.alpha
	_assert(is_equal_approx(beat_alpha, 0.0), "a new beat level starts invisible (%f)" % beat_alpha)
	var hi := _grid(20.0).get_visible_grid_lines(0.0, 400.0)
	for l in hi:
		if l.type == GridHelper.GridLineType.BEAT:
			beat_alpha = l.alpha
	_assert(is_equal_approx(beat_alpha, 1.0), "and is fully in at twice the spacing (%f)" % beat_alpha)


func _test_weight_follows_rank() -> void:
	# Strength: finest level faintest, coarser levels stronger, bars strongest
	var lines := _grid(140.0).get_visible_grid_lines(0.0, 600.0)
	var best := {}
	for l in lines:
		best[l.type] = l.weight
	_assert(best[GridHelper.GridLineType.BAR] > best[GridHelper.GridLineType.BEAT], "bars outweigh beats")
	_assert(best[GridHelper.GridLineType.BEAT] > 0.0, "beats outweigh the finest subdivision")
	var lone := _grid(2.0).get_visible_grid_lines(0.0, 600.0)
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
