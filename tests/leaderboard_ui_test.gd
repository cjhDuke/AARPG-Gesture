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


func _check_board_layout(panel: LeaderboardPanel) -> void:
	var frame: Control = panel._root.get_node("Panel")
	var original_size := get_window().size
	var original_focus := get_viewport().gui_get_focus_owner()
	for resolution in [Vector2i(1280, 720), Vector2i(1440, 810), Vector2i(1920, 1080)]:
		get_window().size = resolution
		await _wait(0.03)
		var interior := frame.get_global_rect().grow(-7)
		_check(panel._identity.get_global_rect().end.y <= panel._local_best.global_position.y, "Identity and personal best do not overlap")
		for button: Button in [panel._near_button, panel._refresh_button, panel._more_button]:
			var disabled := button.disabled
			button.disabled = false
			button.grab_focus()
			await _wait(0.02)
			_check(interior.encloses(button.get_global_rect().grow(2)), "Footer button and focus fit inside frame at %s: %s %s" % [resolution, button.text, button.get_global_rect()])
			_check(button.size.y <= 22, "Compact footer keeps requested height: %s" % button.size)
			_check(panel._local_best.get_global_rect().end.y + 4 <= button.global_position.y, "Footer does not overlap personal best: %s / %s" % [panel._local_best.get_global_rect(), button.get_global_rect()])
			button.disabled = disabled
	get_window().size = original_size
	if is_instance_valid(original_focus):
		original_focus.grab_focus()
	await _wait(0.03)


func _check_failure_layout(hud: SurvivalHud) -> void:
	var original_size := get_window().size
	var buttons: Control = hud.result_panel.get_node("Buttons")
	for resolution in [Vector2i(1280, 720), Vector2i(1440, 810), Vector2i(1920, 1080)]:
		get_window().size = resolution
		await _wait(0.03)
		var content_top := hud.result_title.global_position.y
		var content_bottom := buttons.get_global_rect().end.y
		_check(absf((content_top + content_bottom) * 0.5 - 132.0) <= 2.0, "Failure content vertically centered at %s" % resolution)
		_check(hud.result_title.get_global_rect().end.y <= hud.result_stats.global_position.y, "Failure title and stats do not overlap")
		_check(not hud.trophy.visible, "Failure has no empty trophy placeholder")
		await _capture("failure-centered-%d" % resolution.x)
	# Reusing this HUD for victory must restore the trophy layout without accumulating offsets.
	hud._layout_result(true)
	_check(is_equal_approx(hud.result_title.position.y, 112.0), "Victory restores original title position")
	hud._layout_result(false)
	_check(is_equal_approx(hud.result_title.position.y, 78.0), "Repeated failure layout is stable")
	get_window().size = original_size
	await _wait(0.03)


func _run() -> void:
	if not OS.get_environment("APPDATA").replace("\\", "/").contains("/.stage1_checks/"):
		push_error("Use isolated APPDATA under .stage1_checks for UI tests")
		get_tree().quit(2)
		return
	AuthManager.set_process(false)
	LeaderboardManager.set("network_enabled", false)
	AuthManager.startup_prompt_handled = true
	GestureInput.set_process(false)
	AudioServer.set_bus_mute(0, true)
	if OS.get_cmdline_user_args().has("--exported-package-check"):
		_check(FileAccess.file_exists("res://project.binary"), "Export has complete project configuration")
		_check(ResourceLoader.exists("res://ui/leaderboard/leaderboard_panel.gd"), "Export contains leaderboard implementation")
		for excluded in ["res://tests/run_stats_test.gd", "res://server/app.py", "res://docs/ai/leaderboard-online.md"]:
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
	LeaderboardManager.select_ruleset(StageData.LEGACY_RULESET)
	title.open_leaderboard()
	var panel: LeaderboardPanel = title._leaderboard
	_check(panel.is_open and title._leaderboard_open, "Title opens leaderboard")
	_check(LeaderboardManager.board_ruleset == StageData.CURRENT_RULESET, "Title opens the current v2 leaderboard")
	_check(title._account_button.disabled and title.button_start.disabled, "Background controls disabled")
	_check(panel._status.text != "ONLINE LEADERBOARD COMING SOON", "Production panel no longer uses the offline placeholder")
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
	await _check_board_layout(panel)
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
	arena.kills = 2147483647
	arena._end_run(true)
	await _wait(0.06)
	_check(not hud.gameplay.visible and not hud._ranking_badge.is_visible_in_tree(), "Result hides gameplay and combat ranking badge")
	_check(not PlayerHud.visible, "Actual end-run hides the independent player vitals HUD")
	_check(hud.ranking_label.is_visible_in_tree() and hud.get_node("ResultLayer").layer > 10, "Result ranking stays visible above the camera panel")
	_check(hud.result_extra.text.contains("2147483647") and hud.result_extra.text.contains("NEW BEST KILLS"), "Result uses persisted owner BEST and new record")
	_check(hud.ranking_label.text.contains("NOT RANKED"), "Result never claims upload")
	_check(hud.result_extra.get_minimum_size().x <= 300, "Large kill counts fit result frame")
	await _capture("victory-result")
	hud.leaderboard_button.grab_focus()
	LeaderboardManager.select_ruleset(StageData.LEGACY_RULESET)
	hud._open_leaderboard()
	_check(hud._leaderboard.is_open, "Result opens leaderboard")
	_check(LeaderboardManager.board_ruleset == StageData.CURRENT_RULESET, "Legacy result opens the current v2 leaderboard")
	_check(hud.retry_button.disabled and hud.title_button.disabled and hud.leaderboard_button.disabled, "Result background keys disabled")
	hud._leaderboard.close()
	await _wait(0.03)
	_check(get_tree().paused and not hud.retry_button.disabled, "Leaderboard returns to paused result")
	_check(get_viewport().gui_get_focus_owner() == hud.leaderboard_button, "Result focus restored")
	hud.hide_result()
	var manager := LeaderboardManager
	_check(hud.gameplay.visible and hud._ranking_badge.get_parent() == hud.gameplay, "Retry restores the gameplay group containing the ranking badge")
	AuthManager.authenticated = true
	AuthManager.user_id = "11111111" + "-1111-4111-8111-" + "111111111111"
	AuthManager.username = "同名玩家"
	AuthManager.session_changed.emit()
	var public_rows: Array = []
	for i in 20:
		public_rows.append({"entry_id": "global-%d" % i, "rank": i + 1, "player_name": "同名玩家" if i == 0 else "公开玩家%d" % i, "progress": 9, "rank_time_ms": 300000 + i})
	manager._board = {"entries": public_rows, "loading": false, "error": "", "next_cursor": "next-page", "cached": false, "updated_at": 1800000000}
	manager._personal = {
		"best": {"entry_id": "personal-entry-27", "rank": 27, "player_name": "同名玩家", "progress": 8, "rank_time_ms": 321000},
		"neighbors": [
			{"entry_id": "near-25", "rank": 25, "player_name": "附近玩家25", "progress": 8, "rank_time_ms": 319000},
			{"entry_id": "near-26", "rank": 26, "player_name": "同名玩家", "progress": 8, "rank_time_ms": 320000},
			{"entry_id": "personal-entry-27", "rank": 27, "player_name": "同名玩家", "progress": 8, "rank_time_ms": 321000},
			{"entry_id": "near-28", "rank": 28, "player_name": "附近玩家28", "progress": 8, "rank_time_ms": 322000},
			{"entry_id": "near-29", "rank": 29, "player_name": "附近玩家29", "progress": 8, "rank_time_ms": 323000}
		],
		"loading": false, "error": ""
	}
	var online_panel: LeaderboardPanel = hud._leaderboard
	online_panel.open()
	_check(online_panel.get("_current_button") == null and online_panel.get("_legacy_button") == null, "Leaderboard UI has no ruleset switch controls")
	_check(not online_panel._near_button.disabled, "Authenticated player with a best can open nearby ranks")
	_check(online_panel._rows_box.get_child_count() == 20, "Global view retains the first public page")
	_check(not online_panel._rows_box.get_child(0).get_meta("leaderboard_is_personal_best"), "Global duplicate name is not mistaken for personal entry")
	_check(online_panel._local_best.text.contains("#27") and online_panel._local_best.text.contains("8/11") and online_panel._local_best.text.contains(RunStats.format_time(321000)), "Personal footer includes rank, progress and time")
	_check(online_panel._near_button.focus_neighbor_right == online_panel._refresh_button.get_path(), "Near button joins the horizontal focus loop")
	_check(online_panel._refresh_button.focus_neighbor_right == online_panel._more_button.get_path() and online_panel._more_button.focus_neighbor_right == online_panel._close_button.get_path() and online_panel._close_button.focus_neighbor_right == online_panel._near_button.get_path(), "Global controls close the horizontal focus loop")
	online_panel._near_button.pressed.emit()
	_check(online_panel._near_me and online_panel._rows_box.get_child_count() == 5, "Near Me switches the list to personal neighbors")
	_check(online_panel._more_button.disabled, "Near Me disables public pagination")
	_check(online_panel._rows_box.get_child(1).get_meta("leaderboard_is_personal_best") == false and online_panel._rows_box.get_child(2).get_meta("leaderboard_is_personal_best"), "Only matching entry_id highlights the owner among duplicate names")
	await _capture("near-me")
	manager._personal["neighbors"] = []
	manager._personal["error"] = "Could not load personal ranking"
	manager.personal_changed.emit()
	_check(online_panel._rows_box.get_child_count() == 1 and online_panel._rows_box.get_child(0).get_meta("leaderboard_is_personal_best"), "Cached personal best remains visible without neighbors")
	_check(online_panel._status.text.contains("CACHED BEST") and online_panel._status.text.contains("unavailable"), "Missing personal neighbors are clearly marked unavailable")
	_check(online_panel._local_best.text.contains("CACHED #27"), "Failed personal refresh never presents cached rank as live")
	await _capture("near-me-cached-best")
	online_panel._near_button.pressed.emit()
	_check(not online_panel._near_me and online_panel._rows_box.get_child_count() == 20, "GLOBAL restores the public list")
	online_panel._near_button.pressed.emit()
	AuthManager.user_id = "22222222" + "-2222-4222-8222-" + "222222222222"
	AuthManager.username = "另一账号"
	AuthManager.session_changed.emit()
	_check(not online_panel._near_me and online_panel._near_button.disabled, "Account switch returns to Global and disables empty personal view")
	_check(online_panel._identity.text.contains("另一账号"), "Account switch refreshes current leaderboard identity")
	online_panel.close()
	AuthManager.authenticated = false
	AuthManager.user_id = ""
	AuthManager.username = ""
	AuthManager.session_changed.emit()
	RunStats.begin_run(true, 6)
	_check(hud._ranking_badge.text.contains("CONTINUED"), "Badge updates after HUD ready")
	RunStats.finish_run(false, 18)
	hud.show_result(false, 18, 0)
	_check(hud.result_stats.text.contains("SESSION TIME") and hud.ranking_label.text.contains("CONTINUED RUN"), "Continued result explains timing and qualification")
	await _check_failure_layout(hud)
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
