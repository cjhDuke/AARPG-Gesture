class_name GameUpdateDialog extends CanvasLayer

signal update_pressed
signal later_pressed
signal cancel_pressed

var _heading: Label
var _version: Label
var _notes: RichTextLabel
var _message: Label
var _progress: ProgressBar
var _update: Button
var _retry: Button
var _later: Button
var _cancel: Button


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 35
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0.025, 0.016, 0.02, 0.78)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 292.0
	panel.add_theme_stylebox_override("panel", DungeonTheme.panel())
	center.add_child(panel)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	panel.add_child(content)

	_heading = Label.new()
	_heading.add_theme_font_size_override("font_size", 18)
	_heading.add_theme_color_override("font_color", DungeonTheme.GOLD_BRIGHT)
	content.add_child(_heading)
	_version = Label.new()
	_version.add_theme_font_size_override("font_size", 11)
	content.add_child(_version)
	_notes = RichTextLabel.new()
	_notes.name = "UpdateNotes"
	_notes.custom_minimum_size.y = 67.0
	_notes.bbcode_enabled = false
	_notes.selection_enabled = true
	var notes_font := SystemFont.new()
	notes_font.font_names = PackedStringArray(["Segoe UI", "Microsoft YaHei UI", "sans-serif"])
	_notes.add_theme_font_override("normal_font", notes_font)
	_notes.add_theme_font_size_override("normal_font_size", 11)
	content.add_child(_notes)
	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.add_theme_font_size_override("font_size", 11)
	content.add_child(_message)
	_progress = ProgressBar.new()
	_progress.custom_minimum_size.y = 15.0
	_progress.max_value = 100.0
	_progress.add_theme_font_size_override("font_size", 10)
	content.add_child(_progress)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	content.add_child(actions)
	_update = _action(actions, "UpdateAndStart", "UPDATE & START", func() -> void: update_pressed.emit())
	_retry = _action(actions, "Retry", "RETRY", func() -> void: update_pressed.emit())
	_later = _action(actions, "Later", "LATER", func() -> void: later_pressed.emit())
	_cancel = _action(actions, "Cancel", "CANCEL", func() -> void: cancel_pressed.emit())


func offer(version: String, notes: String) -> void:
	visible = true
	_heading.text = "UPDATE AVAILABLE"
	_version.text = "VERSION " + version
	_notes.text = notes
	_notes.visible = not notes.strip_edges().is_empty()
	_message.hide()
	_progress.hide()
	_show_actions(_update, _later)


func waiting() -> void:
	_show_status("DOWNLOADING UPDATE", "Connecting...", _cancel)


func downloading(progress: float) -> void:
	_show_status("DOWNLOADING UPDATE", "", _cancel)
	_progress.value = progress
	_progress.show()


func preparing() -> void:
	_show_status("INSTALLING UPDATE", "The game will restart when the update is installed.", null)


func failed(message: String) -> void:
	_show_status("UPDATE PAUSED", message, null)
	_show_actions(_retry, _later)


func _show_status(heading: String, message: String, secondary: Button) -> void:
	_heading.text = heading
	_notes.hide()
	_message.text = message
	_message.visible = not message.is_empty()
	_progress.hide()
	_show_actions(null, secondary)


func _show_actions(primary: Button, secondary: Button) -> void:
	for button in [_update, _retry, _later, _cancel]:
		button.visible = button == primary or button == secondary
	var focus := get_viewport().gui_get_focus_owner()
	if is_instance_valid(primary) and focus != primary and focus != secondary:
		primary.grab_focus()
	elif is_instance_valid(secondary) and focus != secondary and primary == null:
		secondary.grab_focus()


func _action(container: HBoxContainer, node_name: String, label: String, callback: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = label
	button.custom_minimum_size.y = 24.0
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 11)
	button.pressed.connect(callback)
	container.add_child(button)
	return button


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not event.is_action_pressed("ui_cancel"):
		return
	get_viewport().set_input_as_handled()
	if _cancel.visible:
		cancel_pressed.emit()
	elif _later.visible:
		later_pressed.emit()
