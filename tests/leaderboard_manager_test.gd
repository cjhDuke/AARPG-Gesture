extends Node

var checks := 0
var failures := 0


func _ready() -> void:
	_run.call_deferred()


func expect(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("MANAGER: " + message)


func _run() -> void:
	if not OS.get_environment("APPDATA").replace("\\", "/").contains("/.stage3_checks/"):
		get_tree().quit(2)
		return
	LeaderboardManager.network_enabled = false
	AuthManager.set_process(false)
	GestureInput.set_process(false)
	AudioServer.set_bus_mute(0, true)
	var manager := LeaderboardManager
	var owner := "11111111-1111-4111-8111-111111111111"
	var id := "22222222-2222-4222-8222-222222222222"
	var original := {"ruleset_id": "survival_v1", "client_version": "1.0.0", "victory": false, "kills": 37, "elapsed_ms": 125, "milestone_ms": [50, 100]}
	var parser := JSON.new()
	parser.parse(JSON.stringify(original))
	expect(manager._valid_result(parser.data), "Old client version queue remains valid")
	var normalized: Dictionary = manager._result_body(parser.data)
	expect(normalized["kills"] is int and normalized["elapsed_ms"] is int and normalized["milestone_ms"][0] is int, "Restart normalizes strict integer payload")
	expect(normalized["client_version"] == "1.0.0", "Retry preserves original credential version")
	expect(manager._write(manager._profile_path(owner), {"version": 1, "pending": [{"run_id": id, "expires_at": 1900000000, "body": original}], "best": {}}), "Save pending queue")
	var loaded: Dictionary = manager._profile(owner)
	expect(loaded["pending"].size() == 1 and loaded["pending"][0]["body"]["kills"] is int, "Actual disk queue reload normalizes numbers")
	expect(loaded["pending"][0]["body"]["ruleset_id"] == StageData.LEGACY_RULESET, "Legacy pending upload retains its original ruleset")
	var v1_entry := {"entry_id": id, "rank": 1, "player_name": "Legacy", "progress": 2, "rank_time_ms": 100, "elapsed_ms": 125, "kills": 37, "victory": false, "achieved_at": 1800000000}
	var v2_entry := {"entry_id": id, "rank": 1, "player_name": "Modern", "progress": 3, "rank_time_ms": 100, "elapsed_ms": 125, "kills": 37, "victory": false, "achieved_at": 1800000001}
	manager.select_ruleset(StageData.LEGACY_RULESET)
	manager._identity = owner
	var legacy_board_path := manager._board_cache_path()
	var legacy_personal_path := manager._personal_cache_path(owner)
	expect(manager._write(legacy_board_path, {"version": 1, "ruleset_id": StageData.LEGACY_RULESET, "entries": [v1_entry], "updated_at": 1800000000}), "Write isolated legacy board cache")
	var legacy_profile: Dictionary = manager._profile(owner)
	legacy_profile["best"] = v1_entry
	expect(manager._save_profile(owner), "Write isolated legacy personal cache")
	manager.select_ruleset(StageData.CURRENT_RULESET)
	var current_board_path := manager._board_cache_path()
	var current_personal_path := manager._personal_cache_path(owner)
	expect(current_board_path != legacy_board_path and current_personal_path != legacy_personal_path, "Rulesets use separate public and personal cache files")
	expect(manager._write(current_board_path, {"version": 1, "ruleset_id": StageData.CURRENT_RULESET, "entries": [v2_entry], "updated_at": 1800000001}), "Write isolated current board cache")
	expect(manager._write(current_personal_path, v2_entry), "Write isolated current personal cache")
	manager._identity = owner
	manager._load_board_cache()
	manager._load_personal_cache()
	expect(manager.get_board_state()["entries"].size() == 1 and manager.get_board_state()["entries"][0]["player_name"] == "Modern", "Current board cache never displays legacy rows")
	expect(manager.get_personal_state()["best"].get("player_name") == "Modern", "Current personal cache never displays legacy best")
	manager.select_ruleset(StageData.LEGACY_RULESET)
	expect(manager.get_board_state()["entries"].size() == 1 and manager.get_board_state()["entries"][0]["player_name"] == "Legacy", "Legacy manager query can still load legacy cache")
	expect(manager.get_personal_state()["best"].get("player_name") == "Legacy", "Legacy manager query can still load legacy personal best")
	manager.select_ruleset(StageData.CURRENT_RULESET)
	manager._identity = ""
	manager._board["updated_at"] = 1800000000
	manager._board["entries"] = []
	manager.fetch_board()
	expect(manager.get_board_state()["cached"], "An empty cached leaderboard remains marked cached")
	expect(not manager._accepted({"kind": "submit", "owner": owner, "run_id": id}, {"accepted": true, "run_id": id, "ruleset_id": "survival_v1", "progress": 2, "rank_time_ms": 100}), "Incomplete success response never removes queue")
	expect(manager._profile(owner)["pending"].size() == 1, "Invalid success retains pending result")
	var wrong_ack := {"accepted": true, "run_id": id, "ruleset_id": "survival_v1", "progress": 1, "rank_time_ms": 50, "improved": true, "best": null}
	expect(not manager._accepted({"kind": "submit", "owner": owner, "run_id": id, "body": original}, wrong_ack), "Success must confirm the exact submitted milestone sequence")
	expect(manager._profile(owner)["pending"].size() == 1, "Mismatched confirmation retains pending result")
	RunStats.begin_run()
	manager.begin_run()
	manager.seal_run()
	var grant := {"run_id": id, "ruleset_id": "survival_v1", "client_version": manager.CLIENT_VERSION, "issued_at": 1800000000, "expires_at": 1800086400, "server_time": 1800000000}
	manager._accepted({"kind": "grant", "owner": "guest", "serial": manager._serial}, grant)
	expect(manager.get_run_status()["status"] == "NOT RANKED" and manager._run["grant"].is_empty(), "Late grant cannot qualify an already started wave")
	var bad_owner := "33333333-3333-4333-8333-333333333333"
	var path: String = manager._profile_path(bad_owner)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("{damaged")
	file.close()
	manager._profile(bad_owner)
	expect(not manager._save_profile(bad_owner), "Damaged queue cannot be silently overwritten")
	expect(FileAccess.get_file_as_string(path) == "{damaged", "Original damaged upload file is preserved")
	print("LEADERBOARD_MANAGER_TEST checks=%d failures=%d" % [checks, failures])
	get_tree().quit(0 if failures == 0 else 1)
