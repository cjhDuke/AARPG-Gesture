extends Node2D

## 标题背景的镜头位置（主角被隐藏，只借用它身上的 Camera2D）。
## x 取房间中心，y 比中心靠上，让顶部露出一截墙，看得出是个房间
const CAMERA_POS := Vector2(256, 112)
## 选择标记相对按钮左边缘的 x 偏移，以及 START 确认后飞出的距离、时长
const MARKER_OFFSET_X := -22.0
const MARKER_FLY_DISTANCE := 360.0
const MARKER_FLY_TIME := 0.25
## 按钮从下方滑入的距离、时长
const MENU_SLIDE_DISTANCE := 28.0
const MENU_SLIDE_TIME := 0.4

@export var music: AudioStream
@export var button_focus_audio: AudioStream
@export var button_press_audio: AudioStream

@onready var title_ui: Control = $CanvasLayer/Control
@onready var logo: TitleLogo = $CanvasLayer/Control/Logo
@onready var subtitle: Label = $CanvasLayer/Control/Subtitle
@onready var orbit_boomerang: TitleBoomerang = $CanvasLayer/Control/OrbitBoomerang
@onready var menu: VBoxContainer = $CanvasLayer/Control/Menu
@onready var button_start: Button = $CanvasLayer/Control/Menu/Button_start
@onready var button_saved: Button = $CanvasLayer/Control/Menu/Button_saved
@onready var button_quit: Button = $CanvasLayer/Control/Menu/Button_quit
@onready var button_settings: Button = $CanvasLayer/Control/Menu/Button_settings
@onready var button_leaderboard: Button = $CanvasLayer/Control/Menu/Button_leaderboard
@onready var marker: TitleBoomerang = $CanvasLayer/Control/Menu/Marker
@onready var audio_stream_player: AudioStreamPlayer = $AudioStreamPlayer

var _marker_tween: Tween
var _starting: bool = false
var _marker_placed: bool = false
var _settings_open: bool = false
var _saved_open: bool = false
var _leaderboard_open: bool = false
var _leaderboard: LeaderboardPanel
var _title_active: bool = true
var _account_open: bool = false
var _account_button: Button
var _account_panel: CanvasLayer
var _menu_ready := false
var _account_was_authenticated := false
var _menu_origin_y := 0.0
var _menu_position_known := false
var _menu_tween: Tween
var _update_dialog: GameUpdateDialog
var _update_open := false
var _update_requested := false
var _update_applying := false
var _update_target := ""
var _update_attempt := 0
var _update_return_focus: Control


func _ready() -> void:
	get_tree().paused = true
	logo.process_mode = Node.PROCESS_MODE_ALWAYS
	# 从游戏里返回标题时，加载流程结束会取消暂停，这里重新暂停
	LevelManager.level_loaded.connect( _pause_tree )
	PlayerManager.player.visible = false
	PlayerManager.player.global_position = CAMERA_POS

	PlayerHud.visible = false
	PauseMenu.process_mode = Node.PROCESS_MODE_DISABLED
	PauseMenu.hidden.connect(_on_settings_closed)
	SavedGames.closed.connect(_on_saved_games_closed)
	AuthManager.session_changed.connect(_queue_account_sync)
	AuthManager.busy_changed.connect(_queue_account_sync)

	title_ui.visible = false
	menu.visible = false
	marker.visible = false

	_build_account_entry()
	if GameUpdate.is_enabled():
		_build_update_dialog()

	LevelManager.level_load_started.connect(exit_title_screen)

	# 启动和从游戏里返回标题都一样：直接进标题，字母下落动画每次都重播
	setup_title_screen()
	_sync_account_state.call_deferred()


func setup_title_screen() -> void:
	title_ui.visible = true

	AudioManager.play_music(music)
	button_start.pressed.connect(start_game)
	button_saved.pressed.connect(open_saved_games)
	button_leaderboard.pressed.connect(open_leaderboard)
	button_quit.pressed.connect(quit_game)
	button_settings.pressed.connect(open_settings)

	# 竖排菜单：上下循环，左右也能在按钮间切换
	var buttons: Array[Button] = [button_start, button_saved, button_leaderboard, button_settings, button_quit]
	for i in buttons.size():
		var button := buttons[i]
		button.add_theme_font_size_override("font_size", 10)
		var prev_path := buttons[(i + buttons.size() - 1) % buttons.size()].get_path()
		var next_path := buttons[(i + 1) % buttons.size()].get_path()
		button.focus_neighbor_top = prev_path
		button.focus_neighbor_left = prev_path
		button.focus_neighbor_bottom = next_path
		button.focus_neighbor_right = next_path
		button.focus_entered.connect(play_audio.bind(button_focus_audio))
		button.focus_entered.connect(_move_marker.bind(button))
	if is_instance_valid(_account_button):
		button_start.focus_neighbor_top = _account_button.get_path()
		button_start.focus_neighbor_left = _account_button.get_path()

	# 标题入场：字母逐个落下，每落一个响一声；全部落定后淡入副标题和回旋镖，按钮滑入
	logo.letter_landed.connect(func(_i: int) -> void: play_audio(button_focus_audio))
	logo.intro_finished.connect(_on_logo_finished)
	# 动画约 1.5 秒，期间按确认键可跳过（见 TitleLogo.skip_intro）
	logo.play_intro()


func _on_logo_finished() -> void:
	if not _title_active:
		return
	orbit_boomerang.visible = true
	var tw := title_ui.create_tween()
	tw.tween_property(subtitle, "modulate:a", 1.0, 0.4)
	_show_menu()


func _show_menu() -> void:
	menu.visible = true
	# 等一帧让容器排好版，再记下按钮的最终位置
	await get_tree().process_frame
	if not is_inside_tree() or not _title_active:
		return
	if not _menu_position_known:
		_menu_origin_y = menu.position.y
		_menu_position_known = true
	var final_y := _menu_origin_y
	menu.position.y = final_y + MENU_SLIDE_DISTANCE
	menu.modulate.a = 0.0
	if _menu_tween:
		_menu_tween.kill()
	var tw := title_ui.create_tween()
	_menu_tween = tw
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.set_parallel(true)
	tw.tween_property(menu, "position:y", final_y, MENU_SLIDE_TIME) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(menu, "modulate:a", 1.0, MENU_SLIDE_TIME)
	tw.chain().tween_callback(func() -> void:
		_menu_ready = true
		if _title_active and not _starting and not _has_title_modal():
			button_start.grab_focus()
		_sync_account_state.call_deferred())


## 选择标记滑到获得焦点的按钮左侧
func _move_marker(button: Button) -> void:
	if _starting or not _title_active or not _menu_ready:
		return
	var target := Vector2(MARKER_OFFSET_X, button.position.y + button.size.y * 0.5)
	marker.visible = true
	if _marker_tween:
		_marker_tween.kill()
	if not _marker_placed:
		_marker_placed = true
		marker.position = target
		return
	_marker_tween = title_ui.create_tween()
	_marker_tween.tween_property(marker, "position", target, 0.15) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func start_game() -> void:
	if _starting or not _menu_ready or _has_title_modal():
		return
	_starting = true
	play_audio(button_press_audio)
	# 回旋镖横向飞出屏幕，然后再开始加载关卡
	if _marker_tween:
		_marker_tween.kill()
	_marker_tween = title_ui.create_tween()
	_marker_tween.tween_property(marker, "position:x", marker.position.x + MARKER_FLY_DISTANCE, MARKER_FLY_TIME) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await _marker_tween.finished
	LevelManager.start_new_game()


func quit_game() -> void:
	if _has_title_modal():
		return
	get_tree().quit()


func open_settings() -> void:
	if _starting or not _menu_ready or _has_title_modal():
		return
	PauseMenu.show_title_settings()
	if not PauseMenu.is_paused:
		return
	_settings_open = true
	title_ui.process_mode = Node.PROCESS_MODE_DISABLED
	for button in [button_start, button_saved, button_leaderboard, button_settings, button_quit]:
		button.disabled = true


func open_saved_games() -> void:
	if _starting or not _menu_ready or _has_title_modal() or not _title_active:
		return
	if not SavedGames.open(true):
		return
	_saved_open = true
	title_ui.process_mode = Node.PROCESS_MODE_DISABLED
	for button in [button_start, button_saved, button_leaderboard, button_settings, button_quit]:
		button.disabled = true


func _on_settings_closed() -> void:
	if not _settings_open or not _title_active:
		return
	_settings_open = false
	title_ui.process_mode = Node.PROCESS_MODE_INHERIT
	for button in [button_start, button_saved, button_leaderboard, button_settings, button_quit]:
		button.disabled = false
	_sync_account_state.call_deferred()


func open_leaderboard() -> void:
	if _starting or not _menu_ready or _has_title_modal() or not _title_active:
		return
	_leaderboard_open = true
	for button in [button_start, button_saved, button_leaderboard, button_settings, button_quit, _account_button]:
		if is_instance_valid(button):
			button.disabled = true
	title_ui.process_mode = Node.PROCESS_MODE_DISABLED
	LeaderboardManager.select_ruleset(StageData.CURRENT_RULESET)
	_leaderboard = LeaderboardPanel.new()
	_leaderboard.name = "LeaderboardPanel"
	add_child(_leaderboard)
	_leaderboard.closed.connect(_on_leaderboard_closed)
	_leaderboard.open()

func _on_leaderboard_closed() -> void:
	if not _leaderboard_open or not _title_active:
		return
	_leaderboard_open = false
	title_ui.process_mode = Node.PROCESS_MODE_INHERIT
	for button in [button_start, button_saved, button_leaderboard, button_settings, button_quit]:
		button.disabled = false
	if is_instance_valid(_account_button):
		_account_button.disabled = not AuthManager.startup_check_complete
	button_leaderboard.grab_focus.call_deferred()
	if is_instance_valid(_leaderboard):
		_leaderboard.queue_free()
	_leaderboard = null
	_sync_account_state.call_deferred()
func _on_saved_games_closed() -> void:
	if not _saved_open or not _title_active:
		return
	_saved_open = false
	title_ui.process_mode = Node.PROCESS_MODE_INHERIT
	for button in [button_start, button_saved, button_leaderboard, button_settings, button_quit]:
		button.disabled = false
	button_saved.grab_focus()
	_sync_account_state.call_deferred()


func _build_account_entry() -> void:
	_account_button = Button.new()
	_account_button.name = "AccountEntry"
	_account_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_account_button.offset_left = -102.0
	_account_button.offset_right = -16.0
	_account_button.offset_top = 12.0
	_account_button.offset_bottom = 38.0
	_account_button.text = "GUEST"
	var account_font := SystemFont.new()
	account_font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC", "Arial", "sans-serif"])
	_account_button.add_theme_font_override("font", account_font)
	_account_button.add_theme_font_size_override("font_size", 10)
	_account_button.clip_text = true
	_account_button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_account_button.pressed.connect(_open_account)
	_account_button.focus_entered.connect(play_audio.bind(button_focus_audio))
	title_ui.add_child(_account_button)
	_account_button.focus_neighbor_bottom = button_start.get_path()
	_account_button.focus_neighbor_left = button_start.get_path()
	_account_panel = CanvasLayer.new()
	_account_panel.set_script(load("res://ui/account/account_panel.gd"))
	_account_panel.name = "AccountPanel"
	add_child(_account_panel)
	_account_panel.closed.connect(_on_account_closed)
	_refresh_account_button()


func _refresh_account_button() -> void:
	if not is_instance_valid(_account_button):
		return
	_account_button.text = AuthManager.display_name() if AuthManager.authenticated else ("CHECKING..." if not AuthManager.startup_check_complete else "GUEST")
	if not AuthManager.authenticated and CloudSaveManager.is_account_context():
		_account_button.text = "OFFLINE"
	_account_button.disabled = not _menu_ready or not AuthManager.startup_check_complete or _starting or _has_title_modal()


func _open_account() -> void:
	if _starting or not _menu_ready or _has_title_modal() or not _title_active:
		return
	AuthManager.startup_prompt_handled = true
	_account_was_authenticated = AuthManager.authenticated
	_account_open = true
	for button in [button_start, button_saved, button_leaderboard, button_settings, button_quit, _account_button]:
		button.disabled = true
	title_ui.process_mode = Node.PROCESS_MODE_DISABLED
	_account_panel.open()


func _on_account_closed() -> void:
	if not _account_open or not _title_active:
		return
	_account_open = false
	title_ui.process_mode = Node.PROCESS_MODE_INHERIT
	for button in [button_start, button_saved, button_leaderboard, button_settings, button_quit, _account_button]:
		button.disabled = false
	_refresh_account_button()
	if AuthManager.authenticated:
		_account_button.grab_focus()
	else:
		button_start.grab_focus()
	_sync_account_state.call_deferred()


func _queue_account_sync(_value: bool = false) -> void:
	_sync_account_state.call_deferred()


func _sync_account_state() -> void:
	if not is_inside_tree() or not _title_active or _starting or LevelManager.practice_mode:
		return
	_refresh_account_button()
	if _account_open:
		if not AuthManager.authenticated and not AuthManager.busy:
			_account_was_authenticated = false
		elif AuthManager.authenticated and not AuthManager.busy and not _account_was_authenticated:
			_account_panel.close()
		return
	if not _menu_ready or _has_title_modal():
		return
	if _try_show_update() or not AuthManager.startup_check_complete or AuthManager.busy:
		return
	if AuthManager.authenticated:
		AuthManager.startup_prompt_handled = true
	elif not LevelManager.tutorial_preview and not AuthManager.startup_prompt_handled:
		_open_account()


func _has_title_modal() -> bool:
	return _settings_open or _saved_open or _leaderboard_open or _account_open or _update_open


func _build_update_dialog() -> void:
	_update_dialog = GameUpdateDialog.new()
	_update_dialog.name = "UpdateDialog"
	add_child(_update_dialog)
	_update_dialog.update_pressed.connect(_submit_update)
	_update_dialog.later_pressed.connect(_defer_update)
	_update_dialog.cancel_pressed.connect(_cancel_update)
	GameUpdate.state_changed.connect(_on_update_state_changed)


func _try_show_update() -> bool:
	if _update_dialog == null or GameUpdate.is_deferred() or not _title_active or _starting or not _menu_ready or _has_title_modal():
		return false
	var status := GameUpdate.get_status()
	var target := str(status.get("target_version", ""))
	if status.get("state") != "available" or target.is_empty():
		return false
	_update_open = true
	_update_target = target
	_update_return_focus = get_viewport().gui_get_focus_owner()
	_set_update_menu_locked(true)
	_update_dialog.offer(target, str(status.get("notes", "")))
	return true


func _set_update_menu_locked(locked: bool) -> void:
	title_ui.process_mode = Node.PROCESS_MODE_DISABLED if locked else Node.PROCESS_MODE_INHERIT
	for button in [button_start, button_saved, button_leaderboard, button_settings, button_quit]:
		button.disabled = locked
	_refresh_account_button()


func _submit_update() -> void:
	if not _update_open or _update_requested or _update_applying:
		return
	var status := GameUpdate.get_status()
	if status.get("target_version") == _update_target and status.get("state") == "ready":
		_apply_update()
		return
	if GameUpdate.request_download() != OK:
		_update_dialog.failed("Could not start the download. You can retry or play this version.")
		return
	_update_requested = true
	_update_attempt += 1
	_update_dialog.waiting()
	_watch_download_start(_update_attempt)


func _watch_download_start(attempt: int) -> void:
	await get_tree().create_timer(8.0, true).timeout
	if _update_open and _update_requested and not _update_applying and attempt == _update_attempt:
		_update_requested = false
		_update_dialog.failed("The update has not started. You can retry or play this version.")


func _on_update_state_changed(status: Dictionary) -> void:
	if not _update_open:
		_try_show_update()
		return
	if status.get("target_version", "") != _update_target:
		if not _update_applying:
			_defer_update()
		return
	if not _update_requested or _update_applying:
		return
	match status.get("state"):
		"downloading":
			_update_attempt += 1
			_update_dialog.downloading(float(status.get("progress", 0)))
		"ready":
			_apply_update()
		"error":
			_update_requested = false
			_update_dialog.failed("The download failed. Check your connection and retry.")


func _apply_update() -> void:
	_update_applying = true
	_update_dialog.preparing()
	var error := await GameUpdate.prepare_and_apply()
	if error == OK:
		return
	_update_applying = false
	_update_requested = false
	_update_dialog.failed("The game could not close safely for the update. You can retry or keep playing.")


func _cancel_update() -> void:
	if _update_requested and not _update_applying:
		GameUpdate.cancel_download()
	_defer_update()


func _defer_update() -> void:
	if not _update_open or _update_applying:
		return
	GameUpdate.defer_for_session()
	_update_open = false
	_update_requested = false
	_update_dialog.hide()
	_set_update_menu_locked(false)
	if is_instance_valid(_update_return_focus):
		_update_return_focus.grab_focus()
	else:
		button_start.grab_focus()
	_sync_account_state.call_deferred()


func exit_title_screen() -> void:
	AuthManager.startup_prompt_handled = true
	_title_active = false
	PlayerManager.player.visible = true

	PlayerHud.visible = true
	PauseMenu.process_mode = Node.PROCESS_MODE_ALWAYS
	if is_instance_valid(_account_panel):
		_account_panel.queue_free()

	self.queue_free()


func _pause_tree() -> void:
	get_tree().paused = true


func play_audio(_a: AudioStream) -> void:
	audio_stream_player.stream = _a
	audio_stream_player.play()
