extends Node

var _checks := 0
var _failures := 0


func _ready() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("LEADERBOARD UI: " + message)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, false, true).timeout


func _until(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 6000
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await _wait(0.02)
	_check(false, "Timeout waiting for scene")
	return false


func _capture(name: String) -> void:
	if not OS.get_cmdline_user_args().has("--capture-previews") or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var path := "res://build/previews/leaderboard"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
	_check(get_viewport().get_texture().get_image().save_png(path.path_join(name + ".png")) == OK, "Save preview " + name)


func _run() -> void:
	if not OS.get_environment("APPDATA").replace("\\", "/").contains("/.stage1_checks/"):
		push_error("Use isolated APPDATA under .stage1_checks for UI tests")
		get_tree().quit(2)
		return
	AuthManager.set_process(false)
	AuthManager.startup_prompt_handled = true
	GestureInput.set_process(false)
	AudioServer.set_bus_mute(0, true)
	if OS.get_cmdline_user_args().has("--exported-package-check"):
		_check(FileAccess.file_exists("res://project.binary"), "Export has complete project configuration")
		_check(ResourceLoader.exists("res://ui/leaderboard/leaderboard_panel.gd"), "Export contains leaderboard implementation")
		for excluded in ["res://tests/run_stats_test.gd", "res://server/app.py", "res://docs/ai/leaderboard-design.md"]:
			_check(not FileAccess.file_exists(excluded), "Private/test source excluded: " + excluded)
	get_tree().current_scene = null
	get_tree().change_scene_to_file("res://ui/title/title_scene.tscn")
	if not await _until(func() -> bool: return get_tree().current_scene != null):
		get_tree().quit(1)
		return
	var title := get_tree().current_scene
	title.logo.skip_intro()
	if not await _until(func() -> bool: return title._menu_ready):
		get_tree().quit(1)
		return
	var buttons: Array[Button] = [title.button_start, title.button_saved, title.button_leaderboard, title.button_settings, title.button_quit]
	_check(buttons.size() == 5, "Five title actions")
	var previous_bottom := 0.0
	for button in buttons:
		_check(button.position.y >= previous_bottom, "Title buttons do not overlap")
		previous_bottom = button.position.y + button.size.y
		_check(button.size.x <= 160, "Title button fits menu width")
	_check(title.menu.position.y + previous_bottom < 231, "Menu does not overlap keyboard hint")
	_check(not title._account_open, "Optional account dialog does not interrupt explicit user interaction")
	await _capture("title")
	title.button_leaderboard.grab_focus()
	title.open_leaderboard()
	var panel: LeaderboardPanel = title._leaderboard
	_check(panel.is_open and title._leaderboard_open, "Title opens leaderboard")
	_check(title._account_button.disabled and title.button_start.disabled, "Background controls disabled")
	_check(panel._status.text == "ONLINE LEADERBOARD COMING SOON", "Production panel has honest empty state")
	_check(panel._preview_rows.is_empty(), "No fake rankings in production")
	_check(get_tree().paused, "Title pause preserved while modal open")
	title.open_settings()
	title.open_saved_games()
	title._open_account()
	title.start_game()
	_check(not title._account_open and not title._saved_open and not title._settings_open and not title._starting, "Leaderboard excludes competing title actions")
	await _capture("empty-board")
	var rows: Array = []
	for i in 8:
		rows.append({"rank": i + 1, "name": "测试玩家" + str(i + 1) if i != 3 else "一个非常长的中文玩家名字用于测试显示截断", "progress": "9/9" if i < 4 else "8/9", "time": "08:42.123", "is_me": i == 3})
	panel.set_preview_rows(rows)
	await _wait(0.06)
	_check(panel._status.text == "DESIGN PREVIEW - SAMPLE DATA", "Samples clearly identified")
	_check(panel._rows_box.get_child_count() == 8, "Eight sample rows rendered")
	var name_label := panel._rows_box.get_child(3).get_child(0).get_child(1) as Label
	_check(name_label.clip_text and name_label.text_overrun_behavior == TextServer.OVERRUN_TRIM_ELLIPSIS, "Long Chinese names are clipped with ellipsis")
	_check(name_label.size.x <= 176 and name_label.position.x + name_label.size.x < 232, "Long Chinese label stays inside name column")
	_check(not panel._rows_box.get_child(3).tooltip_text.is_empty(), "Full name available as row tooltip")
	_check(panel._rows_box.size.x <= 402, "Sample rows do not cause horizontal overflow")
	await _capture("sample-board")
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	Input.parse_input_event(cancel)
	await _wait(0.04)
	_check(not title._leaderboard_open, "Escape closes only leaderboard")
	_check(get_tree().paused and not title.button_start.disabled, "Closing restores title controls and pause")
	_check(get_viewport().gui_get_focus_owner() == title.button_leaderboard, "Closing restores leaderboard button focus")
	title.open_settings()
	_check(title._settings_open, "Settings still opens after leaderboard")
	PauseMenu.hide_pause_menu()
	await _wait(0.03)
	title.open_saved_games()
	_check(title._saved_open, "Saved games still opens after leaderboard")
	SavedGames.close()
	await _wait(0.03)
	title._open_account()
	_check(title._account_open, "Optional account entry still works")
	title._account_panel.close()
	await _wait(0.03)
	_check(not title._account_open and not title.button_start.disabled, "Optional account close still permits guest play")
	title.start_game()
	if not await _until(func() -> bool: return get_tree().current_scene is SurvivalArena and not LevelManager.is_loading_level):
		get_tree().quit(1)
		return
	var arena := get_tree().current_scene as SurvivalArena
	var hud := arena.hud
	RunStats.begin_run()
	for milestone in range(1, 10):
		RunStats.record_milestone(milestone)
	RunStats.finish_run(true, 2147483647)
	hud.show_result(true, 2147483647, 0)
	await _wait(0.06)
	_check(hud.result_extra.text.contains("2147483647") and hud.result_extra.text.contains("NEW BEST KILLS"), "Result uses persisted owner BEST and new record")
	_check(hud.ranking_label.text.contains("NOT RANKED"), "Result never claims upload")
	_check(hud.result_extra.get_minimum_size().x <= 300, "Large kill counts fit result frame")
	await _capture("victory-result")
	hud.leaderboard_button.grab_focus()
	hud._open_leaderboard()
	_check(hud._leaderboard.is_open, "Result opens leaderboard")
	_check(hud.retry_button.disabled and hud.title_button.disabled and hud.leaderboard_button.disabled, "Result background keys disabled")
	hud._leaderboard.close()
	await _wait(0.03)
	_check(get_tree().paused and not hud.retry_button.disabled, "Leaderboard returns to paused result")
	_check(get_viewport().gui_get_focus_owner() == hud.leaderboard_button, "Result focus restored")
	hud.hide_result()
	RunStats.begin_run(true, 6)
	_check(hud._ranking_badge.text.contains("CONTINUED"), "Badge updates after HUD ready")
	RunStats.finish_run(false, 18)
	hud.show_result(false, 18, 0)
	_check(hud.result_stats.text.contains("SESSION TIME") and hud.ranking_label.text.contains("CONTINUED RUN"), "Continued result explains timing and qualification")
	await _capture("continued-result")
	hud.hide_result()
	RunStats.abandon_run()
	LevelManager.practice_mode = true
	RunStats.begin_run()
	_check(hud._ranking_badge.text.contains("PRACTICE"), "Practice badge distinct")
	RunStats.finish_run(false, 999)
	hud.show_result(false, 999, 0)
	_check(not hud.leaderboard_button.visible, "Practice has no online entry")
	_check(hud.retry_button.focus_neighbor_right == hud.title_button.get_path(), "Practice result focus skips hidden leaderboard")
	_check(not FileAccess.file_exists("user://account/session.dat"), "Tests never store real credentials")
	# 结束活跃场景后释放暂停中仍在等待的关卡/音乐任务。
	hud.hide_result()
	get_tree().paused = false
	arena._on_title_pressed()
	await _until(func() -> bool: return not LevelManager.is_loading_level)
	AudioManager.stop_music()
	await _wait(0.6)
	print("LEADERBOARD_UI_TEST checks=%d failures=%d" % [_checks, _failures])
	get_tree().quit(0 if _failures == 0 else 1)
