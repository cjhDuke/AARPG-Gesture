extends Node
## 排名凭证、账号最佳同步与按账号隔离的持久补交队列。

signal board_changed()
signal personal_changed()
signal run_status_changed()

const RULESET := "survival_v1"
const CLIENT_VERSION := "1.1.0"
const ROOT := "user://leaderboard"
const MAX_BYTES := 65536
const MAX_PENDING := 64

var network_enabled := true
var last_error := ""
var _identity := ""
var _epoch := 0
var _profiles: Dictionary = {}
var _broken_profiles: Dictionary = {}
var _active: Dictionary = {}
var _retries: Dictionary = {}
var _serial := 0
var _run: Dictionary = {}
var _stats_due := 0
var _submit_due := 0
var _board: Dictionary = {"entries": [], "loading": false, "error": "", "next_cursor": "", "cached": false, "updated_at": 0}
var _personal: Dictionary = {"best": {}, "neighbors": [], "loading": false, "error": ""}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	network_enabled = not (OS.is_debug_build() and OS.get_cmdline_user_args().has("--leaderboard-offline"))
	if LevelManager.practice_mode:
		return
	_load_board_cache()
	AuthManager.session_changed.connect(_on_session_changed)
	RunStats.personal_best_changed.connect(_on_local_best)
	_on_session_changed()


func _process(_delta: float) -> void:
	if not network_enabled or LevelManager.practice_mode:
		return
	for kind in _retries.keys():
		var job: Dictionary = _retries[kind]
		if kind == "grant" and (bool(_run.get("sealed", true)) or int(job["serial"]) != _serial):
			_retries.erase(kind)
			continue
		if int(job["epoch"]) == _epoch and AuthManager.authenticated and not AuthManager.busy:
			_retries.erase(kind)
			_request(job)
	if not _run.is_empty() and not bool(_run.get("sealed", true)) and str(_run.get("status")) == "PREPARING" and not _active.has("grant") and not _retries.has("grant"):
		_prepare_grant()
	if _identity.is_empty() or not AuthManager.authenticated or AuthManager.busy:
		return
	var now := Time.get_ticks_msec()
	if now >= _stats_due and not _active.has("stats") and not _retries.has("stats"):
		_stats_due = now + 30000
		_send("stats", "/me/stats", HTTPClient.METHOD_GET, {}, _identity)
	if now >= _submit_due and not _active.has("submit") and not _retries.has("submit"):
		_submit_due = now + 30000
		var profile := _profile(_identity)
		if not profile["pending"].is_empty():
			var item: Dictionary = profile["pending"][0]
			_send("submit", "/ranked-runs/" + item["run_id"] + "/result", HTTPClient.METHOD_PUT, item["body"], _identity, {"run_id": item["run_id"]})


func begin_run(continued: bool = false) -> void:
	_serial += 1
	_cancel("grant")
	_retries.erase("grant")
	var owner := RunStats.get_run_owner_id()
	var reason := "CONTINUED RUN" if continued else "SIGN IN BEFORE START"
	if LevelManager.practice_mode:
		reason = "PRACTICE MODE"
	_run = {"owner": owner, "serial": _serial, "sealed": false, "grant": {}, "status": "NOT RANKED", "reason": reason, "rank": 0, "result_id": ""}
	if not continued and not LevelManager.practice_mode and network_enabled and AuthManager.authenticated and owner == AuthManager.user_id:
		_run["status"] = "PREPARING"
		_run["reason"] = "CHECKING ONLINE START"
		_run["operation_id"] = _uuid()
		_prepare_grant()
	run_status_changed.emit()


func _prepare_grant() -> void:
	if _run.is_empty() or bool(_run["sealed"]) or _run["owner"] != _identity:
		return
	_send("grant", "/ranked-runs", HTTPClient.METHOD_POST,
		{"operation_id": _run["operation_id"], "ruleset_id": RULESET, "client_version": CLIENT_VERSION},
		str(_run["owner"]), {"serial": _serial})


func seal_run() -> void:
	if _run.is_empty() or bool(_run["sealed"]):
		return
	_run["sealed"] = true
	if _run["grant"].is_empty() and str(_run["status"]) == "PREPARING":
		_set_status("NOT RANKED", "ONLINE START UNAVAILABLE")
	_cancel("grant")
	_retries.erase("grant")


func abandon_run() -> void:
	seal_run()
	_serial += 1
	_run = {}
	run_status_changed.emit()


func finish_run(snapshot: Dictionary) -> void:
	seal_run()
	if _run.is_empty() or _run["grant"].is_empty() or str(_run["status"]) != "RANKED":
		return
	var body := {"ruleset_id": RULESET, "client_version": CLIENT_VERSION,
		"victory": snapshot.get("victory", false), "kills": snapshot.get("kills", 0),
		"elapsed_ms": snapshot.get("elapsed_ms", 0), "milestone_ms": snapshot.get("milestone_ms", [])}
	if not _valid_result(body) or snapshot.get("continued", false) or snapshot.get("practice", false):
		_set_status("NOT RANKED", "INVALID RUN TIMES")
		return
	var owner := str(_run["owner"])
	var profile := _profile(owner)
	if profile["pending"].size() >= MAX_PENDING:
		_set_status("NOT RANKED", "UPLOAD QUEUE FULL")
		return
	var run_id := str(_run["grant"]["run_id"])
	profile["pending"].append({"run_id": run_id, "expires_at": _run["grant"]["expires_at"], "body": body})
	if not _save_profile(owner):
		profile["pending"].pop_back()
		_set_status("NOT RANKED", "COULD NOT SAVE RESULT")
		return
	_run["result_id"] = run_id
	_set_status("PENDING", "WAITING TO UPLOAD")
	_submit_due = 0


func get_run_status() -> Dictionary:
	return {"status": _run.get("status", "NOT RANKED"), "reason": _run.get("reason", "START A NEW RUN"), "rank": _run.get("rank", 0), "run_id": _run.get("result_id", "")}


func _set_status(status: String, reason: String, rank: int = 0) -> void:
	if _run.is_empty():
		return
	_run["status"] = status
	_run["reason"] = reason
	_run["rank"] = rank
	run_status_changed.emit()


func fetch_board(refresh: bool = true) -> void:
	if _active.has("board") or bool(_board["loading"]):
		return
	if LevelManager.practice_mode or not network_enabled:
		_board["error"] = "Network unavailable"
		_board["cached"] = int(_board["updated_at"]) > 0
		board_changed.emit()
		return
	var cursor := "" if refresh else str(_board["next_cursor"])
	if not refresh and cursor.is_empty():
		return
	_board["loading"] = true
	_board["error"] = ""
	board_changed.emit()
	_send("board", "/leaderboards?ruleset_id=" + RULESET + ("&cursor=" + cursor.uri_encode() if not cursor.is_empty() else ""), HTTPClient.METHOD_GET, {}, "", {"refresh": refresh}, false)


func fetch_personal() -> void:
	if _active.has("personal") or _retries.has("personal"):
		return
	if LevelManager.practice_mode or not network_enabled or _identity.is_empty():
		_personal["error"] = "Sign in to see your rank" if _identity.is_empty() else "Network unavailable"
		personal_changed.emit()
		return
	_personal["loading"] = true
	_personal["error"] = ""
	personal_changed.emit()
	_send("personal", "/me/leaderboard?ruleset_id=" + RULESET, HTTPClient.METHOD_GET, {}, _identity)


func get_board_state() -> Dictionary:
	return _board.duplicate(true)


func get_personal_state() -> Dictionary:
	return _personal.duplicate(true)


func sync_stats_now() -> void:
	_stats_due = 0


func retry_pending_now() -> void:
	_submit_due = 0


func _on_local_best(owner: String, _value: int) -> void:
	if owner == _identity:
		_stats_due = mini(_stats_due, Time.get_ticks_msec() + 1000)


func _on_session_changed() -> void:
	var next := AuthManager.user_id if AuthManager.authenticated else ""
	if next == _identity:
		return
	_identity = next
	_epoch += 1
	for kind in _active.keys():
		if kind != "board":
			_cancel(kind)
	_retries.clear()
	_personal = {"best": {}, "neighbors": [], "loading": false, "error": ""}
	if next.is_empty() and _run.get("status", "") == "UPLOADING":
		_set_status("PENDING", "SIGN IN TO RETRY")
	if not next.is_empty():
		var profile := _profile(next)
		_personal["best"] = profile.get("best", {}).duplicate(true)
		if not _personal["best"].is_empty():
			_personal["error"] = "Cached personal rank - refresh to update"
		_stats_due = 0
		_submit_due = 0
		if not _run.is_empty() and not str(_run["owner"]).is_empty() and str(_run["owner"]) != next and _run["owner"] != "guest":
			_run["grant"] = {}
			_set_status("NOT RANKED", "ACCOUNT CHANGED")
	personal_changed.emit()


func _send(kind: String, path: String, method: int, body: Dictionary, owner: String, context: Dictionary = {}, authorized: bool = true) -> bool:
	var job := {"kind": kind, "path": path, "method": method, "body": body.duplicate(true), "owner": owner, "authorized": authorized, "epoch": _epoch, "auth_retries": 0}
	job.merge(context)
	return _request(job)


func _request(job: Dictionary) -> bool:
	var kind := str(job["kind"])
	if not network_enabled or LevelManager.practice_mode or _active.has(kind):
		return false
	var http := HTTPRequest.new()
	http.process_mode = Node.PROCESS_MODE_ALWAYS
	http.timeout = 8.0
	http.body_size_limit = MAX_BYTES
	http.max_redirects = 0
	add_child(http)
	var error := AuthManager.send_service_request(http, str(job["path"]), int(job["method"]), job["body"], str(job["owner"]), bool(job["authorized"]))
	if error != OK:
		http.queue_free()
		if error == ERR_BUSY:
			_retries[kind] = job
		else:
			_failed(job, 0, "", 30)
		return false
	job["http"] = http
	_active[kind] = job
	http.request_completed.connect(_completed.bind(kind, http))
	if kind == "submit" and _run.get("result_id", "") == job.get("run_id", "-"):
		_set_status("UPLOADING", "SENDING RESULT")
	return true


func _cancel(kind: String) -> void:
	if not _active.has(kind):
		return
	var http: HTTPRequest = _active[kind]["http"]
	_active.erase(kind)
	http.cancel_request()
	http.queue_free()


func _completed(result: int, status: int, headers: PackedStringArray, body: PackedByteArray, kind: String, http: HTTPRequest) -> void:
	if not _active.has(kind) or _active[kind]["http"] != http:
		return
	var job: Dictionary = _active[kind]
	_active.erase(kind)
	job.erase("http")
	http.queue_free()
	if bool(job["authorized"]) and (int(job["epoch"]) != _epoch or job["owner"] != _identity):
		return
	var parser := JSON.new()
	var data: Dictionary = {}
	if result == HTTPRequest.RESULT_SUCCESS and body.size() <= MAX_BYTES and parser.parse(body.get_string_from_utf8()) == OK and parser.data is Dictionary:
		data = parser.data
	if status in [401, 403] and bool(job["authorized"]) and int(job["auth_retries"]) == 0:
		job["auth_retries"] = 1
		_retries[kind] = job
		AuthManager.refresh_service_session(str(job["owner"]))
		return
	var retry := 30
	for header in headers:
		if header.to_lower().begins_with("retry-after:"):
			var value := header.get_slice(":", 1).strip_edges()
			if value.is_valid_int():
				retry = clampi(int(value), 1, 86400)
	if result == HTTPRequest.RESULT_SUCCESS and status >= 200 and status < 300 and _accepted(job, data):
		return
	var code := ""
	if data.get("error") is Dictionary:
		code = str(data["error"].get("code", ""))
	_failed(job, status, code, retry)


func _accepted(job: Dictionary, data: Dictionary) -> bool:
	var kind := str(job["kind"])
	var owner := str(job["owner"])
	if kind == "grant":
		if int(job["serial"]) != _serial or _run.is_empty() or bool(_run["sealed"]):
			return true
		if not _valid_grant(data):
			return false
		_run["grant"] = data
		_set_status("RANKED", "ONLINE START CONFIRMED")
	elif kind == "board":
		if not _valid_entries(data.get("entries"), 20) or data.get("ruleset_id") != RULESET or not _integer(data.get("generated_at"), 0, 9007199254740991):
			return false
		var cursor: Variant = data.get("next_cursor")
		if cursor != null and (not cursor is String or str(cursor).length() > 512):
			return false
		var entries: Array = [] if job["refresh"] else _board["entries"].duplicate(true)
		for row in data["entries"]:
			var found := false
			for i in entries.size():
				if entries[i]["entry_id"] == row["entry_id"]:
					entries[i] = _entry(row)
					found = true
					break
			if not found:
				entries.append(_entry(row))
		if entries.size() > 200:
			entries = entries.slice(entries.size() - 200)
		_board = {"entries": entries, "loading": false, "error": "", "next_cursor": "" if cursor == null else cursor, "cached": false, "updated_at": int(data["generated_at"])}
		if job["refresh"]:
			_write(ROOT + "/board_cache.json", {"version": 1, "ruleset_id": RULESET, "entries": entries, "updated_at": _board["updated_at"]})
		board_changed.emit()
	elif kind == "personal":
		if not data.has("best") or data.get("ruleset_id") != RULESET or not _valid_entries(data.get("neighbors"), 5) or (data.get("best") != null and not _valid_entry(data["best"])):
			return false
		var best: Dictionary = {} if data["best"] == null else _entry(data["best"])
		_personal = {"best": best, "neighbors": data["neighbors"].map(_entry), "loading": false, "error": ""}
		_profile(owner)["best"] = best
		_save_profile(owner)
		personal_changed.emit()
	elif kind == "stats":
		if not _integer(data.get("best_kills"), 0, 2147483647):
			return false
		if not RunStats.merge_remote_best(owner, int(data["best_kills"])):
			last_error = RunStats.last_error
			return false
		var local := RunStats.get_personal_best(owner)
		_stats_due = Time.get_ticks_msec() + 30000
		if local > int(data["best_kills"]):
			_send("stats", "/me/stats", HTTPClient.METHOD_PUT, {"best_kills": local}, owner)
	elif kind == "submit":
		if not data.has("best") or data.get("run_id") != job["run_id"] or not data.get("accepted") is bool or data.get("accepted") != true or data.get("ruleset_id") != RULESET or not _integer(data.get("progress"), 0, 9) or not _integer(data.get("rank_time_ms"), 0, 86400000):
			return false
		if data.get("best") != null and not _valid_entry(data["best"]):
			return false
		var times: Array = job["body"]["milestone_ms"]
		if int(data["progress"]) != times.size() or int(data["rank_time_ms"]) != (0 if times.is_empty() else int(times[-1])) or not data.get("improved") is bool:
			return false
		_remove_pending(owner, str(job["run_id"]))
		if _run.get("result_id", "") == job["run_id"]:
			_set_status("UPLOADED", "RESULT CONFIRMED", int(data["best"]["rank"]) if data["best"] != null else 0)
		_submit_due = 0
		fetch_personal()
	return true


func _failed(job: Dictionary, status: int, code: String, retry: int) -> void:
	var kind := str(job["kind"])
	var delay := Time.get_ticks_msec() + retry * 1000
	if kind == "grant":
		if int(job["serial"]) == _serial and not _run.is_empty():
			_set_status("NOT RANKED", "ONLINE START UNAVAILABLE")
	elif kind == "board":
		_board["loading"] = false
		_board["error"] = "Please wait before refreshing" if status == 429 else "Could not load leaderboard"
		_board["cached"] = int(_board["updated_at"]) > 0
		board_changed.emit()
	elif kind == "personal":
		_personal["loading"] = false
		_personal["error"] = "Could not load personal ranking"
		personal_changed.emit()
	elif kind == "stats":
		_stats_due = delay
	elif kind == "submit":
		_submit_due = delay
		var terminal := status in [400, 404, 409, 410, 413, 415, 422]
		if terminal:
			_remove_pending(str(job["owner"]), str(job["run_id"]))
		if _run.get("result_id", "") == job["run_id"]:
			_set_status("NOT RANKED" if terminal else "PENDING", "RUN EXPIRED" if status == 410 else "RESULT REJECTED" if terminal else "WILL RETRY WHEN ONLINE")


func _remove_pending(owner: String, run_id: String) -> void:
	var profile := _profile(owner)
	for i in range(profile["pending"].size() - 1, -1, -1):
		if profile["pending"][i]["run_id"] == run_id:
			profile["pending"].remove_at(i)
	_save_profile(owner)


func _profile(owner: String) -> Dictionary:
	if _profiles.has(owner):
		return _profiles[owner]
	var profile := {"version": 1, "pending": [], "best": {}}
	var data := _read(_profile_path(owner))
	var valid: bool = data.size() == 3 and _integer(data.get("version"), 1, 1) and data.get("pending") is Array and data["pending"].size() <= MAX_PENDING and data.get("best") is Dictionary and (data["best"].is_empty() or _valid_entry(data["best"]))
	if valid:
		var seen := {}
		for item in data["pending"]:
			if not item is Dictionary or item.size() != 3 or not _is_uuid(item.get("run_id")) or not _integer(item.get("expires_at"), 1, 9007199254740991) or not _valid_result(item.get("body")) or seen.has(item.get("run_id")):
				valid = false
				break
			seen[item["run_id"]] = true
			profile["pending"].append({"run_id": item["run_id"], "expires_at": int(item["expires_at"]), "body": _result_body(item["body"])})
		if _valid_entry(data.get("best")):
			profile["best"] = _entry(data["best"])
	if not valid and FileAccess.file_exists(_profile_path(owner)):
		_broken_profiles[owner] = true
		profile = {"version": 1, "pending": [], "best": {}}
		last_error = "Stored upload data is damaged; original file was preserved"
	_profiles[owner] = profile
	return profile


func _profile_path(owner: String) -> String:
	return ROOT + "/" + owner.sha256_text() + ".json"


func _save_profile(owner: String) -> bool:
	if _broken_profiles.has(owner):
		last_error = "Stored upload data is damaged; original file was preserved"
		return false
	return _write(_profile_path(owner), _profile(owner))


func _load_board_cache() -> void:
	var data := _read(ROOT + "/board_cache.json")
	if data.get("version") == 1 and data.get("ruleset_id") == RULESET and _valid_entries(data.get("entries"), 20) and _integer(data.get("updated_at"), 0, 9007199254740991):
		_board["entries"] = data["entries"].map(_entry)
		_board["updated_at"] = int(data["updated_at"])
		_board["cached"] = true


func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > MAX_BYTES:
		return {}
	var parser := JSON.new()
	return parser.data if parser.parse(file.get_as_text()) == OK and parser.data is Dictionary else {}


func _write(path: String, data: Dictionary) -> bool:
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		last_error = "Cannot create ranking data folder"
		return false
	var contents := JSON.stringify(data)
	if contents.to_utf8_buffer().size() > MAX_BYTES:
		last_error = "Ranking data is too large"
		return false
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		last_error = "Cannot save ranking data"
		return false
	file.store_string(contents)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or DirAccess.rename_absolute(path + ".tmp", path) != OK:
		DirAccess.remove_absolute(path + ".tmp")
		last_error = "Cannot replace ranking data"
		return false
	last_error = ""
	return true


func _integer(value: Variant, low: int, high: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value)) and float(value) >= low and float(value) <= high


func _is_uuid(value: Variant) -> bool:
	return value is String and RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$").search(value) != null


func _uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 15) | 64
	bytes[8] = (bytes[8] & 63) | 128
	var text := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [text.substr(0, 8), text.substr(8, 4), text.substr(12, 4), text.substr(16, 4), text.substr(20)]


func _valid_grant(data: Dictionary) -> bool:
	return _is_uuid(data.get("run_id")) and data.get("ruleset_id") == RULESET and data.get("client_version") == CLIENT_VERSION and _integer(data.get("issued_at"), 1, 9007199254740991) and _integer(data.get("server_time"), 1, 9007199254740991) and _integer(data.get("expires_at"), 1, 9007199254740991) and int(data["expires_at"]) - int(data["issued_at"]) == 86400


func _valid_result(value: Variant) -> bool:
	if not value is Dictionary or value.get("ruleset_id") != RULESET or not value.get("client_version") is String or RegEx.create_from_string("^[A-Za-z0-9._+-]{1,32}$").search(value["client_version"]) == null or not value.get("victory") is bool or not _integer(value.get("kills"), 0, 2147483647) or not _integer(value.get("elapsed_ms"), 0, 86400000) or not value.get("milestone_ms") is Array:
		return false
	var times: Array = value["milestone_ms"]
	if times.size() > 9 or bool(value["victory"]) != (times.size() == 9):
		return false
	var previous := 0
	for time in times:
		if not _integer(time, 1, int(value["elapsed_ms"])) or int(time) < previous:
			return false
		previous = int(time)
	return not bool(value["victory"]) or previous == int(value["elapsed_ms"])


func _result_body(value: Dictionary) -> Dictionary:
	var times: Array[int] = []
	for time in value["milestone_ms"]:
		times.append(int(time))
	return {"ruleset_id": RULESET, "client_version": str(value["client_version"]), "victory": bool(value["victory"]), "kills": int(value["kills"]), "elapsed_ms": int(value["elapsed_ms"]), "milestone_ms": times}


func _valid_entries(value: Variant, limit: int) -> bool:
	if not value is Array or value.size() > limit:
		return false
	for row in value:
		if not _valid_entry(row):
			return false
	return true


func _valid_entry(value: Variant) -> bool:
	return value is Dictionary and _is_uuid(value.get("entry_id")) and value.get("player_name") is String and str(value["player_name"]).length() <= 24 and _integer(value.get("rank"), 1, 9007199254740991) and _integer(value.get("progress"), 1, 9) and _integer(value.get("rank_time_ms"), 1, 86400000) and _integer(value.get("elapsed_ms"), int(value.get("rank_time_ms", 0)), 86400000) and _integer(value.get("kills"), 0, 2147483647) and value.get("victory") is bool and bool(value["victory"]) == (int(value["progress"]) == 9) and _integer(value.get("achieved_at"), 0, 9007199254740991)


func _entry(value: Dictionary) -> Dictionary:
	var result := {}
	for key in ["entry_id", "rank", "player_name", "progress", "rank_time_ms", "elapsed_ms", "kills", "victory", "achieved_at"]:
		result[key] = value[key]
	return result
