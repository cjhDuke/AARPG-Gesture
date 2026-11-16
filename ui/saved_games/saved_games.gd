extends CanvasLayer

signal closed

const SKIN = preload("res://ui/settings/settings_theme.gd")

var is_open := false
var root: Control
var panel: Panel
var list: VBoxContainer
var details: VBoxContainer
var back: Button
var create_button: Button
var load_button: Button
var overwrite_button: Button
var rename_button: Button
var delete_button: Button
var notice: Label
var counter: Label
var modal: Control
var modal_title: Label
var modal_target: Label
var modal_note: Label
var name_input: LineEdit
var cancel_button: Button
var accept_button: Button
var entries: Array[Dictionary] = []
var selected_id := ""
var _from_title := true
var _can_save := false
var _previous_pause := false
var _previous_focus: Control
var _modal_focus: Control
var _action := ""
var _pending_id := ""
var _name_font: SystemFont


func _ready() -> void:
	layer = 25
	process_mode = Node.PROCESS_MODE_ALWAYS
	_name_font = SystemFont.new()
	_name_font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "sans-serif"])
	_build()
	visible = false


func open(from_title: bool) -> bool:
	if is_open or LevelManager.is_loading_level:
		return false
	_from_title = from_title
	_can_save = false
	var scene := get_tree().current_scene
	if not from_title and scene != null and scene.has_method("can_save_checkpoint"):
		_can_save = scene.can_save_checkpoint()
	_previous_pause = get_tree().paused
	_previous_focus = get_viewport().gui_get_focus_owner()
	get_tree().paused = true
	is_open = true
	visible = true
	modal.visible = false
	_refresh_entries()
	back.grab_focus()
	return true


func close() -> void:
	if not is_open:
		return
	modal.visible = false
	_action = ""
	_pending_id = ""
	visible = false
	is_open = false
	get_tree().paused = _previous_pause or LevelManager.is_loading_level
	if is_instance_valid(_previous_focus) and _previous_focus.is_visible_in_tree() and not (_previous_focus is Button and _previous_focus.disabled):
		_previous_focus.grab_focus()
	closed.emit()


func _input(event: InputEvent) -> void:
	if not is_open:
		return
	if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
		if name_input.has_focus() and name_input.has_ime_text():
			return
		if modal.visible:
			_cancel()
		else:
			close()
		get_viewport().set_input_as_handled()


func _unhandled_input(_event: InputEvent) -> void:
	if is_open:
		get_viewport().set_input_as_handled()


func _place(control: Control, parent: Node, rect: Rect2) -> void:
	parent.add_child(control)
	control.position = rect.position
	control.size = rect.size


func _label(text: String, font_size := 10, custom_name := false) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if custom_name:
		label.add_theme_font_override("font", _name_font)
	return label


func _button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 24
	button.pressed.connect(action)
	return button


func _build() -> void:
	root = Control.new()
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = SKIN.make_theme()
	root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var dim := ColorRect.new()
	dim.color = Color(DungeonTheme.BACKGROUND, 0.78)
	root.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel = Panel.new()
	root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -224
	panel.offset_right = 224
	panel.offset_top = -124
	panel.offset_bottom = 124
	panel.add_theme_stylebox_override("panel", DungeonTheme.panel())
	var heading := _label("SAVED GAMES", 24)
	heading.add_theme_font_override("font", DungeonTheme.TITLE_FONT)
	_place(heading, panel, Rect2(16, 7, 270, 28))
	back = _button("BACK", close)
	_place(back, panel, Rect2(356, 9, 76, 24))
	var banner := _label("SELECT A CHECKPOINT TO MANAGE", 8)
	banner.add_theme_color_override("font_color", SKIN.GOLD)
	_place(banner, panel, Rect2(16, 34, 416, 13))
	var left := Panel.new()
	left.add_theme_stylebox_override("panel", SKIN.flat(DungeonTheme.BACKGROUND, DungeonTheme.GOLD))
	_place(left, panel, Rect2(16, 50, 178, 144))
	counter = _label("")
	_place(counter, left, Rect2(7, 4, 162, 14))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	_place(scroll, left, Rect2(5, 22, 168, 116))
	list = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	var right := Panel.new()
	right.add_theme_stylebox_override("panel", SKIN.flat(DungeonTheme.BACKGROUND, DungeonTheme.GOLD))
	_place(right, panel, Rect2(202, 50, 230, 144))
	var detail_scroll := ScrollContainer.new()
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_place(detail_scroll, right, Rect2(8, 5, 214, 134))
	details = VBoxContainer.new()
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	details.add_theme_constant_override("separation", 3)
	detail_scroll.add_child(details)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 4)
	_place(actions, panel, Rect2(16, 200, 416, 25))
	create_button = _button("+ NEW", _prompt.bind("new"))
	load_button = _button("LOAD", _prompt.bind("load"))
	overwrite_button = _button("OVERWRITE", _prompt.bind("overwrite"))
	rename_button = _button("RENAME", _prompt.bind("rename"))
	delete_button = _button("DELETE", _prompt.bind("delete"))
	delete_button.add_theme_color_override("font_color", Color("#ffb08a"))
	for button in [create_button, load_button, overwrite_button, rename_button, delete_button]:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		actions.add_child(button)
	notice = _label("", 8)
	notice.clip_text = true
	_place(notice, panel, Rect2(16, 229, 416, 13))
	_build_modal()


func _build_modal() -> void:
	modal = Control.new()
	root.add_child(modal)
	modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.82)
	modal.add_child(dim)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dialog := Panel.new()
	modal.add_child(dialog)
	dialog.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	dialog.offset_left = -168
	dialog.offset_right = 168
	dialog.offset_top = -78
	dialog.offset_bottom = 78
	dialog.add_theme_stylebox_override("panel", DungeonTheme.panel())
	modal_title = _label("", 14)
	modal_title.add_theme_color_override("font_color", SKIN.GOLD)
	_place(modal_title, dialog, Rect2(16, 12, 304, 20))
	modal_target = _label("", 12, true)
	modal_target.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	modal_target.max_lines_visible = 2
	_place(modal_target, dialog, Rect2(16, 38, 304, 35))
	name_input = LineEdit.new()
	name_input.max_length = 24
	name_input.add_theme_font_override("font", _name_font)
	name_input.add_theme_font_size_override("font_size", 12)
	name_input.add_theme_stylebox_override("normal", SKIN.flat(Color("#180f0c"), Color("#876442")))
	name_input.add_theme_stylebox_override("focus", SKIN.flat(Color("#180f0c"), SKIN.GOLD))
	name_input.add_theme_color_override("font_color", SKIN.INK)
	name_input.text_submitted.connect(func(_text: String) -> void: _accept())
	_place(name_input, dialog, Rect2(16, 39, 304, 29))
	modal_note = _label("", 9)
	modal_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_place(modal_note, dialog, Rect2(16, 78, 304, 27))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	_place(actions, dialog, Rect2(32, 115, 272, 26))
	cancel_button = _button("CANCEL", _cancel)
	accept_button = _button("CONFIRM", _accept)
	for button in [cancel_button, accept_button]:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		actions.add_child(button)
	modal.visible = false


func _clear(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()


func _selected() -> Dictionary:
	return _entry_by_id(selected_id)


func _entry_by_id(id: String) -> Dictionary:
	for entry in entries:
		if str(entry.get("id", "")) == id:
			return entry
	return {}


func _entry_name(entry: Dictionary) -> String:
	return "Autosave" if bool(entry.get("automatic", false)) else str(entry.get("name", ""))


func _refresh_entries() -> void:
	entries.assign(SaveManager.list_saves())
	if _entry_by_id(selected_id).is_empty():
		selected_id = ""
	_refresh()
	if not SaveManager.last_error.is_empty():
		_show_notice(SaveManager.last_error, true)


func _refresh() -> void:
	if _selected().is_empty():
		selected_id = "" if entries.is_empty() else str(entries[0].get("id", ""))
	_clear(list)
	counter.text = "%d SAVES / NEWEST FIRST" % entries.size()
	for entry in entries:
		var id := str(entry.get("id", ""))
		var button := _button("", _select.bind(id))
		button.focus_entered.connect(_select.bind(id))
		button.custom_minimum_size.y = 45
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_child(button)
		button.tooltip_text = str(entry.get("name", ""))
		button.set_meta("save_id", id)
		var automatic := bool(entry.get("automatic", false))
		var title := _label(("AUTO  " if automatic else "") + _entry_name(entry), 11, true)
		if automatic:
			title.add_theme_color_override("font_color", SKIN.GOLD)
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
		title.offset_left = 8
		title.offset_right = -8
		title.offset_top = 4
		button.add_child(title)
		var summary := _label("%s\n%s" % [str(entry.get("progress", "")), str(entry.get("time", ""))], 8)
		_place(summary, button, Rect2(8, 20, 145, 22))
	_select(selected_id)
	create_button.visible = not _from_title
	overwrite_button.visible = not _from_title
	create_button.disabled = not _can_save or LevelManager.practice_mode
	_foci(panel)
	_default_notice()


func _select(id: String) -> void:
	selected_id = id
	for button in list.get_children():
		var chosen: bool = button.get_meta("save_id", "") == id
		button.add_theme_stylebox_override("normal", DungeonTheme.panel(chosen))
	_clear(details)
	var entry := _selected()
	var valid := not entry.is_empty() and bool(entry.get("valid", false))
	var automatic := not entry.is_empty() and bool(entry.get("automatic", false))
	load_button.disabled = not valid or LevelManager.practice_mode
	overwrite_button.disabled = not valid or automatic or not _can_save or LevelManager.practice_mode
	rename_button.disabled = not valid or automatic or LevelManager.practice_mode
	delete_button.disabled = entry.is_empty() or LevelManager.practice_mode
	if entry.is_empty():
		details.add_child(_label("NO SAVED GAMES", 14))
		var empty := _label("Start a new game to create a checkpoint." if _from_title else "Choose + NEW to save this wave checkpoint.", 11)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		details.add_child(empty)
		return
	var title := _label(_entry_name(entry), 13, true)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.add_child(title)
	if automatic:
		var auto_note := _label("AUTO  Automatically saved at wave start. Loading restarts this wave.", 9)
		auto_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		auto_note.add_theme_color_override("font_color", SKIN.GOLD)
		details.add_child(auto_note)
	var progress := _label(str(entry.get("progress", "")), 12)
	progress.add_theme_color_override("font_color", SKIN.GOLD)
	details.add_child(progress)
	details.add_child(_label("SAVED  " + str(entry.get("time", "")), 9))
	if not valid:
		var message := str(entry.get("message", "")).strip_edges()
		var reason := _label(message if not message.is_empty() else "DAMAGED SAVE - CANNOT LOAD", 10)
		reason.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		details.add_child(reason)
		return
	details.add_child(_label("HP %s   PSI %s" % [str(entry.get("hp", "")), str(entry.get("psi", ""))]))
	details.add_child(_label("APPLES %d / 3   KILLS %d" % [int(entry.get("apples", 0)), int(entry.get("kills", 0))]))
	details.add_child(_label("UPGRADES", 9))
	var upgrades := str(entry.get("upgrades", ""))
	details.add_child(_label(upgrades if not upgrades.is_empty() else "NONE YET", 10))


func _default_notice() -> void:
	if LevelManager.practice_mode:
		notice.text = "PRACTICE MODE / SAVING AND LOADING ARE DISABLED."
		_show_notice(notice.text)
	elif not SaveManager.autosave_error.is_empty():
		notice.text = "AUTOSAVE FAILED: " + SaveManager.autosave_error
		_show_notice(notice.text, true)
	elif not _from_title and not _can_save:
		notice.text = "SAVE UNAVAILABLE BETWEEN WAVES."
		_show_notice(notice.text)
	else:
		notice.text = "LOAD RESTARTS THE SAVED WAVE / ESC BACK"
		_show_notice(notice.text)


func _show_notice(message: String, is_error := false) -> void:
	notice.text = message
	notice.tooltip_text = message
	notice.add_theme_color_override("font_color", Color("#ffb08a") if is_error else SKIN.INK)


func _prompt(action: String) -> void:
	if LevelManager.practice_mode or (action in ["new", "overwrite"] and (not _can_save or _from_title)):
		return
	var target := _selected()
	if bool(target.get("automatic", false)) and action in ["rename", "overwrite"]:
		return
	if action != "new" and target.is_empty():
		return
	if action in ["load", "rename", "overwrite"] and not target.get("valid", false):
		return
	_action = action
	_pending_id = str(target.get("id", "")) if action != "new" else ""
	_modal_focus = get_viewport().gui_get_focus_owner()
	modal_title.text = {"new": "NEW SAVE", "rename": "RENAME SAVE", "load": "LOAD THIS SAVE?", "overwrite": "OVERWRITE THIS SAVE?", "delete": "DELETE THIS SAVE?"}[action]
	name_input.visible = action in ["new", "rename"]
	modal_target.visible = not name_input.visible
	modal_target.text = _entry_name(target)
	name_input.text = str(target.get("name", "")) if action == "rename" else ""
	name_input.placeholder_text = "Name (optional, up to 24 characters)"
	modal_note.text = {"new": "Leave blank to use the game's default name.", "rename": "Only the name changes. Checkpoint stays the same.", "load": "Restarts this checkpoint. Current run will be replaced." if not _from_title else "Restarts from the beginning of the saved wave.", "overwrite": "Replaces this checkpoint with the current wave opening.", "delete": "This saved game will be permanently removed." if not bool(target.get("automatic", false)) else "This autosave will be recreated automatically at the next wave."}[action]
	accept_button.text = {"new": "CREATE", "rename": "RENAME", "load": "LOAD", "overwrite": "OVERWRITE", "delete": "DELETE"}[action]
	for control in _controls(panel):
		control.focus_mode = Control.FOCUS_NONE
	modal.visible = true
	_foci(modal)
	if name_input.visible:
		name_input.grab_focus()
		name_input.select_all()
	else:
		cancel_button.grab_focus()


func _cancel() -> void:
	modal.visible = false
	_action = ""
	_pending_id = ""
	_foci(panel)
	if is_instance_valid(_modal_focus) and _modal_focus.is_visible_in_tree():
		_modal_focus.grab_focus()
	else:
		back.grab_focus()


func _accept() -> void:
	if _action.is_empty() or (name_input.visible and name_input.has_ime_text()):
		return
	var action := _action
	var target_id := _pending_id
	var name := name_input.text.strip_edges().left(24)
	var success := false
	var created_id := ""
	var error := ""
	if action == "new":
		var checkpoint := _save_checkpoint()
		if checkpoint.is_empty():
			error = "Save is available during a wave or Boss battle."
		else:
			created_id = SaveManager.create_save(checkpoint, name)
			success = not created_id.is_empty()
	elif action == "rename":
		success = SaveManager.rename_save(target_id, name)
	elif action == "delete":
		success = SaveManager.delete_save(target_id)
	elif action == "overwrite":
		var checkpoint := _save_checkpoint()
		if checkpoint.is_empty():
			error = "Save is available during a wave or Boss battle."
		else:
			success = SaveManager.overwrite_save(target_id, checkpoint)
	elif action == "load":
		if SaveManager.load_game(target_id):
			PauseMenu.finish_for_load()
			modal.visible = false
			_action = ""
			_pending_id = ""
			visible = false
			is_open = false
			return
	modal.visible = false
	_action = ""
	_pending_id = ""
	if not success and error.is_empty():
		error = SaveManager.last_error.strip_edges()
		if error.is_empty():
			error = "SAVE OPERATION FAILED."
	if success and action == "new":
		selected_id = created_id
	elif success:
		selected_id = target_id
	elif action != "new":
		selected_id = target_id
	else:
		selected_id = ""
	_refresh_entries()
	back.grab_focus()
	if success:
		_show_notice({"new": "SAVE CREATED.", "rename": "SAVE RENAMED.", "delete": "SAVE DELETED.", "overwrite": "SAVE OVERWRITTEN."}[action])
	else:
		_show_notice(error, true)


func _save_checkpoint() -> Dictionary:
	if LevelManager.practice_mode or LevelManager.is_loading_level:
		return {}
	var scene := get_tree().current_scene
	if scene == null or not scene.has_method("can_save_checkpoint") or not scene.can_save_checkpoint() or not scene.has_method("get_checkpoint"):
		return {}
	var checkpoint: Variant = scene.call("get_checkpoint")
	return checkpoint if checkpoint is Dictionary else {}


func _controls(parent: Node) -> Array[Control]:
	var result: Array[Control] = []
	for child in parent.get_children():
		if child is Control and child.is_visible_in_tree() and (child is Button or child is LineEdit):
			if not (child is Button and child.disabled):
				result.append(child)
		result.append_array(_controls(child))
	return result


func _foci(parent: Node) -> void:
	var controls := _controls(parent)
	for i in controls.size():
		var control := controls[i]
		control.focus_mode = Control.FOCUS_ALL
		var previous := controls[posmod(i - 1, controls.size())].get_path()
		var next := controls[(i + 1) % controls.size()].get_path()
		control.focus_previous = previous
		control.focus_next = next
		control.focus_neighbor_top = previous
		control.focus_neighbor_bottom = next
		if control is Button:
			control.focus_neighbor_left = previous
			control.focus_neighbor_right = next
