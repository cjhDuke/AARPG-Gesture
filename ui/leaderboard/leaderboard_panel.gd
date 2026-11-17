extends CanvasLayer
class_name LeaderboardPanel

signal closed

const PANEL_RECT := Rect2(20, 15, 440, 240)

var is_open := false
var _previous_pause := false
var _previous_focus: Control
var _preview_rows: Array = []
var _root: Control
var _rows_box: VBoxContainer
var _status: Label
var _identity: Label
var _local_best: Label
var _name_font: SystemFont
var _close_button: Button


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	_name_font = SystemFont.new()
	_name_font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "Arial", "sans-serif"])
	_build()
	visible = false


func _build() -> void:
	_root = Control.new()
	_root.name = "ModalRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.theme = DungeonTheme.THEME
	_root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_root)
	var blocker := ColorRect.new()
	blocker.name = "InputBlocker"
	blocker.color = Color(DungeonTheme.BACKGROUND, 0.82)
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(blocker)
	var panel := Panel.new()
	panel.name = "Panel"
	panel.position = PANEL_RECT.position
	panel.size = PANEL_RECT.size
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", DungeonTheme.panel())
	_root.add_child(panel)
	var title := _label("LEADERBOARD", 20)
	title.add_theme_font_override("font", DungeonTheme.TITLE_FONT)
	title.position = Vector2(20, 12)
	title.size = Vector2(360, 24)
	panel.add_child(title)
	_close_button = Button.new()
	_close_button.name = "CloseButton"
	_close_button.text = "X"
	_close_button.position = Vector2(401, 8)
	_close_button.size = Vector2(25, 22)
	_close_button.pressed.connect(close)
	panel.add_child(_close_button)
	for direction in ["top", "bottom", "left", "right"]:
		_close_button.set("focus_neighbor_" + direction, _close_button.get_path())
	_status = _label("ONLINE LEADERBOARD COMING SOON", 10)
	_status.position = Vector2(20, 40)
	_status.size = Vector2(390, 13)
	_status.add_theme_color_override("font_color", DungeonTheme.GOLD_BRIGHT)
	panel.add_child(_status)
	var header := Control.new()
	header.position = Vector2(18, 59)
	header.size = Vector2(398, 14)
	panel.add_child(header)
	for spec in [["RANK", 0, 42], ["PLAYER", 48, 172], ["PROGRESS", 232, 60], ["TIME", 302, 84]]:
		var label := _label(spec[0], 8)
		label.position.x = spec[1]
		label.size = Vector2(spec[2], 14)
		label.add_theme_color_override("font_color", DungeonTheme.MUTED)
		header.add_child(label)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(18, 75)
	scroll.size = Vector2(402, 112)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 1)
	scroll.add_child(_rows_box)
	var divider := ColorRect.new()
	divider.position = Vector2(18, 190)
	divider.size = Vector2(402, 1)
	divider.color = DungeonTheme.GOLD.darkened(0.25)
	panel.add_child(divider)
	_identity = _label("CURRENT PLAYER  GUEST", 9)
	_identity.position = Vector2(18, 195)
	_identity.size = Vector2(402, 12)
	_identity.add_theme_font_override("font", _name_font)
	_identity.clip_text = true
	_identity.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_identity.mouse_filter = Control.MOUSE_FILTER_PASS
	_identity.add_theme_color_override("font_color", DungeonTheme.GOLD_BRIGHT)
	panel.add_child(_identity)
	_local_best = _label("LOCAL BEST KILLS  0", 9)
	_local_best.position = Vector2(18, 207)
	_local_best.size = Vector2(402, 12)
	panel.add_child(_local_best)
	var hint := _label("ESC / X: CLOSE", 8)
	hint.position = Vector2(18, 225)
	hint.size = Vector2(402, 12)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", DungeonTheme.MUTED)
	panel.add_child(hint)
	_render_rows()


func _label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func open(player_name: String = "", local_best: int = -1) -> void:
	if is_open:
		return
	_previous_pause = get_tree().paused
	_previous_focus = get_viewport().gui_get_focus_owner()
	get_tree().paused = true
	is_open = true
	visible = true
	if player_name.is_empty():
		_refresh_identity()
	else:
		set_identity(player_name, maxi(local_best, 0))
	_render_rows()
	_close_button.grab_focus()


func close() -> void:
	if not is_open:
		return
	visible = false
	is_open = false
	get_tree().paused = _previous_pause or LevelManager.is_loading_level
	if is_instance_valid(_previous_focus) and _previous_focus.is_visible_in_tree() and not (_previous_focus is BaseButton and _previous_focus.disabled):
		_previous_focus.grab_focus()
	closed.emit()


func set_preview_rows(rows: Array) -> void:
	_preview_rows = rows.duplicate(true)
	_render_rows()


func set_identity(display_name: String, best_kills: int) -> void:
	var shown_name := display_name if not display_name.is_empty() else "GUEST"
	_identity.text = "CURRENT PLAYER  " + shown_name
	_identity.tooltip_text = shown_name
	_local_best.text = "LOCAL BEST KILLS  %d" % best_kills


func _refresh_identity() -> void:
	var display := "GUEST"
	if AuthManager.authenticated:
		display = AuthManager.username if not AuthManager.username.is_empty() else "Player"
	set_identity(display, RunStats.best_kills)


func _exit_tree() -> void:
	if is_open:
		get_tree().paused = _previous_pause or LevelManager.is_loading_level
		is_open = false


func _input(event: InputEvent) -> void:
	if not is_open:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause"):
		close()
		get_viewport().set_input_as_handled()


func _unhandled_input(_event: InputEvent) -> void:
	if is_open:
		get_viewport().set_input_as_handled()


func _render_rows() -> void:
	if not is_instance_valid(_rows_box):
		return
	for child in _rows_box.get_children():
		_rows_box.remove_child(child)
		child.queue_free()
	if _preview_rows.is_empty():
		_status.text = "ONLINE LEADERBOARD COMING SOON"
		var empty := _label("Not connected yet", 11)
		empty.custom_minimum_size = Vector2(390, 96)
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_rows_box.add_child(empty)
		return
	_status.text = "DESIGN PREVIEW - SAMPLE DATA"
	for i in _preview_rows.size():
		var row: Dictionary = _preview_rows[i]
		var line := PanelContainer.new()
		line.custom_minimum_size = Vector2(388, 18)
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		line.tooltip_text = str(row.get("name", "Player"))
		_rows_box.add_child(line)
		if bool(row.get("is_me", false)):
			var style := StyleBoxFlat.new()
			style.bg_color = Color(DungeonTheme.GOLD, 0.17)
			style.border_color = DungeonTheme.GOLD
			style.set_border_width_all(1)
			line.add_theme_stylebox_override("panel", style)
		var cells := Control.new()
		cells.custom_minimum_size = Vector2(386, 18)
		cells.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line.add_child(cells)
		var place := int(row.get("rank", i + 1))
		var rank_color: Color = Color("#f0c45e") if place == 1 else (Color("#c6d0d5") if place == 2 else (Color("#c98b60") if place == 3 else DungeonTheme.TEXT))
		var rank := _label(str(place), 9)
		rank.position.x = 0
		rank.size = Vector2(42, 18)
		rank.add_theme_color_override("font_color", rank_color)
		cells.add_child(rank)
		var player_name := Label.new()
		# 在写入长名称前启用裁切，避免缓存的最小宽度先撑大本列。
		player_name.clip_text = true
		player_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		player_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
		player_name.add_theme_font_override("font", _name_font)
		player_name.add_theme_font_size_override("font_size", 9)
		player_name.text = str(row.get("name", "Player"))
		player_name.position.x = 48
		player_name.size = Vector2(176, 18)
		cells.add_child(player_name)
		var progress := _label(str(row.get("progress", "0/9")), 9)
		progress.position.x = 232
		progress.size = Vector2(60, 18)
		cells.add_child(progress)
		var time := _label(str(row.get("time", "--:--")), 9)
		time.position.x = 302
		time.size = Vector2(84, 18)
		cells.add_child(time)
