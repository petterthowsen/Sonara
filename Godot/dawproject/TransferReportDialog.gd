class_name TransferReportDialog extends AcceptDialog
## Shows a DAWproject transfer report (items dropped or approximated) or an error message.
## Layout lives in TransferReportDialog.tscn.

@onready var _summary: Label = %Summary
@onready var _entries: ItemList = %Entries


## Lists every entry of `report` (a TransferReport) under `title`.
func show_report(title: String, report: TransferReport) -> void:
	self.title = title
	_summary.text = "Some items could not be transferred exactly:"
	_entries.clear()
	for entry in report.entries():
		_entries.add_item(report.entry_text(entry))
	_entries.visible = true
	_show()


## Shows a single error message and no list.
func show_error(title: String, message: String) -> void:
	self.title = title
	_summary.text = message
	_entries.clear()
	_entries.visible = false
	_show()


func _show() -> void:
	if is_inside_tree() and not Utils.is_test_mode():
		popup_centered(Vector2i(560, 360))
