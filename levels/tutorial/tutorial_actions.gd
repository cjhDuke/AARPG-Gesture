extends CanvasLayer

signal confirmation_opened
signal confirmation_cancelled
signal confirmed(action: String)

var _controls: Control
var _modal: ColorRect
var _question: Label
var _accept: Button
var _cancel: Button
var _action: String


func _ready() -> void:
	_controls = Control.new()
	_controls.name = "Controls"
	_controls.theme = DungeonTheme.THEME
	_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_controls)
	_button(_controls, "SkipButton", "SKIP (ESC)", Rect2(310, 244, 82, 21), 10).pressed.connect(_open.bind("skipped"))
	_button(_controls, "TitleButton", "TITLE", Rect2(400, 244, 70, 21), 10).pressed.connect(_open.bind("title"))

	_modal = ColorRect.new()
	_modal.name = "Confirmation"
	_modal.color = UpgradeMenu.COL_DIM
	_modal.theme = DungeonTheme.THEME
	_modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_modal)
	var panel := Panel.new()
	panel.position = Vector2(120, 92)
	panel.size = Vector2(240, 86)
	_modal.add_child(panel)
	_question = Label.new()
	_question.name = "Question"
	_question.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_question.position = Vector2(0, 11)
	_question.size.x = panel.size.x
	panel.add_child(_question)
	_cancel = _button(panel, "CancelButton", "CANCEL", Rect2(22, 48, 90, 25))
	_accept = _button(panel, "ConfirmButton", "SKIP", Rect2(128, 48, 90, 25))
	_cancel.focus_mode = Control.FOCUS_ALL
	_accept.focus_mode = Control.FOCUS_ALL
	_cancel.pressed.connect(_close)
	_accept.pressed.connect(_confirm)
	_modal.hide()


func _input(event: InputEvent) -> void:
	if LevelManager.is_loading_level:
		return
	if event.is_action_pressed("pause"):
		get_viewport().set_input_as_handled()
		if _modal.visible:
			_close()
		else:
			request_skip()


func request_skip() -> void:
	_open("skipped")


func _open(action: String) -> void:
	if LevelManager.is_loading_level or _modal.visible:
		return
	_action = action
	_question.text = "SKIP TRAINING?" if action == "skipped" else "RETURN TO TITLE?"
	_accept.text = "SKIP" if action == "skipped" else "TITLE"
	_modal.show()
	_cancel.grab_focus()
	confirmation_opened.emit()


func _close() -> void:
	_modal.hide()
	confirmation_cancelled.emit()


func _confirm() -> void:
	_modal.hide()
	confirmed.emit(_action)


func _button(parent: Control, node_name: String, caption: String, rect: Rect2, font_size := 12) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = caption
	button.focus_mode = Control.FOCUS_NONE
	button.position = rect.position
	button.add_theme_font_size_override("font_size", font_size)
	parent.add_child(button)
	button.size = rect.size
	return button
