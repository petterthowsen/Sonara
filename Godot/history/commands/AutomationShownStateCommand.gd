# AutomationShownStateCommand.gd
# Undoable change of which automation lanes a view shows (spec 055). `do()` makes `lanes` the
# shown set through the view; `undo()` hands the view back the state captured before. Run it
# AFTER the commands that create the lanes it names, in the same macro, so redo re-attaches the
# lanes first and then shows them.
class_name AutomationShownStateCommand extends Command

var track: Object = null
var view: Object = null
## Lanes to show, in order.
var lanes: Array = []
## Opaque `view.capture(track)` from before the change.
var before: Variant = null


func _init(p_name: String = "Show Lanes", p_track: Object = null, p_view: Object = null,
		p_lanes: Array = [], p_before: Variant = null) -> void:
	name = p_name
	track = p_track
	view = p_view
	lanes = p_lanes.duplicate()
	before = p_before


func do() -> void:
	if track != null and view != null:
		view.apply_shown(track, lanes)


func undo() -> void:
	if track != null and view != null:
		view.restore(track, before)
