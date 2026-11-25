extends Node

## End-to-end test driver. Run with a fixture config and an isolated APPDATA per role.
const TITLE_SCENE := "res://ui/title/title_scene.tscn"
const CONFIG_ARG := "--client-config="
const ROLE_ARG := "--client-role="
const VALID_ROLES := ["a-seed", "a-retry", "b-verify", "c-verify", "current-play"]

var _driver := false
var _role := ""
var _config: Dictionary = {}
var _checks := 0
var _failures: Array[String] = []
var _auth_done := false
var _auth_ok := false
var _auth_expected := ""
var _prior_result_count := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if has_meta("e2e_driver"):
		_driver = true
		call_deferred("_execute")
		return
	call_deferred("_spawn_driver")


func _spawn_driver() -> void:
	var driver := Node.new()
	driver.set_script(load("res://tests/leaderboard_client_test.gd"))
	driver.set_meta("e2e_driver", true)
	get_tree().root.add_child(driver)


func _execute() -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), true)
	if not _parse_args():
		_finish()
		return
	if not _check(OS.get_environment("APPDATA").replace("\\", "/").contains("/.stage3_checks/"), "isolated APPDATA is set"):
		_finish()
		return
	if not _check(not LevelManager.practice_mode, "normal mode is enabled"):
		_finish()
		return
	if not _check(AuthManager.get_api_base() == str(_config.get("api", "")), "AuthManager targets fixture API"):
		_finish()
		return
	if _role == "a-retry":
		var before := await _fixture_summary()
		_prior_result_count = int(before.get("counts", {}).get("/api/v1" + "/ranked-runs/:id/result", 0))
		var control := await _control("drop_result_once")
		if not _check(int(control.get("status", 0)) == 200, "fixture armed one dropped result response"):
			_finish()
			return
		control = await _control("expire_access_once")
		if not _check(int(control.get("status", 0)) == 200, "fixture armed one expired access response"):
			_finish()
			return
	var scene_error := get_tree().change_scene_to_file(TITLE_SCENE)
	if not _check(scene_error == OK, "load the actual title scene"):
		_finish()
		return
	if not await _wait_for(func() -> bool: return get_tree().current_scene != null and get_tree().current_scene.scene_file_path == TITLE_SCENE, 15.0):
		_check(false, "title scene becomes current")
		_finish()
		return
	var title := get_tree().current_scene
	title.logo.skip_intro()
	if not await _wait_for(func() -> bool: return bool(title._menu_ready), 8.0):
		_check(false, "title menu becomes ready after skip intro")
		_finish()
		return
	var account: Dictionary = _config.get("users", {}).get("b" if _role == "b-verify" else "a", {})
	if not _check(account.has("id") and account.has("email") and account.has("password"), "fixture account is configured"):
		_finish()
		return
	if not await _login(str(account["email"]), str(account["password"])):
		_check(false, "login succeeds through AuthManager")
		_finish()
		return
	if not _check(AuthManager.authenticated and AuthManager.user_id == str(account["id"]), "authenticated identity matches configured account"):
		_finish()
		return
	if _role == "a-seed":
		await _run_a_seed(title, str(account["id"]))
	elif _role == "b-verify":
		await _exercise_delayed_grant()
		await _run_b_verify(title, str(account["id"]))
	elif _role == "a-retry":
		await _run_a_retry(str(account["id"]))
	elif _role == "c-verify":
		await _run_c_verify(title, str(account["id"]))
	elif _role == "current-play":
		await _run_current(title)
	_finish()


func _parse_args() -> bool:
	var config_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(CONFIG_ARG):
			config_path = arg.trim_prefix(CONFIG_ARG)
		elif arg.begins_with(ROLE_ARG):
			_role = arg.trim_prefix(ROLE_ARG)
	if not _check(_role in VALID_ROLES, "client role argument is valid"):
		return false
	if not _check(not config_path.is_empty(), "client config argument exists"):
		return false
	var file := FileAccess.open(config_path, FileAccess.READ)
	if not _check(file != null, "fixture config can be read"):
		return false
	var parser := JSON.new()
	if not _check(parser.parse(file.get_as_text()) == OK and parser.data is Dictionary, "fixture config is valid JSON"):
		return false
	_config = parser.data
	return _check(_config.get("api") is String and _config.get("users") is Dictionary, "fixture config has API and users")


func _login(email: String, password: String) -> bool:
	_auth_done = false
	_auth_ok = false
	_auth_expected = "login"
	if not AuthManager.request_finished.is_connected(_on_auth_finished):
		AuthManager.request_finished.connect(_on_auth_finished)
	AuthManager.login(email, password, false)
	var completed := await _wait_for(func() -> bool: return _auth_done, 15.0)
	AuthManager.request_finished.disconnect(_on_auth_finished)
	return completed and _auth_ok


func _on_auth_finished(operation: String, ok: bool, _message: String, _data: Dictionary) -> void:
	if operation != _auth_expected:
		return
	_auth_done = true
	_auth_ok = ok


func _open_arena(title: Node) -> SurvivalArena:
	title.button_start.pressed.emit()
	if not await _wait_for(func() -> bool: return get_tree().current_scene is SurvivalArena, 15.0):
		_check(false, "actual title START opens survival arena")
		return null
	var arena := get_tree().current_scene as SurvivalArena
	if not await _wait_for(func() -> bool: return LeaderboardManager.get_run_status().get("status") == "RANKED", 12.0):
		_check(false, "ranked run grant arrives before first wave")
		return arena
	var sealed := await _wait_for(func() -> bool: return arena._run_clock_started and bool(LeaderboardManager._run.get("sealed", false)) and RunStats._timing_active, 12.0)
	_check(sealed, "first wave starts and seals the grant while stats clock is active")
	return arena


func _record_milestones(count: int) -> void:
	for index in range(1, count + 1):
		await _wait_for(func() -> bool: return Time.get_ticks_msec() - _last_mark_ms >= 60, 2.0)
		RunStats.record_milestone(index)
		_last_mark_ms = Time.get_ticks_msec()


var _last_mark_ms := 0


func _run_current(title: Node) -> void:
	var arena := await _open_arena(title)
	if arena == null or LeaderboardManager.get_run_status().get("status") != "RANKED":
		return
	_check(arena.stage_count() == 4 and LeaderboardManager._run["grant"]["ruleset_id"] == "survival_v2", "New START receives a v2 credential")
	_last_mark_ms = Time.get_ticks_msec()
	await _record_milestones(11)
	arena._end_run(true)
	_check(await _wait_for(func() -> bool: return LeaderboardManager.get_run_status().get("status") == "UPLOADED", 15.0), "Eleven milestones upload as a ranked victory")
	arena.hud._open_leaderboard()
	await _wait_for(func() -> bool: return not LeaderboardManager.get_board_state()["loading"] and not LeaderboardManager.get_personal_state()["loading"], 15.0)
	_check(LeaderboardManager.board_ruleset == "survival_v2" and LeaderboardManager.get_personal_state().get("best", {}).get("progress") == 11, "Results open current personal ranking")
	var panel := arena.hud._leaderboard
	_check(panel.get("_current_button") == null and panel.get("_legacy_button") == null, "Online leaderboard UI has no ruleset switch controls")


func _run_a_seed(title: Node, owner: String) -> void:
	var arena := await _open_arena(title)
	if arena == null:
		return
	if LeaderboardManager.get_run_status().get("status") != "RANKED":
		return
	LeaderboardManager.network_enabled = false
	_last_mark_ms = Time.get_ticks_msec()
	await _record_milestones(2)
	var snapshot := RunStats.get_run_snapshot()
	_check(int(snapshot.get("elapsed_ms", 0)) >= int(snapshot.get("milestone_ms", [0])[-1]) and int(snapshot.get("milestone_ms", [0])[0]) >= 1, "a-seed milestones have positive wall-clock timing")
	arena.kills = 37
	arena._end_run(false)
	var result_state := LeaderboardManager.get_run_status()
	_check(result_state.get("status") == "PENDING", "offline result is pending (" + str(result_state.get("status")) + ": " + str(result_state.get("reason")) + ")")
	_check(LeaderboardManager._profile(owner)["pending"].size() == 1, "one result is persisted for account a")
	_check(RunStats.get_personal_best(owner) == 37, "local personal best 37 is persisted")
	var profile_path: String = LeaderboardManager._profile_path(owner)
	var profile_file := FileAccess.open(profile_path, FileAccess.READ)
	_check(profile_file != null, "account profile file exists")
	if profile_file != null:
		var profile_text := profile_file.get_as_text().to_lower()
		_check(not profile_text.contains("access_token") and not profile_text.contains("refresh_token") and not profile_text.contains("bearer "), "profile contains no credentials")
	var stats_file := FileAccess.open(RunStats._path_for_identity(owner), FileAccess.READ)
	_check(stats_file != null and stats_file.get_as_text().contains("37"), "local BEST record is persisted")


func _run_b_verify(title: Node, owner: String) -> void:
	_check(RunStats.get_personal_best(owner) == 0, "account b starts with local BEST 0")
	_check(LeaderboardManager._profile(owner)["pending"].is_empty(), "account b cannot read account a pending queue")
	var arena := await _open_arena(title)
	if arena == null or LeaderboardManager.get_run_status().get("status") != "RANKED":
		return
	_last_mark_ms = Time.get_ticks_msec()
	await _record_milestones(1)
	var snapshot := RunStats.get_run_snapshot()
	_check(int(snapshot.get("elapsed_ms", 0)) >= int(snapshot.get("milestone_ms", [0])[-1]) and int(snapshot.get("milestone_ms", [0])[0]) >= 1, "b-verify milestone has positive wall-clock timing")
	arena.kills = 12
	arena._end_run(false)
	var uploaded := await _wait_for(func() -> bool: return LeaderboardManager.get_run_status().get("status") == "UPLOADED", 15.0)
	_check(uploaded, "account b result uploads successfully")
	LeaderboardManager.fetch_board(true)
	var loaded := await _wait_for(func() -> bool: return not LeaderboardManager.get_board_state().get("loading", true), 15.0)
	var entries: Array = LeaderboardManager.get_board_state().get("entries", [])
	_check(loaded and entries.size() == 1, "board contains only b while a result is offline")
	LeaderboardManager.fetch_personal()
	await _wait_for(func() -> bool: return not LeaderboardManager.get_personal_state().get("loading", true), 15.0)
	var personal: Dictionary = LeaderboardManager.get_personal_state()
	var best: Dictionary = personal.get("best", {})
	if entries.size() == 1:
		_check(entries[0].get("entry_id") == best.get("entry_id") and best.get("entry_id") != owner and entries[0].get("progress") == 1, "board row matches b personal entry id, distinct from account id")
	_check(RunStats.get_personal_best(owner) == 12, "account b local BEST is 12")


func _run_a_retry(owner: String) -> void:
	_check(LeaderboardManager._profile(owner)["pending"].size() == 1, "account a pending result restored on restart")
	_check(RunStats.get_personal_best(owner) == 37, "account a local BEST survives restart")
	var dropped := await _wait_for_dropped_result(owner)
	_check(dropped, "fixture accepted result but dropped one response; queue remains pending")
	LeaderboardManager.retry_pending_now()
	var removed := await _wait_for(func() -> bool: return LeaderboardManager._profile(owner)["pending"].is_empty(), 15.0)
	_check(removed, "idempotent retry removes pending result")
	var refreshed := await _wait_for_fixture_count("/api/v1/auth/refresh", 1, 15.0)
	_check(refreshed, "401 triggers one normal session refresh")
	LeaderboardManager.fetch_board(true)
	await _wait_for(func() -> bool: return not LeaderboardManager.get_board_state().get("loading", true), 15.0)
	var board: Dictionary = LeaderboardManager.get_board_state()
	var entries: Array = board.get("entries", [])
	_check(entries.size() == 2, "board has one best entry for each account")
	LeaderboardManager.fetch_personal()
	await _wait_for(func() -> bool: return not LeaderboardManager.get_personal_state().get("loading", true), 15.0)
	var personal: Dictionary = LeaderboardManager.get_personal_state()
	var personal_best: Dictionary = personal.get("best", {})
	var a_row: Dictionary = {}
	var b_row: Dictionary = {}
	for entry in entries:
		if entry.get("progress") == 2:
			a_row = entry
		elif entry.get("progress") == 1:
			b_row = entry
	_check(personal_best.get("entry_id", "") != owner and personal_best.get("rank", 0) == 1 and a_row.get("entry_id", "") == personal_best.get("entry_id"), "account a personal rank one matches its distinct board entry id")
	_check(a_row.get("rank", 0) == 1 and a_row.get("progress") == 2 and b_row.get("rank", 0) == 2 and b_row.get("progress") == 1 and b_row.get("entry_id", "") != _user_id("b") and a_row.get("entry_id") != b_row.get("entry_id"), "both accounts have distinct ranked entries by progress")
	_check(RunStats.get_personal_best(owner) == 37, "server statistics preserve personal BEST 37")
	var summary := await _fixture_summary()
	_check(int(summary.get("accepted_runs", -1)) == 2 and int(summary.get("best_entries", -1)) == 2, "fixture confirms idempotent run and two BEST rows")


func _run_c_verify(title: Node, owner: String) -> void:
	var synced := await _wait_for(func() -> bool: return RunStats.get_personal_best(owner) == 37, 15.0)
	_check(synced, "fresh account a profile downloads BEST 37")
	LeaderboardManager.fetch_board(true)
	await _wait_for(func() -> bool: return not LeaderboardManager.get_board_state().get("loading", true), 15.0)
	LeaderboardManager.fetch_personal()
	await _wait_for(func() -> bool: return not LeaderboardManager.get_personal_state().get("loading", true), 15.0)
	var personal: Dictionary = LeaderboardManager.get_personal_state()
	var best: Dictionary = personal.get("best", {})
	_check(best.get("entry_id", "") != owner and best.get("rank", 0) == 1, "fresh account a profile reads personal rank one with distinct entry id")
	var entries: Array = LeaderboardManager.get_board_state().get("entries", [])
	_check(entries.size() == 2, "fresh profile reads both board entries")
	if entries.size() == 2:
		var matching_rows := entries.filter(func(row: Dictionary) -> bool: return row.get("entry_id") == best.get("entry_id"))
		_check(entries[0].get("player_name") == "联调玩家" and entries[1].get("player_name") == "联调玩家" and entries[0].get("entry_id") != entries[1].get("entry_id") and entries[0].get("entry_id") != owner and entries[1].get("entry_id") != owner and matching_rows.size() == 1, "same display names remain distinct and personal best maps by entry id")
	if OS.get_cmdline_user_args().has("--capture-previews"):
		await _capture_board(title)
	await _exercise_account_switch()


func _exercise_delayed_grant() -> void:
	var before := await _fixture_summary()
	var prior_count := int(before.get("counts", {}).get("/api/v1/ranked-runs", 0))
	var control := await _control("delay_grant_once")
	if not _check(int(control.get("status", 0)) == 200, "fixture armed one delayed grant"):
		return
	LeaderboardManager.begin_run(false)
	var reached := await _wait_for_fixture_count("/api/v1/ranked-runs", prior_count + 1, 8.0)
	_check(reached, "delayed grant request reaches fixture")
	LeaderboardManager.seal_run()
	await _wait_duration(2.1)
	_check(LeaderboardManager.get_run_status().get("status") == "NOT RANKED" and LeaderboardManager._run.get("grant", {}).is_empty(), "late grant after seal cannot rank the run")


func _exercise_account_switch() -> void:
	var before := await _fixture_summary()
	var prior_count := int(before.get("counts", {}).get("/api/v1/me/leaderboard", 0))
	var control := await _control("delay_personal_once")
	if not _check(int(control.get("status", 0)) == 200, "fixture armed one delayed personal response"):
		return
	LeaderboardManager.fetch_personal()
	var reached := await _wait_for_fixture_count("/api/v1/me/leaderboard", prior_count + 1, 8.0)
	_check(reached, "delayed a personal request reaches fixture")
	_auth_expected = "logout"
	_auth_done = false
	_auth_ok = false
	AuthManager.request_finished.connect(_on_auth_finished)
	AuthManager.logout()
	var logged_out := await _wait_for(func() -> bool: return _auth_done, 10.0)
	AuthManager.request_finished.disconnect(_on_auth_finished)
	_check(logged_out and _auth_ok and not AuthManager.authenticated, "logout completes before switching accounts")
	var b: Dictionary = _config.get("users", {}).get("b", {})
	if not await _login(str(b.get("email", "")), str(b.get("password", ""))):
		_check(false, "account b login succeeds after account a logout")
		return
	await _wait_duration(2.1)
	_check(LeaderboardManager._identity == str(b.get("id", "")) and LeaderboardManager.get_personal_state().get("best", {}).is_empty(), "late account a response cannot populate account b state")
	LeaderboardManager.fetch_personal()
	await _wait_for(func() -> bool: return not LeaderboardManager.get_personal_state().get("loading", true), 15.0)
	var best: Dictionary = LeaderboardManager.get_personal_state().get("best", {})
	_check(best.get("rank", 0) == 2 and best.get("entry_id", "") != str(b.get("id", "")), "account b personal view remains account scoped")


func _capture_board(title: Node) -> void:
	title.open_leaderboard()
	var preview_ready := await _wait_for(func() -> bool: return title._leaderboard_open, 5.0)
	if not preview_ready:
		_check(false, "online leaderboard panel opens for preview")
		return
	await _wait_for(func() -> bool: return not LeaderboardManager.get_board_state()["loading"] and not LeaderboardManager.get_personal_state()["loading"], 15.0)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "build/previews/leaderboard/online-local-test.png"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var error := get_viewport().get_texture().get_image().save_png(ProjectSettings.globalize_path(path))
	_check(error == OK, "optional local integration preview is saved")
	title._leaderboard.close()


func _user_id(key: String) -> String:
	return str(_config.get("users", {}).get(key, {}).get("id", ""))


func _control(action: String) -> Dictionary:
	var result := await _http_json(str(_config["api"]).trim_suffix("/api/v1") + "/_test/control", HTTPClient.METHOD_POST, {"key": _config["control_key"], "action": action})
	return result


func _fixture_summary() -> Dictionary:
	var url := str(_config["api"]).trim_suffix("/api/v1") + "/_test/summary?key=" + str(_config["control_key"]).uri_encode()
	return await _http_json(url, HTTPClient.METHOD_GET, {})


func _wait_for_dropped_result(owner: String) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		var summary := await _fixture_summary()
		var counts: Dictionary = summary.get("counts", {})
		var result_count := int(counts.get("/api/v1" + "/ranked-runs/:id/result", 0))
		if result_count >= _prior_result_count + 1 and not LeaderboardManager._active.has("submit") and LeaderboardManager._profile(owner)["pending"].size() == 1:
			return true
		await get_tree().process_frame
	return false


func _wait_for_fixture_count(path: String, minimum: int, timeout_seconds: float = 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var summary := await _fixture_summary()
		if int(summary.get("counts", {}).get(path, 0)) >= minimum:
			return true
		await get_tree().process_frame
	return false


func _wait_duration(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _http_json(url: String, method: int, payload: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()
	http.process_mode = Node.PROCESS_MODE_ALWAYS
	http.timeout = 8.0
	http.max_redirects = 0
	add_child(http)
	var received := {"done": false, "result": -1, "status": 0, "body": PackedByteArray()}
	http.request_completed.connect(func(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
		received["done"] = true
		received["result"] = result
		received["status"] = status
		received["body"] = body
	, CONNECT_ONE_SHOT)
	var error := http.request(url, PackedStringArray(["Content-Type: application/json", "Accept: application/json"]), method, "" if method == HTTPClient.METHOD_GET else JSON.stringify(payload))
	if error == OK:
		await _wait_for(func() -> bool: return received["done"], 15.0)
	var parsed: Variant = JSON.parse_string(received["body"].get_string_from_utf8()) if received["done"] else {}
	var response: Dictionary = parsed if parsed is Dictionary else {}
	response["status"] = int(received["status"])
	response["request_error"] = error
	http.queue_free()
	return response


func _wait_for(predicate: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await get_tree().process_frame
	return bool(predicate.call())


func _check(condition: bool, label: String) -> bool:
	_checks += 1
	if not condition:
		_failures.append(label)
		push_error("[%s] %s" % [_role, label])
	return condition


func _finish() -> void:
	if _failures.is_empty():
		print("leaderboard_client_test role=%s checks=%d passed" % [_role, _checks])
	else:
		push_error("leaderboard_client_test role=%s checks=%d failed=%d: %s" % [_role, _checks, _failures.size(), "; ".join(_failures)])
	get_tree().quit(1 if not _failures.is_empty() else 0)
