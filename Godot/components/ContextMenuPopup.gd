## One place for how every context menu / popup menu opens, anchors, animates and closes.
##
## Works with any `Popup` (`PopupPanel` or `PopupMenu`). Call sites use the static functions:
##
## - `popup_at_mouse(popup)` / `popup_at_point(popup, point)`: the right-click menu, under the pointer.
## - `popup_below_control(popup, control, prefer_up)`: a menu hanging off a button.
## - `popup_anchored(popup, anchor_rect, prefer_up)`: the general form (`anchor_rect` is in the
##   coordinates of the window the popup is parented to, i.e. `get_global_rect()` of a Control).
## - `close(popup)`: hide the popup with the close animation (use it instead of `hide()` for closes
##   the menu triggers itself, such as a button press in a `PopupPanel` menu).
##
## Anchoring: below the anchor (above when `prefer_up`), flipped to the other side when it does
## not fit, and clamped into the visible window (or screen, for a native popup). It handles both
## embedded and native (`force_native`) popups.
##
## Animation: the popup slides `SLIDE_PIXELS` towards its anchor's far side while the content fades
## in (`OPEN_SECONDS`), and reverses on close (`CLOSE_SECONDS`). Godot has no window alpha for
## embedded popups, so a `PopupPanel` fades its content (the panel background does not fade) and a
## `PopupMenu` (which draws itself) only slides. A `PopupMenu` is switched to
## `hide_on_item_selection = false` so a chosen item can close with the animation.
##
## Auto-close: for the grace period after opening (the `behavior/context_menu_auto_close` setting,
## `AUTO_CLOSE_GRACE_SECONDS` by default, or never), a popup never closes by itself. Once
## that has passed, it closes (animated) when the pointer is outside it, as soon as it has been
## outside for `AUTO_CLOSE_LEAVE_SECONDS` (a short debounce, so briefly overshooting an edge does
## not kill the menu). A pointer that left during the grace period therefore closes the popup the
## moment the grace period ends. These count as "inside": an open child popup (a submenu), a held
## mouse button, and a focused text field that is being edited while it has text or was typed in
## within `TYPING_HOLD_SECONDS` (an always-focused, still empty search field does not hold the
## popup open). See `AutoClose.should_close` for the rule as a pure function.
##
## In test mode (`Utils.is_test_mode()`) nothing animates and nothing auto-closes: `popup()` and
## `hide()` behave exactly as plain Godot ones, only the placement is shared.
class_name ContextMenuPopup extends RefCounted

## Distance the popup travels while opening/closing.
const SLIDE_PIXELS := 12.0
const OPEN_SECONDS := 0.25
const CLOSE_SECONDS := 0.15
## Nothing auto-closes during this long after opening (the default of the setting below).
const AUTO_CLOSE_GRACE_SECONDS := 2.0
## Setting holding the grace period: a `GRACE_CHOICES` key.
const AUTO_CLOSE_SETTING := "behavior/context_menu_auto_close"
const GRACE_NEVER := "Never"
## The setting's choices and their grace periods in seconds (negative: never auto-close).
const GRACE_CHOICES := {
	"0.5 s": 0.5, "1 s": 1.0, "1.5 s": 1.5, "2 s": 2.0, "3 s": 3.0, "4 s": 4.0, "5 s": 5.0,
	GRACE_NEVER: -1.0,
}
## After the grace period, the pointer may be outside the popup this long before it closes.
const AUTO_CLOSE_LEAVE_SECONDS := 0.3
## A focused text field with no text holds the popup open this long after the last key press.
const TYPING_HOLD_SECONDS := 5.0
## Offset from the pointer so a right-click menu opens under it with the pointer inside.
const MOUSE_OFFSET := 10.0
## Space between a popup and the (non-overlapping) anchor it hangs off.
const ANCHOR_GAP := 4.0
## Tests can turn the animation (and auto-close) back on; they are off in test mode by default.
static var animate_in_tests: bool = false
## Name of the helper node attached to an animated popup.
const CONTROLLER_NAME := &"_ContextMenuController"


## Where a popup of a given size lands. See `place()`.
class Placement extends RefCounted:
	## Top-left corner, clamped into the bounds.
	var position := Vector2.ZERO
	## True when the popup sits above the anchor (so it slides up while opening).
	var up := false


## Pure placement math. `anchor` is the rect the popup hangs off, `bounds` the area it must stay in.
## With `overlap` the popup starts at the anchor's edge instead of beyond it (the pointer case:
## the anchor is a small square around the pointer and the popup covers it).
## It opens below unless `prefer_up`; when the preferred side lacks room it flips to the other
## side if that fits, else it takes the side with more room. Horizontally it left-aligns with the
## anchor and right-aligns instead when that is the only way to fit. The result is clamped.
static func place(size: Vector2, anchor: Rect2, bounds: Rect2, prefer_up: bool = false,
		overlap: bool = false, gap: float = ANCHOR_GAP) -> Placement:
	var result := Placement.new()
	var top_below := anchor.position.y if overlap else anchor.end.y + gap
	var bottom_above := anchor.end.y if overlap else anchor.position.y - gap
	var room_below := bounds.end.y - top_below
	var room_above := bottom_above - bounds.position.y
	var fits_below := room_below >= size.y
	var fits_above := room_above >= size.y
	var up := prefer_up
	if prefer_up and not fits_above and fits_below:
		up = false
	elif not prefer_up and not fits_below and fits_above:
		up = true
	elif not fits_above and not fits_below:
		up = room_above > room_below
	result.up = up
	var x := anchor.position.x
	if x + size.x > bounds.end.x and anchor.end.x - size.x >= bounds.position.x:
		x = anchor.end.x - size.x
	var y := bottom_above - size.y if up else top_below
	result.position = Vector2(
		clampf(x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - size.x)),
		clampf(y, bounds.position.y, maxf(bounds.position.y, bounds.end.y - size.y)))
	return result


## Open `popup` under the pointer (the anchor is a small square around it).
## `prefer_up` opens it above the pointer instead (for menus near the bottom of a plugin window).
static func popup_at_mouse(popup: Popup, prefer_up: bool = false) -> void:
	popup_at_point(popup, _host_of(popup).get_mouse_position(), prefer_up)


## Open `popup` at `point` (window coordinates, e.g. a click position) like `popup_at_mouse`.
static func popup_at_point(popup: Popup, point: Vector2, prefer_up: bool = false) -> void:
	var anchor := Rect2(point - Vector2.ONE * MOUSE_OFFSET, Vector2.ONE * MOUSE_OFFSET * 2.0)
	popup_anchored(popup, anchor, prefer_up, true)


## Open `popup` hanging off `control`: below it, or above when `prefer_up`.
static func popup_below_control(popup: Popup, control: Control, prefer_up: bool = false) -> void:
	var anchor: Rect2 = control.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, control.size)
	popup_anchored(popup, anchor, prefer_up)


## Open `popup` anchored to `anchor` (window coordinates of the popup's parent window).
## `overlap` starts it at the anchor's edge rather than beyond it. `bounds` overrides the area it
## must stay in (window coordinates; default is the whole window, or the screen for a native popup).
## `auto_close` turns the auto-close off for popups that should stay until dismissed.
static func popup_anchored(popup: Popup, anchor: Rect2, prefer_up: bool = false,
		overlap: bool = false, bounds: Rect2 = Rect2(), auto_close: bool = true) -> void:
	var host := _host_of(popup)
	var native := not popup.is_embedded()
	# Native popups position in screen coordinates; embedded ones in the parent window's.
	var origin := Vector2(host.position) if native else Vector2.ZERO
	var area := bounds
	if area.size == Vector2.ZERO:
		area = _window_bounds(popup, host, anchor, origin)
	else:
		area.position += origin
	var screen_anchor := Rect2(anchor.position + origin, anchor.size)
	var size := _popup_size(popup)
	var placement := place(size, screen_anchor, area, prefer_up, overlap)
	var animated := _animates()
	var controller: Controller = null
	if animated:
		controller = _controller_for(popup)
		controller.auto_close_enabled = auto_close
		controller.begin_open()
	var start := placement.position
	if animated:
		start.y += SLIDE_PIXELS if placement.up else -SLIDE_PIXELS
	popup.popup(Rect2i(Vector2i(start), Vector2i(size)))
	# A PopupMenu may size itself larger than its minimum once shown; re-place with the real size.
	if Vector2(popup.size) != size:
		size = Vector2(popup.size)
		placement = place(size, screen_anchor, area, prefer_up, overlap)
		start = placement.position
		if animated:
			start.y += SLIDE_PIXELS if placement.up else -SLIDE_PIXELS
		popup.position = Vector2i(start)
	if animated:
		controller.play_open(Vector2i(placement.position), placement.up)


## Hide `popup` with the close animation (instantly in test mode or when it is not shown).
static func close(popup: Popup) -> void:
	if popup == null or not popup.visible:
		return
	var controller := popup.get_node_or_null(NodePath(CONTROLLER_NAME)) as Controller
	if controller == null or not _animates():
		popup.hide()
		return
	controller.play_close()


## The grace period for a setting choice, in seconds; negative means never auto-close.
static func grace_for_choice(choice: Variant) -> float:
	return GRACE_CHOICES.get(choice, AUTO_CLOSE_GRACE_SECONDS)


## The grace period from the setting, in seconds (negative: never). The `Settings` autoload is
## looked up as a node: naming it would stop this script compiling for test scripts.
static func grace_setting() -> float:
	var settings := (Engine.get_main_loop() as SceneTree).root.get_node_or_null("Settings")
	if settings == null:
		return AUTO_CLOSE_GRACE_SECONDS
	return grace_for_choice(settings.get_value(AUTO_CLOSE_SETTING))


## Whether popups animate: always, except in test mode (unless `animate_in_tests`).
static func _animates() -> bool:
	return animate_in_tests or not Utils.is_test_mode()


## The window a popup is parented to (its placement coordinates are relative to this).
static func _host_of(popup: Popup) -> Window:
	var parent := popup.get_parent()
	if parent != null and parent.get_window() != null:
		return parent.get_window()
	return Engine.get_main_loop().root


## Room a popup may use: the host window for an embedded popup, the screen otherwise.
static func _window_bounds(popup: Popup, host: Window, anchor: Rect2, origin: Vector2) -> Rect2:
	if popup.is_embedded():
		return Rect2(Vector2.ZERO, host.get_visible_rect().size)
	var at := Vector2i(anchor.get_center() + origin)
	var screen := DisplayServer.get_screen_from_rect(Rect2i(at, Vector2i.ONE))
	return Rect2(DisplayServer.screen_get_usable_rect(screen))


## Size the popup will open at: its contents, at least its own minimum.
static func _popup_size(popup: Popup) -> Vector2:
	var size := Vector2(popup.get_contents_minimum_size())
	size = size.max(Vector2(popup.min_size))
	return size.max(Vector2.ONE)


static func _controller_for(popup: Popup) -> Controller:
	var existing := popup.get_node_or_null(NodePath(CONTROLLER_NAME)) as Controller
	if existing != null:
		return existing
	var controller := Controller.new()
	controller.name = CONTROLLER_NAME
	controller.popup = popup
	popup.add_child(controller, false, Node.INTERNAL_MODE_BACK)
	return controller


## Tracks the age of the popup and how long the pointer has been outside; the testable half of
## the auto-close.
class AutoClose extends RefCounted:
	var grace: float = ContextMenuPopup.AUTO_CLOSE_GRACE_SECONDS
	var leave_delay: float = ContextMenuPopup.AUTO_CLOSE_LEAVE_SECONDS
	## Seconds since the popup opened.
	var elapsed: float = 0.0
	## Seconds the pointer has been continuously outside (and not busy).
	var outside_seconds: float = 0.0

	## Start again (on open).
	func reset() -> void:
		elapsed = 0.0
		outside_seconds = 0.0

	## The decision: close only after the grace period, and only when the pointer has been outside
	## (and nothing keeps the popup busy) for `leave_delay`.
	static func should_close(p_elapsed: float, p_outside_seconds: float, pointer_inside: bool,
			busy: bool, p_grace: float = ContextMenuPopup.AUTO_CLOSE_GRACE_SECONDS,
			p_leave_delay: float = ContextMenuPopup.AUTO_CLOSE_LEAVE_SECONDS) -> bool:
		if pointer_inside or busy:
			return false
		if p_elapsed < p_grace:
			return false
		return p_outside_seconds >= p_leave_delay

	## Whether a focused text field keeps the popup open: only while it is being edited and has
	## text or was typed in recently.
	static func field_holds_open(editing: bool, has_text: bool, seconds_since_typed: float) -> bool:
		if not editing:
			return false
		return has_text or seconds_since_typed < ContextMenuPopup.TYPING_HOLD_SECONDS

	## Advance by `delta`. `busy` (child popup open, text being edited, button held) counts as
	## inside. Returns true when the popup should close now.
	func tick(delta: float, pointer_inside: bool, busy: bool = false) -> bool:
		elapsed += delta
		if pointer_inside or busy:
			outside_seconds = 0.0
		else:
			outside_seconds += delta
		return AutoClose.should_close(elapsed, outside_seconds, pointer_inside, busy, grace, leave_delay)

	## The pointer is inside again: the leave debounce starts over (the grace clock keeps running).
	func pointer_entered() -> void:
		outside_seconds = 0.0


## Lives under an animated popup: runs the open/close tweens and the auto-close timer.
class Controller extends Node:
	var popup: Popup
	var auto_close_enabled: bool = true

	var _auto := AutoClose.new()
	var _tween: Tween
	var _closing := false
	var _pointer_inside := false
	var _target := Vector2i.ZERO
	var _up := false
	var _serial := 0
	var _menu_hooked := false
	var _hide_on_checkable := true
	var _last_typed_msec := -1000000
	## Tests set this to stand in for the real pointer position (null = read the pointer).
	var forced_inside: Variant = null


	func _ready() -> void:
		set_process(false)
		popup.popup_hide.connect(_on_popup_hide)
		_hook_menu()


	## Called before the popup is shown: forget any close in progress.
	func begin_open() -> void:
		_kill_tween()
		_closing = false
		_serial += 1


	## Slide/fade in to `target` (window position), starting `SLIDE_PIXELS` away.
	func play_open(target: Vector2i, up: bool) -> void:
		_target = target
		_up = up
		_set_content_alpha(0.0)
		_auto.reset()
		_auto.grace = ContextMenuPopup.grace_setting()
		_pointer_inside = _pointer_over(Rect2(Vector2(target), Vector2(popup.size)))
		_last_typed_msec = -1000000
		set_process(auto_close_enabled and _auto.grace >= 0.0)
		_kill_tween()
		_tween = popup.create_tween().set_parallel(true)
		_tween.tween_property(popup, "position:y", target.y, ContextMenuPopup.OPEN_SECONDS) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_tween.tween_method(_set_content_alpha, 0.0, 1.0, ContextMenuPopup.OPEN_SECONDS) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


	## Slide/fade out, then hide.
	func play_close() -> void:
		if _closing or not popup.visible:
			return
		_closing = true
		set_process(false)
		_kill_tween()
		var end_y := _target.y + (ContextMenuPopup.SLIDE_PIXELS if _up else -ContextMenuPopup.SLIDE_PIXELS)
		_tween = popup.create_tween().set_parallel(true)
		_tween.tween_property(popup, "position:y", int(end_y), ContextMenuPopup.CLOSE_SECONDS) \
				.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_tween.tween_method(_set_content_alpha, _content_alpha(), 0.0, ContextMenuPopup.CLOSE_SECONDS)
		_tween.chain().tween_callback(popup.hide)


	func _process(delta: float) -> void:
		if not popup.visible or _closing:
			set_process(false)
			return
		var inside := _pointer_over(Rect2(Vector2(popup.position), Vector2(popup.size)))
		if inside and not _pointer_inside:
			_auto.pointer_entered()
		_pointer_inside = inside
		if _auto.tick(delta, _pointer_inside, _is_busy()):
			play_close()


	## Anything that should keep the popup open even with the pointer away.
	func _is_busy() -> bool:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			return true
		for child in popup.find_children("*", "Window", true, false):
			if (child as Window).visible:
				return true
		var focus := popup.gui_get_focus_owner()
		var since_typed := (Time.get_ticks_msec() - _last_typed_msec) / 1000.0
		if focus is LineEdit:
			var line := focus as LineEdit
			return AutoClose.field_holds_open(line.is_editing(), not line.text.is_empty(), since_typed)
		if focus is TextEdit:
			var edit := focus as TextEdit
			return AutoClose.field_holds_open(edit.has_focus(), not edit.text.is_empty(), since_typed)
		return false


	## Whether the pointer is over `rect` (the popup's rect, in its host window's coordinates for an
	## embedded popup, screen coordinates for a native one). Polled every frame: while an embedded
	## popup is open, Godot hands it every mouse motion event, even ones outside it, so motion
	## events and mouse_entered/exited cannot tell inside from outside.
	func _pointer_over(rect: Rect2) -> bool:
		if forced_inside != null:
			return forced_inside
		if popup.is_embedded():
			return rect.has_point(ContextMenuPopup._host_of(popup).get_mouse_position())
		return rect.has_point(Vector2(DisplayServer.mouse_get_position()))


	func _on_popup_hide() -> void:
		_kill_tween()
		_closing = false
		set_process(false)
		_set_content_alpha(1.0)


	func _kill_tween() -> void:
		if _tween != null and _tween.is_valid():
			_tween.kill()
		_tween = null


	## Fade the popup's content (the panel itself cannot fade in an embedded window).
	func _set_content_alpha(alpha: float) -> void:
		for child in popup.get_children():
			if child != self and child is CanvasItem:
				(child as CanvasItem).modulate.a = alpha


	func _content_alpha() -> float:
		for child in popup.get_children():
			if child != self and child is CanvasItem:
				return (child as CanvasItem).modulate.a
		return 1.0


	## A PopupMenu hides itself on selection before we can animate. Turn that off and close
	## ourselves after the item's own handlers ran.
	func _hook_menu() -> void:
		if _menu_hooked or not (popup is PopupMenu):
			return
		_menu_hooked = true
		var menu := popup as PopupMenu
		_hide_on_checkable = menu.hide_on_checkable_item_selection
		menu.hide_on_item_selection = false
		menu.index_pressed.connect(_on_menu_index_pressed)


	func _on_menu_index_pressed(index: int) -> void:
		var menu := popup as PopupMenu
		if menu.is_item_checkable(index) and not _hide_on_checkable:
			return
		_close_if_unchanged.call_deferred(_serial)


	func _close_if_unchanged(serial: int) -> void:
		# A handler that reopened the menu has bumped the serial; leave that one alone.
		if serial == _serial:
			play_close()


	## Key presses in the popup count as typing (see `_is_busy`).
	func _input(event: InputEvent) -> void:
		if event is InputEventKey and (event as InputEventKey).pressed:
			_last_typed_msec = Time.get_ticks_msec()
