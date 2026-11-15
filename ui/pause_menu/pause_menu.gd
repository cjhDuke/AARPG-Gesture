extends CanvasLayer
## Shared gameplay/title settings. Closing restores the state owned by the caller.

signal shown
signal hidden

const TITLE_SCENE := "res://ui/title/title_scene.tscn"
const SKIN = preload("res://ui/settings/settings_theme.gd")
const ITEMS_TEXTURE = preload("res://levels/survival/pickups/items.png")

var bag_provider: Callable
var item_user: Callable
var _bag_use_buttons: Dictionary = {}
var restart_handler: Callable
var is_paused := false
var root: Control
var _panel: Panel
var _bag: VBoxContainer
var _game: GridContainer
var _audio: VBoxContainer
var _resume: Button
var _restart: Button
var _title: Button
var _saved_games: Button
var _slot_status: Label
var _game_tab: Button
var _audio_tab: Button
var _close: Button
var _feedback: Label
var _confirm: Control
var _confirm_text: Label
var _confirm_note: Label
var _cancel: Button
var _accept: Button
var _pending: Callable
var _confirm_close_before_action := true
var _confirm_keep_open := false
var _action_focus: Control
var _previous_focus: Control
var _previous_pause := false
var _previous_mode := Node.PROCESS_MODE_ALWAYS
var _title_context := false
var _sliders: Dictionary = {}
var _values: Dictionary = {}

func _ready() -> void:
	_build()
	visible = false
	SavedGames.closed.connect(_on_saved_games_closed)
	if AudioManager.has_signal("volume_changed"):
		AudioManager.connect("volume_changed", _on_volume_changed)
	if AudioManager.has_signal("storage_error"):
		AudioManager.connect("storage_error", _on_storage_error)

func clear_level_hooks() -> void:
	bag_provider = Callable()
	item_user = Callable()
	restart_handler = Callable()

func _input(event: InputEvent) -> void:
	if SavedGames.is_open:
		return
	if is_paused and (event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")):
		if _confirm.visible:
			_cancel_confirmation()
		else:
			hide_pause_menu()
		get_viewport().set_input_as_handled()

	if is_paused:
		_navigate_focus(event)

func _unhandled_input(event: InputEvent) -> void:
	if SavedGames.is_open:
		return
	if is_paused:
		if not _confirm.visible and not _title_context and event is InputEventKey and event.pressed and not event.echo:
			var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
			if key == KEY_Q or key == KEY_E:
				_use_bag_item(Pickup.Kind.APPLE if key == KEY_Q else Pickup.Kind.POTION)
		# Never let an unused key reach the title or another gameplay modal.
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("pause"):
		show_pause_menu()
		get_viewport().set_input_as_handled()

func show_pause_menu() -> void:
	# This guard is also required for direct calls from the HUD gear.
	if is_paused or process_mode == Node.PROCESS_MODE_DISABLED or LevelManager.is_loading_level or get_tree().paused:
		return
	if _gameplay_modal_active():
		return
	_open(false)

func _gameplay_modal_active() -> bool:
	if is_instance_valid(PlayerManager.player) and PlayerManager.player.is_dead:
		return true
	var scene := get_tree().current_scene
	if scene is SurvivalArena:
		return bool(scene.get("_ended")) or bool(scene.get("_stage_changing")) or is_instance_valid(scene.get("_upgrade_menu"))
	return false

func show_title_settings() -> void:
	if is_paused or LevelManager.is_loading_level:
		return
	_open(true)

func _open(from_title: bool) -> void:
	_previous_focus = get_viewport().gui_get_focus_owner()
	_previous_pause = get_tree().paused
	_previous_mode = process_mode
	_title_context = from_title
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = true
	_refresh()
	is_paused = true
	visible = true
	_set_page(false)
	shown.emit()

func hide_pause_menu() -> void:
	if not is_paused:
		return
	_confirm.visible = false
	_pending = Callable()
	visible = false
	is_paused = false
	get_tree().paused = _previous_pause or LevelManager.is_loading_level or _gameplay_modal_active()
	process_mode = _previous_mode
	hidden.emit()
	if is_instance_valid(_previous_focus) and _previous_focus.is_visible_in_tree():
		_previous_focus.grab_focus()

func finish_for_load() -> void:
	if not is_paused:
		return
	is_paused = false
	visible = false
	_confirm.visible = false
	_pending = Callable()
	process_mode = Node.PROCESS_MODE_ALWAYS

func _place(control: Control, parent: Node, rect: Rect2) -> void:
	parent.add_child(control)
	control.position = rect.position
	control.size = rect.size

func _label(text: String, size_px := 12) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size_px)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func _button(text: String, parent: Node, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 26
	parent.add_child(button)
	button.pressed.connect(callback)
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
	_panel = Panel.new()
	root.add_child(_panel)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.offset_left = -220
	_panel.offset_right = 220
	_panel.offset_top = -120
	_panel.offset_bottom = 120
	_panel.add_theme_stylebox_override("panel", DungeonTheme.panel())
	var heading := _label("SETTINGS", 24)
	heading.add_theme_font_override("font", DungeonTheme.TITLE_FONT)
	_place(heading, _panel, Rect2(18, 9, 350, 28))
	_close = _button("X", _panel, hide_pause_menu)
	_close.tooltip_text = "Close settings (Esc)"
	_close.position = Vector2(396, 9)
	_close.size = Vector2(28, 28)
	var inset := Panel.new()
	inset.add_theme_stylebox_override("panel", SKIN.flat(DungeonTheme.BACKGROUND, DungeonTheme.GOLD))
	_place(inset, _panel, Rect2(16, 42, 164, 124))
	var scroll := ScrollContainer.new()
	_place(scroll, inset, Rect2(7, 5, 150, 112))
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_bag = VBoxContainer.new()
	_bag.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bag.add_theme_constant_override("separation", 4)
	scroll.add_child(_bag)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	_place(tabs, _panel, Rect2(194, 42, 230, 26))
	_game_tab = _button("GAME", tabs, _set_page.bind(false))
	_audio_tab = _button("AUDIO", tabs, _set_page.bind(true))
	_game_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_audio_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for tab in [_game_tab, _audio_tab]:
		tab.toggle_mode = true
		tab.theme_type_variation = &"SettingsTab"
	_game = GridContainer.new()
	_game.columns = 2
	_game.add_theme_constant_override("h_separation", 5)
	_game.add_theme_constant_override("v_separation", 5)
	_place(_game, _panel, Rect2(194, 77, 230, 100))
	_resume = _button("RESUME", _game, hide_pause_menu)
	_restart = _button("RESTART", _game, _ask.bind("Restart this run?", _restart_run))
	_saved_games = _button("SAVED GAMES", _game, _open_saved_games)
	_title = _button("TITLE", _game, _ask.bind("Leave this run?", _return_title))
	_title.tooltip_text = "Return to title screen"
	_button("QUIT", _game, _ask.bind("Quit the game?", _quit_game))
	for child in _game.get_children():
		if child is Button:
			child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_audio = VBoxContainer.new()
	_audio.add_theme_constant_override("separation", 6)
	_place(_audio, _panel, Rect2(194, 77, 230, 139))
	for bus: StringName in [&"Master", &"Music", &"SFX"]:
		var row := VBoxContainer.new()
		row.add_theme_constant_override("separation", 1)
		_audio.add_child(row)
		var header := HBoxContainer.new()
		row.add_child(header)
		var name_label := _label({"Master": "MASTER", "Music": "MUSIC", "SFX": "SOUND EFFECTS"}[bus])
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		header.add_child(name_label)
		var value_label := _label("100%")
		header.add_child(value_label)
		_values[bus] = value_label
		var slider := HSlider.new()
		slider.max_value = 1.0
		slider.step = 0.01
		slider.custom_minimum_size = Vector2(230, 16)
		slider.value_changed.connect(_set_volume.bind(bus))
		row.add_child(slider)
		_sliders[bus] = slider
	_slot_status = _label("", 8)
	_slot_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_slot_status.clip_text = true
	_slot_status.max_lines_visible = 3
	_place(_slot_status, _panel, Rect2(18, 178, 404, 36))
	_feedback = _label("ESC  CLOSE    /    ARROWS  SELECT", 8)
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback.clip_text = true
	_feedback.max_lines_visible = 2
	_feedback.mouse_filter = Control.MOUSE_FILTER_PASS
	_place(_feedback, _panel, Rect2(18, 216, 404, 22))
	_build_confirmation()

func _build_confirmation() -> void:
	_confirm = Control.new()
	root.add_child(_confirm)
	_confirm.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.8)
	_confirm.add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dialog := Panel.new()
	_confirm.add_child(dialog)
	dialog.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	dialog.offset_left = -148
	dialog.offset_right = 148
	dialog.offset_top = -56
	dialog.offset_bottom = 56
	dialog.add_theme_stylebox_override("panel", DungeonTheme.panel())
	_confirm_text = _label("")
	_confirm_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place(_confirm_text, dialog, Rect2(12, 17, 272, 22))
	_confirm_note = _label("CURRENT PROGRESS WILL BE LOST", 9)
	_confirm_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_confirm_note.add_theme_color_override("font_color", DungeonTheme.GOLD_BRIGHT)
	_place(_confirm_note, dialog, Rect2(12, 42, 272, 14))
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	_place(buttons, dialog, Rect2(26, 68, 244, 26))
	_cancel = _button("CANCEL", buttons, _cancel_confirmation)
	_accept = _button("CONFIRM", buttons, _confirm_action)
	_cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_accept.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm.visible = false

func _refresh() -> void:
	_feedback.text = "ESC  CLOSE    /    ARROWS  SELECT"
	_feedback.tooltip_text = ""
	_feedback.add_theme_color_override("font_color", SKIN.INK)
	if LevelManager.practice_mode:
		_feedback.text = "Practice mode: saving and loading are disabled.\nNo checkpoint is written in practice."
	if int(AudioManager.get("last_settings_error")) != OK:
		_on_storage_error(&"load", int(AudioManager.get("last_settings_error")))
	for child in _bag.get_children():
		_bag.remove_child(child)
		child.queue_free()
	_bag_use_buttons.clear()
	var heading := HBoxContainer.new()
	var bag_texture := AtlasTexture.new()
	bag_texture.atlas = preload("res://ui/theme/ui_icons.png")
	bag_texture.region = Rect2(224, 0, 32, 32)
	var bag_icon := TextureRect.new()
	bag_icon.texture = bag_texture
	heading.add_child(bag_icon)
	var bag_title := _label("BAG", 24)
	bag_title.add_theme_font_override("font", DungeonTheme.TITLE_FONT)
	bag_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.add_child(bag_title)
	_bag.add_child(heading)
	if not _title_context and bag_provider.is_valid():
		var info: Dictionary = bag_provider.call()
		var status := _label(str(info.get("status", "")), 9)
		status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_bag.add_child(status)
		for row: Dictionary in info.get("rows", []):
			var line := HBoxContainer.new()
			var icon := TextureRect.new()
			var tex := AtlasTexture.new()
			tex.atlas = ITEMS_TEXTURE
			var region: Rect2 = row["region"]
			tex.region = region.grow(-4.0)
			icon.texture = tex
			icon.custom_minimum_size = Vector2(20, 24)
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			line.add_child(icon)
			var words := VBoxContainer.new()
			words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			words.add_theme_constant_override("separation", -2)
			words.add_child(_label("%s  %s" % [row["name"], row["value"]], 10))
			var note := _label(str(row.get("note", "")), 8)
			note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			words.add_child(note)
			line.add_child(words)
			if row.has("kind"):
				var kind := int(row["kind"])
				var use := _button("USE %s" % ("Q" if kind == Pickup.Kind.APPLE else "E"), line, _use_bag_item.bind(kind))
				use.custom_minimum_size.y = 16
				use.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				use.add_theme_font_size_override("font_size", 8)
				use.disabled = not bool(row.get("can_use", false))
				_bag_use_buttons[kind] = use
			_bag.add_child(line)
		_bag.add_child(_label("UPGRADES", 12))
		var upgrades: Array = info.get("upgrades", [])
		var owned := _label("\n".join(PackedStringArray(upgrades)) if not upgrades.is_empty() else "NONE YET", 9)
		owned.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_bag.add_child(owned)
	else:
		var welcome := _label("PSI HAND\n\nSOUND SETTINGS\n\nChanges apply instantly.", 12)
		welcome.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_bag.add_child(welcome)
	_resume.text = "BACK" if _title_context else "RESUME"
	_restart.visible = not _title_context and restart_handler.is_valid()
	_title.visible = not _title_context
	_saved_games.visible = not _title_context
	for bus: StringName in _sliders:
		if AudioManager.has_method("get_bus_volume"):
			_on_volume_changed(bus, float(AudioManager.call("get_bus_volume", bus)))
		_sliders[bus].editable = AudioManager.has_method("set_bus_volume")
	_slot_status.text = "Manage saved checkpoints from SAVED GAMES." if not _title_context else "SAVED GAMES is available from the title menu."

func _use_bag_item(kind: int) -> void:
	if not item_user.is_valid() or not bool(item_user.call(kind)):
		return
	_refresh()
	_update_focus()
	var button: Button = _bag_use_buttons.get(kind)
	if is_instance_valid(button) and not button.disabled:
		button.grab_focus()
	else:
		_resume.grab_focus() if _game.visible else _sliders[&"Master"].grab_focus()

func _set_page(audio_page: bool) -> void:
	_game.visible = not audio_page
	_audio.visible = audio_page
	_slot_status.visible = not audio_page
	_game_tab.set_pressed_no_signal(not audio_page)
	_audio_tab.set_pressed_no_signal(audio_page)
	_update_focus()
	if audio_page:
		_sliders[&"Master"].grab_focus()
	else:
		_resume.grab_focus()

func _focusables(node: Node) -> Array[Control]:
	var controls: Array[Control] = []
	for child in node.get_children():
		if child is Control and child.is_visible_in_tree() and (child is Button or child is HSlider):
			if not (child is Button and child.disabled) and not (child is HSlider and not child.editable):
				controls.append(child)
		controls.append_array(_focusables(child))
	return controls

func _update_focus() -> void:
	var controls := _focusables(_confirm if _confirm.visible else _panel)
	for i in controls.size():
		var control := controls[i]
		control.focus_mode = Control.FOCUS_ALL
		var previous := controls[(i + controls.size() - 1) % controls.size()].get_path()
		var next := controls[(i + 1) % controls.size()].get_path()
		control.focus_previous = previous
		control.focus_next = next
		# Directions are resolved at input time, after containers have laid out.
		control.focus_neighbor_top = control.get_path()
		control.focus_neighbor_bottom = control.get_path()
		control.focus_neighbor_left = control.get_path()
		control.focus_neighbor_right = control.get_path()

func _navigate_focus(event: InputEvent) -> void:
	var direction := Vector2.ZERO
	if event.is_action_pressed("ui_up", true):
		direction = Vector2.UP
	elif event.is_action_pressed("ui_down", true):
		direction = Vector2.DOWN
	elif event.is_action_pressed("ui_left", true):
		direction = Vector2.LEFT
	elif event.is_action_pressed("ui_right", true):
		direction = Vector2.RIGHT
	else:
		return
	var controls := _focusables(_confirm if _confirm.visible else _panel)
	var current := get_viewport().gui_get_focus_owner()
	if current is HSlider and current in controls and direction.x != 0.0:
		return
	# Consume even at an edge so Godot's automatic search cannot leave the modal.
	get_viewport().set_input_as_handled()
	if controls.is_empty():
		return
	if current not in controls:
		controls[0].grab_focus()
		return
	var origin := current.get_global_rect()
	var best: Control
	var best_aligned := false
	var best_distance := INF
	for candidate in controls:
		if candidate == current or candidate.focus_mode == Control.FOCUS_NONE:
			continue
		var rect := candidate.get_global_rect()
		if not rect.has_area():
			continue
		var offset := rect.get_center() - origin.get_center()
		# Ignore center drift between differently sized controls in the same row/column.
		if offset.dot(direction) <= origin.size.dot(direction.abs()) * 0.5:
			continue
		var aligned := false
		if direction.x == 0.0:
			aligned = minf(origin.end.x, rect.end.x) > maxf(origin.position.x, rect.position.x)
		else:
			aligned = minf(origin.end.y, rect.end.y) > maxf(origin.position.y, rect.position.y)
		var distance := offset.length_squared()
		if best == null or (aligned and not best_aligned) or (aligned == best_aligned and distance < best_distance):
			best = candidate
			best_aligned = aligned
			best_distance = distance
	if best != null:
		best.grab_focus()

func _ask(message: String, action: Callable, close_before_action := true, keep_open := false, note := "CURRENT PROGRESS WILL BE LOST") -> void:
	_action_focus = get_viewport().gui_get_focus_owner()
	_pending = action
	_confirm_text.text = message
	_confirm_close_before_action = close_before_action
	_confirm_keep_open = keep_open
	_confirm_note.text = note
	_confirm_note.visible = not note.is_empty()
	for control in _focusables(_panel):
		control.focus_mode = Control.FOCUS_NONE
	_confirm.visible = true
	_update_focus()
	_cancel.grab_focus()

func _cancel_confirmation() -> void:
	_confirm.visible = false
	_pending = Callable()
	_update_focus()
	_restore_action_focus()

func _confirm_action() -> void:
	var action := _pending
	if not action.is_valid():
		return
	if action == _quit_game:
		AudioManager.flush_settings()
	if _confirm_close_before_action:
		hide_pause_menu()
		action.call()
		return
	var result: Variant = action.call()
	_pending = Callable()
	_confirm.visible = false
	if result is bool and not bool(result):
		_update_focus()
		_restore_action_focus()
		return
	if _confirm_keep_open:
		_update_focus()
		_restore_action_focus()
		return
	hide_pause_menu()

func _restore_action_focus() -> void:
	if is_instance_valid(_action_focus) and _action_focus.is_visible_in_tree():
		if not (_action_focus is Button and _action_focus.disabled):
			_action_focus.grab_focus()
			return
	_resume.grab_focus()

func _open_saved_games() -> void:
	if _title_context or not is_paused or not SavedGames.open(false):
		return
	visible = false
	process_mode = Node.PROCESS_MODE_DISABLED

func _on_saved_games_closed() -> void:
	if not is_paused:
		return
	visible = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	_refresh()
	_update_focus()
	_saved_games.grab_focus()

func _restart_run() -> void:
	if restart_handler.is_valid():
		restart_handler.call()

func _return_title() -> void:
	LevelManager.load_new_level(TITLE_SCENE)

func _quit_game() -> void:
	get_tree().quit()

func _set_volume(value: float, bus: StringName) -> void:
	if AudioManager.has_method("set_bus_volume"):
		AudioManager.call("set_bus_volume", bus, value)
	_on_volume_changed(bus, value)

func _on_volume_changed(bus: StringName, value: float) -> void:
	if _sliders.has(bus):
		_sliders[bus].set_value_no_signal(value)
		_values[bus].text = "%d%%" % roundi(value * 100.0)

func _on_storage_error(operation: StringName, error: int) -> void:
	if operation == &"load":
		_feedback.text = "Could not load sound settings. Default volumes are in use."
	else:
		_feedback.text = "Could not save sound settings. Changes apply this session."
	_feedback.add_theme_color_override("font_color", Color("#ffb08c"))
	_feedback.tooltip_text = "%s: %s (%d)" % [String(operation), error_string(error), error]
