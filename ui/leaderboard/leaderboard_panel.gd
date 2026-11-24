extends CanvasLayer
class_name LeaderboardPanel

signal closed

const PANEL_RECT := Rect2(20, 15, 440, 240)
const VISIBLE_ROWS := 6
const SETTINGS_THEME := preload("res://ui/settings/settings_theme.gd")

var is_open := false
var _previous_pause := false
var _previous_focus: Control
var _preview_rows: Array = []
var _preview_mode := false
var _root: Control
var _rows_box: VBoxContainer
var _scroll: ScrollContainer
var _status: Label
var _identity: Label
var _local_best: Label
var _name_font: SystemFont
var _close_button: Button
var _near_button: Button
var _refresh_button: Button
var _more_button: Button
var _player_name := ""
var _best_kills := 0
var _active_identity := ""
var _near_me := false


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	_name_font = SystemFont.new()
	_name_font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "Arial", "sans-serif"])
	_build()
	visible = false
	if not LeaderboardManager.board_changed.is_connected(_on_board_changed):
		LeaderboardManager.board_changed.connect(_on_board_changed)
	if not LeaderboardManager.personal_changed.is_connected(_on_personal_changed):
		LeaderboardManager.personal_changed.connect(_on_personal_changed)
	if not RunStats.stats_changed.is_connected(_on_stats_changed):
		RunStats.stats_changed.connect(_on_stats_changed)
	if not AuthManager.session_changed.is_connected(_on_session_changed):
		AuthManager.session_changed.connect(_on_session_changed)


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
	_close_button = _button("X", Rect2(401, 8, 25, 22))
	_close_button.pressed.connect(close)
	panel.add_child(_close_button)
	for direction in ["top", "bottom", "left", "right"]:
		_close_button.set("focus_neighbor_" + direction, _close_button.get_path())
	_status = _label("Loading leaderboard...", 9)
	_status.position = Vector2(20, 39)
	_status.size = Vector2(390, 16)
	_status.add_theme_color_override("font_color", DungeonTheme.GOLD_BRIGHT)
	panel.add_child(_status)
	var header := Control.new()
	header.position = Vector2(18, 57)
	header.size = Vector2(398, 14)
	panel.add_child(header)
	for spec in [["RANK", 0, 42], ["PLAYER", 48, 176], ["PROGRESS", 232, 60], ["TIME", 302, 84]]:
		var label := _label(spec[0], 8)
		label.position.x = spec[1]
		label.size = Vector2(spec[2], 14)
		label.add_theme_color_override("font_color", DungeonTheme.MUTED)
		header.add_child(label)
	_scroll = ScrollContainer.new()
	_scroll.position = Vector2(18, 73)
	_scroll.size = Vector2(402, 98)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(_scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 1)
	_scroll.add_child(_rows_box)
	var divider := ColorRect.new()
	divider.position = Vector2(18, 175)
	divider.size = Vector2(402, 1)
	divider.color = DungeonTheme.GOLD.darkened(0.25)
	panel.add_child(divider)
	_identity = _label("CURRENT PLAYER  GUEST", 9)
	_identity.position = Vector2(18, 176)
	_identity.size = Vector2(402, 14)
	_identity.add_theme_font_override("font", _name_font)
	_identity.clip_text = true
	_identity.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_identity.add_theme_color_override("font_color", DungeonTheme.GOLD_BRIGHT)
	panel.add_child(_identity)
	_local_best = _label("BEST KILLS  0   |   Sign in or complete a ranked run for your online best.", 8)
	_local_best.position = Vector2(18, 190)
	_local_best.size = Vector2(402, 12)
	panel.add_child(_local_best)
	_near_button = _button("NEAR ME", Rect2(18, 208, 90, 22))
	_near_button.pressed.connect(_toggle_near_me)
	panel.add_child(_near_button)
	_refresh_button = _button("REFRESH", Rect2(112, 208, 92, 22))
	_refresh_button.pressed.connect(_refresh_pressed)
	panel.add_child(_refresh_button)
	_more_button = _button("MORE", Rect2(208, 208, 78, 22))
	_more_button.pressed.connect(_more_pressed)
	panel.add_child(_more_button)
	_close_button.focus_neighbor_top = _close_button.get_path()
	_close_button.focus_neighbor_bottom = _close_button.get_path()
	var hint := _label("ESC / X: CLOSE", 8)
	hint.position = Vector2(292, 213)
	hint.size = Vector2(124, 12)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.add_theme_color_override("font_color", DungeonTheme.MUTED)
	panel.add_child(hint)
	_render_rows()


func _label(value: String, font_size: int) -> Label:
	var label := Label.new()
	label.theme = DungeonTheme.THEME
	label.add_theme_font_size_override("font_size", font_size)
	label.text = value
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _button(value: String, rect: Rect2) -> Button:
	var button := Button.new()
	# 先固定字号，再设置文字和尺寸，避免默认字号把按钮提前撑高。
	button.theme = DungeonTheme.THEME
	button.add_theme_font_size_override("font_size", 8)
	button.text = value
	button.position = rect.position
	button.size = rect.size
	# 挂入父节点并刷新主题最小尺寸后再收紧，避免保留构建期间的旧高度。
	button.set_size.call_deferred(rect.size)
	return button


func open() -> void:
	if is_open:
		return
	_previous_pause = get_tree().paused
	_previous_focus = get_viewport().gui_get_focus_owner()
	get_tree().paused = true
	is_open = true
	visible = true
	_near_me = false
	_active_identity = _current_identity()
	_player_name = AuthManager.username if AuthManager.authenticated and not AuthManager.username.is_empty() else "GUEST"
	_best_kills = RunStats.get_personal_best(AuthManager.user_id if AuthManager.authenticated else "guest")
	_refresh_identity()
	_render_rows()
	_refresh_button.grab_focus()
	if not _preview_mode:
		LeaderboardManager.fetch_board(true)
		LeaderboardManager.fetch_personal()
		_render_live_state()


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
	_preview_mode = true
	_preview_rows = rows.duplicate(true)
	_render_rows()
	_update_controls()


func set_identity(display_name: String, best_kills: int) -> void:
	_player_name = display_name if not display_name.is_empty() else "GUEST"
	_best_kills = maxi(best_kills, 0)
	_refresh_identity()


func _refresh_identity() -> void:
	_identity.text = "CURRENT PLAYER  " + _player_name
	_identity.tooltip_text = _player_name
	_local_best.text = "BEST KILLS  %d   |   Sign in or complete a ranked run for your online best." % _best_kills


func _on_board_changed() -> void:
	if is_open and not _preview_mode:
		_render_live_state()


func _on_personal_changed() -> void:
	if is_open and not _preview_mode:
		_render_live_state()


func _on_stats_changed() -> void:
	if not is_open or _preview_mode:
		return
	_player_name = AuthManager.username if AuthManager.authenticated and not AuthManager.username.is_empty() else "GUEST"
	_best_kills = RunStats.get_personal_best(AuthManager.user_id if AuthManager.authenticated else "guest")
	_refresh_identity()
	_render_live_state()


func _current_identity() -> String:
	return AuthManager.user_id.to_lower() if AuthManager.authenticated else "guest"


func _on_session_changed() -> void:
	var identity := _current_identity()
	if identity == _active_identity:
		return
	_active_identity = identity
	_near_me = false
	_player_name = AuthManager.username if AuthManager.authenticated and not AuthManager.username.is_empty() else "GUEST"
	_best_kills = RunStats.get_personal_best(AuthManager.user_id if AuthManager.authenticated else "guest")
	if not _preview_mode:
		_refresh_identity()
		if is_open:
			LeaderboardManager.fetch_personal()
			_render_live_state()


func _render_live_state() -> void:
	if not is_open or _preview_mode:
		return
	var state: Dictionary = LeaderboardManager.get_board_state()
	var entries: Array = state.get("entries", [])
	var personal: Dictionary = LeaderboardManager.get_personal_state()
	var best: Dictionary = personal.get("best", {})
	if _near_me:
		if best.is_empty():
			_near_me = false
		else:
			var nearby_rows: Array = personal.get("neighbors", [])
			entries = nearby_rows if not nearby_rows.is_empty() else [best]
	_render_entries(entries)
	var status := ""
	if _near_me:
		var displayed_neighbors: Array = personal.get("neighbors", [])
		var personal_status_error := not str(personal.get("error", "")).is_empty()
		if displayed_neighbors.is_empty():
			status = "CACHED BEST  |  Nearby ranks unavailable"
			if bool(personal.get("loading", false)):
				status = "CACHED BEST  |  Loading nearby ranks..."
		elif personal_status_error:
			status = "CACHED PERSONAL RANK  |  Refresh failed; showing saved neighbors"
		elif bool(personal.get("loading", false)):
			status = "YOUR NEARBY RANKS  |  Refreshing..."
		else:
			status = "YOUR RANK AND NEIGHBORS"
	elif bool(state.get("cached", false)):
		status = "CACHED  %s" % _format_updated(int(state.get("updated_at", 0)))
		if bool(state.get("loading", false)):
			status += "  |  Refreshing..."
		elif not str(state.get("error", "")).is_empty():
			status += "  |  Offline; showing saved results"
	elif bool(state.get("loading", false)):
		status = "Loading leaderboard..."
	elif not str(state.get("error", "")).is_empty():
		status = "Could not load leaderboard. Press REFRESH to retry."
	elif entries.is_empty():
		status = "No ranked runs yet"
	else:
		status = "LIVE LEADERBOARD"
	if _near_me:
		status += "  |  NEAR ME"
	_status.text = status
	if not AuthManager.authenticated:
		_local_best.text = "BEST KILLS  %d   |   Sign in to see your online best." % _best_kills
	else:
		var personal_footer_error := not str(personal.get("error", "")).is_empty()
		if personal_footer_error and not best.is_empty():
			_local_best.text = _format_personal_best(best, "CACHED") if not best.is_empty() else "BEST KILLS  %d   |   Cached personal rank unavailable." % _best_kills
		elif not best.is_empty():
			_local_best.text = _format_personal_best(best, "CACHED" if bool(personal.get("loading", false)) else "YOUR BEST")
		elif bool(personal.get("loading", false)):
			_local_best.text = "BEST KILLS  %d   |   Loading your online best..." % _best_kills
		elif not str(personal.get("error", "")).is_empty():
			_local_best.text = "BEST KILLS  %d   |   Online best unavailable." % _best_kills
		else:
			_local_best.text = "BEST KILLS  %d   |   Complete a ranked run for your online best." % _best_kills
	_update_controls()


func _format_personal_best(best: Dictionary, label: String) -> String:
	var rank := int(best.get("rank", 0))
	var place := "#%d" % rank if rank > 0 else "UNRANKED"
	return "BEST KILLS %d  |  %s %s  %d/%d  %s" % [
		_best_kills, label, place, int(best.get("progress", 0)), _milestone_total(),
		RunStats.format_time(int(best.get("rank_time_ms", 0)))
	]


func _format_updated(timestamp: int) -> String:
	if timestamp <= 0:
		return "time unavailable"
	return "Updated " + Time.get_datetime_string_from_unix_time(timestamp, true)


func _render_entries(entries: Array) -> void:
	_clear_rows()
	var personal: Dictionary = LeaderboardManager.get_personal_state() if not _preview_mode else {}
	var best: Dictionary = personal.get("best", {})
	var my_entry_id := str(best.get("entry_id", ""))
	if entries.is_empty():
		var empty := _label("No ranked runs yet", 11)
		empty.custom_minimum_size = Vector2(390, 96)
		empty.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_rows_box.add_child(empty)
		return
	for i in entries.size():
		var row: Dictionary = entries[i]
		_add_row(row, i, str(row.get("entry_id", "")) == my_entry_id)


func _clear_rows() -> void:
	for child in _rows_box.get_children():
		_rows_box.remove_child(child)
		child.queue_free()


func _add_row(row: Dictionary, i: int, is_me: bool) -> void:
	var line := PanelContainer.new()
	line.custom_minimum_size = Vector2(388, 17)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var full_name := str(row.get("player_name", row.get("name", "Player")))
	if full_name.is_empty():
		full_name = "Player"
	line.tooltip_text = full_name
	_rows_box.add_child(line)
	var is_personal_best := is_me or (_preview_mode and bool(row.get("is_me", false)))
	line.set_meta("leaderboard_is_personal_best", is_personal_best)
	if is_personal_best:
		var style: StyleBox = SETTINGS_THEME.flat(Color(DungeonTheme.GOLD, 0.17), DungeonTheme.GOLD, 1)
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			style.set_content_margin(side, 0)
		line.add_theme_stylebox_override("panel", style)
	var cells := Control.new()
	cells.custom_minimum_size = Vector2(386, 17)
	cells.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(cells)
	var place := int(row.get("rank", i + 1))
	var rank_color: Color = Color("#f0c45e") if place == 1 else (Color("#c6d0d5") if place == 2 else (Color("#c98b60") if place == 3 else DungeonTheme.TEXT))
	var rank := _label(str(place), 9)
	rank.position.x = 0
	rank.size = Vector2(42, 17)
	rank.add_theme_color_override("font_color", rank_color)
	cells.add_child(rank)
	var player_name := Label.new()
	player_name.clip_text = true
	player_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	player_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	player_name.add_theme_font_override("font", _name_font)
	player_name.add_theme_font_size_override("font_size", 9)
	player_name.text = full_name
	player_name.position.x = 48
	player_name.size = Vector2(176, 17)
	cells.add_child(player_name)
	var progress := _label("%d/%d" % [int(row.get("progress", 0)), _milestone_total()], 9)
	progress.position.x = 232
	progress.size = Vector2(60, 17)
	cells.add_child(progress)
	var time := _label(RunStats.format_time(int(row.get("rank_time_ms", 0))), 9)
	time.position.x = 302
	time.size = Vector2(84, 17)
	cells.add_child(time)


func _render_rows() -> void:
	if not is_instance_valid(_rows_box):
		return
	if _preview_mode:
		_clear_rows()
		for i in _preview_rows.size():
			var row: Dictionary = _preview_rows[i]
			var converted := {"rank": row.get("rank", i + 1), "player_name": row.get("player_name", row.get("name", "Player")), "progress": int(str(row.get("progress", "0/9")).split("/")[0]), "rank_time_ms": row.get("rank_time_ms", 522123)}
			_add_row(converted, i, bool(row.get("is_me", false)))
		_status.text = "DESIGN PREVIEW - SAMPLE DATA"
	else:
		_render_live_state()


func _milestone_total() -> int:
	return StageData.milestones_for_ruleset(StageData.CURRENT_RULESET)


func _refresh_pressed() -> void:
	if not is_open or _preview_mode:
		return
	LeaderboardManager.fetch_board(true)
	LeaderboardManager.fetch_personal()
	_render_live_state()


func _more_pressed() -> void:
	if not is_open or _preview_mode or _near_me:
		return
	LeaderboardManager.fetch_board(false)
	_update_controls()


func _update_controls() -> void:
	if _preview_mode:
		_near_button.disabled = true
		_refresh_button.disabled = true
		_more_button.disabled = true
		_update_focus_neighbors()
		return
	var state: Dictionary = LeaderboardManager.get_board_state()
	var personal: Dictionary = LeaderboardManager.get_personal_state()
	var best: Dictionary = personal.get("best", {})
	_near_button.disabled = not AuthManager.authenticated or best.is_empty()
	_near_button.text = "GLOBAL" if _near_me else "NEAR ME"
	_refresh_button.disabled = bool(state.get("loading", false))
	_more_button.disabled = _near_me or bool(state.get("loading", false)) or str(state.get("next_cursor", "")).is_empty()
	if is_instance_valid(_scroll) and _rows_box.get_child_count() > VISIBLE_ROWS:
		_rows_box.custom_minimum_size.y = VISIBLE_ROWS * 18
	else:
		_rows_box.custom_minimum_size.y = 0
	_update_focus_neighbors()


func _toggle_near_me() -> void:
	if not is_open or not AuthManager.authenticated:
		return
	var personal: Dictionary = LeaderboardManager.get_personal_state()
	if personal.get("best", {}).is_empty():
		return
	_near_me = not _near_me
	_render_live_state()
	_update_controls()


func _update_focus_neighbors() -> void:
	var candidates: Array[Button] = []
	for button in [_near_button, _refresh_button, _more_button, _close_button]:
		if is_instance_valid(button) and not button.disabled and button.is_visible_in_tree():
			candidates.append(button)
	for i in candidates.size():
		var button := candidates[i]
		button.focus_neighbor_left = candidates[(i - 1 + candidates.size()) % candidates.size()].get_path()
		button.focus_neighbor_right = candidates[(i + 1) % candidates.size()].get_path()
		button.focus_neighbor_top = button.get_path()
		button.focus_neighbor_bottom = button.get_path()
	var owner := get_viewport().gui_get_focus_owner()
	if owner is BaseButton and owner.disabled and not candidates.is_empty():
		candidates[0].grab_focus()


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
