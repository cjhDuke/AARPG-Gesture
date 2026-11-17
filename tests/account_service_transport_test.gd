extends Node

## Isolated API contract checks. Does not issue network requests or touch user:// records.
var _failed := false

func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	AudioServer.set_bus_mute(0, true)
	if not OS.get_environment("APPDATA").replace("\\", "/").contains("/.stage3_checks/"):
		get_tree().quit(2)
		return
	var http := HTTPRequest.new()
	get_tree().root.add_child(http)
	var checks := 0
	_expect(AuthManager._is_service_route("/ranked-runs", HTTPClient.METHOD_POST, true), "start run route")
	checks += 1
	_expect(AuthManager._is_service_route("/ranked-runs/123e4567-e89b-12d3-a456-426614174000/result", HTTPClient.METHOD_PUT, true), "submit result route")
	checks += 1
	_expect(AuthManager._is_service_route("/leaderboards?ruleset_id=survival_v1&cursor=abc-1", HTTPClient.METHOD_GET, false), "public leaderboard query")
	checks += 1
	_expect(AuthManager._is_service_route("/me/leaderboard?ruleset_id=survival_v1", HTTPClient.METHOD_GET, true), "authenticated personal leaderboard query")
	checks += 1
	_expect(not AuthManager._is_service_route("/me/leaderboard?ruleset_id=survival_v1", HTTPClient.METHOD_GET, false), "personal leaderboard is not public")
	checks += 1
	_expect(not AuthManager._is_service_route("https://example.com/me", HTTPClient.METHOD_GET, true), "external URL rejected")
	checks += 1
	_expect(not AuthManager._is_service_route("/auth/login", HTTPClient.METHOD_POST, true), "auth endpoint rejected")
	checks += 1
	_expect(not AuthManager._is_service_route("/leaderboards/../me/stats", HTTPClient.METHOD_GET, false), "path traversal rejected")
	checks += 1
	_expect(not AuthManager._is_service_route("/leaderboards?next=https://example.com", HTTPClient.METHOD_GET, false), "arbitrary query rejected")
	checks += 1
	_expect(AuthManager.send_service_request(http, "/auth/login", HTTPClient.METHOD_POST, {}) == ERR_INVALID_PARAMETER, "invalid route does not issue request")
	checks += 1
	var wrong_owner := "00000000-0000-0000-0000-000000000000"
	if AuthManager.user_id.to_lower() == wrong_owner:
		wrong_owner = "11111111-1111-1111-1111-111111111111"
	_expect(RunStats.merge_remote_best(wrong_owner, 1) == false, "unverified owner merge rejected")
	checks += 1
	_expect(RunStats.last_error != "", "merge failure explains rejection")
	checks += 1
	http.queue_free()
	print("account_service_transport_test: %d checks passed" % checks)
	get_tree().quit(1 if _failed else 0)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		_failed = true
		push_error("FAILED: " + label)
