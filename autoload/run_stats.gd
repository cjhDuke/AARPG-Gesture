extends Node
## 按身份持久化击杀最佳与单局进度计时；由 LeaderboardManager 同步线上统计。

signal stats_changed()
signal personal_best_changed(owner_id: String, value: int)

const RULESET_ID := "survival_v1"
const DATA_VERSION := 1
const MAX_FILE_BYTES := 4096
const MAX_KILLS := 2147483647
const GUEST_PATH := "user://stats/guest.json"
const ACCOUNT_DIR := "user://stats/accounts"

var last_error: String = ""

var best_kills: int:
	get:
		if _run_active:
			return 0 if _run_practice else _best_for_identity(_run_identity)
		if LevelManager.practice_mode:
			return 0
		return _best_for_identity(_current_identity())

var _best_by_identity: Dictionary = {}
var _run_active := false
var _run_identity := "guest"
var _run_name := "GUEST"
var _run_practice := false
var _continued := false
var _progress := 0
var _elapsed_usec := 0
var _last_tick_usec := 0
var _was_paused := false
var _timing_active := false
var _milestone_ms: Array[int] = []
var _kills := 0
var _new_best := false
var _last_result: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not AuthManager.session_changed.is_connected(_on_session_changed):
		AuthManager.session_changed.connect(_on_session_changed)
	if not LevelManager.practice_mode:
		_best_for_identity(_current_identity())


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var paused := get_tree().paused
	if _timing_active and not _was_paused and not paused and _last_tick_usec > 0:
		_elapsed_usec += maxi(now - _last_tick_usec, 0)
	_last_tick_usec = now
	_was_paused = paused


func update_best_kills(value: int) -> void:
	if value < 0 or value > MAX_KILLS:
		return
	if not _run_active:
		begin_run(false)
	if _run_practice:
		_kills = maxi(_kills, value)
		return
	_kills = maxi(_kills, value)
	var previous := _best_for_identity(_run_identity)
	if value <= previous:
		return
	if _write_record(_run_identity, value):
		_best_by_identity[_run_identity] = value
		_new_best = true
		personal_best_changed.emit(_run_identity, value)
		stats_changed.emit()


func begin_run(continued: bool = false, starting_progress: int = 0) -> void:
	_finish_timing_interval()
	_run_active = true
	_run_identity = _current_identity()
	_run_name = (AuthManager.username if not AuthManager.username.is_empty() else "Player") if _run_identity != "guest" else "GUEST"
	_run_practice = LevelManager.practice_mode
	_continued = continued
	_progress = clampi(starting_progress, 0, 9)
	_elapsed_usec = 0
	_milestone_ms.clear()
	_kills = 0
	_new_best = false
	_timing_active = false
	_last_tick_usec = Time.get_ticks_usec()
	_was_paused = get_tree().paused
	_last_result.clear()
	if not _run_practice:
		_best_for_identity(_run_identity)
	stats_changed.emit()


func set_timing_active(active: bool) -> void:
	_finish_timing_interval()
	_timing_active = active and _run_active and _progress < 9
	_last_tick_usec = Time.get_ticks_usec()
	_was_paused = get_tree().paused


func record_milestone(index: int) -> void:
	if not _run_active or index != _progress + 1 or index < 1 or index > 9:
		return
	_finish_timing_interval()
	_progress = index
	_milestone_ms.append(_elapsed_ms())
	if index == 9:
		_timing_active = false
	_last_tick_usec = Time.get_ticks_usec()
	stats_changed.emit()


func finish_run(victory: bool, kills: int) -> Dictionary:
	if not _last_result.is_empty() and not _run_active:
		return _last_result.duplicate(true)
	if not _run_active:
		begin_run(false)
	_finish_timing_interval()
	_timing_active = false
	_kills = clampi(kills, 0, MAX_KILLS)
	if not _run_practice and _kills > _best_for_identity(_run_identity):
		if _write_record(_run_identity, _kills):
			_best_by_identity[_run_identity] = _kills
			_new_best = true
			personal_best_changed.emit(_run_identity, _kills)
	_last_result = _make_snapshot(victory)
	_run_active = false
	stats_changed.emit()
	return _last_result.duplicate(true)


func abandon_run() -> void:
	_finish_timing_interval()
	_timing_active = false
	_run_active = false
	_last_tick_usec = 0
	stats_changed.emit()


func get_run_snapshot() -> Dictionary:
	return _make_snapshot(false) if _run_active else {}


func get_last_result() -> Dictionary:
	return _last_result.duplicate(true)


func get_run_owner_id() -> String:
	return _run_identity if _run_active else _current_identity()


func get_personal_best(owner_id: String = "") -> int:
	var identity := owner_id
	if identity.is_empty():
		identity = _run_identity if _run_active else _current_identity()
	if identity == "guest" or not _is_uuid(identity):
		return 0 if identity != "guest" else _best_for_identity("guest")
	return _best_for_identity(identity.to_lower())


func merge_remote_best(owner_id: String, value: int) -> bool:
	last_error = ""
	if LevelManager.practice_mode or not AuthManager.authenticated or not _is_uuid(owner_id) or owner_id.to_lower() != AuthManager.user_id.to_lower():
		last_error = "Remote statistics do not belong to the active account."
		return false
	if value < 0 or value > MAX_KILLS:
		last_error = "Remote personal best is invalid."
		return false
	var identity := owner_id.to_lower()
	var previous := _best_for_identity(identity)
	if value <= previous:
		return true
	if not _write_record(identity, value):
		return false
	_best_by_identity[identity] = value
	stats_changed.emit()
	return true


func format_time(ms: int) -> String:
	var total_seconds := maxi(ms, 0) / 1000
	var minutes := total_seconds / 60
	var seconds := total_seconds % 60
	var millis := maxi(ms, 0) % 1000
	return "%02d:%02d.%03d" % [minutes, seconds, millis]


func _finish_timing_interval() -> void:
	var now := Time.get_ticks_usec()
	var paused := get_tree().paused
	if _timing_active and not _was_paused and not paused and _last_tick_usec > 0:
		_elapsed_usec += maxi(now - _last_tick_usec, 0)
	_last_tick_usec = now
	_was_paused = paused


func _elapsed_ms() -> int:
	return int(_elapsed_usec / 1000)


func _make_snapshot(victory: bool) -> Dictionary:
	var rank_time := int(_milestone_ms[-1]) if not _milestone_ms.is_empty() else 0
	var reason := "PRACTICE MODE" if _run_practice else "CONTINUED RUN" if _continued else "ONLINE RANKING NOT AVAILABLE"
	return {
		"progress": _progress,
		"elapsed_ms": _elapsed_ms(),
		"rank_time_ms": rank_time,
		"milestone_ms": _milestone_ms.duplicate(),
		"continued": _continued,
		"practice": _run_practice,
		"kills": _kills,
		"best_kills": 0 if _run_practice else _best_for_identity(_run_identity),
		"new_best_kills": _new_best,
		"victory": victory,
		"ranking_status": "NOT RANKED",
		"ranking_reason": reason,
		"ruleset_id": RULESET_ID,
		"player_name": _run_name,
		"owner_id": _run_identity,
	}


func _current_identity() -> String:
	if AuthManager.authenticated and _is_uuid(AuthManager.user_id):
		return AuthManager.user_id.to_lower()
	return "guest"


func _is_uuid(value: String) -> bool:
	return RegEx.create_from_string("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$").search(value) != null


func _path_for_identity(identity: String) -> String:
	if identity == "guest":
		return GUEST_PATH
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(identity.to_utf8_buffer())
	return ACCOUNT_DIR.path_join(context.finish().hex_encode() + ".json")


func _best_for_identity(identity: String) -> int:
	if _best_by_identity.has(identity):
		return int(_best_by_identity[identity])
	last_error = ""
	var best := 0
	var path := _path_for_identity(identity)
	if FileAccess.file_exists(path):
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			last_error = "Unable to read local statistics."
		else:
			var bytes := file.get_length()
			var parsed: Variant = null
			var parse_ok := false
			if bytes <= MAX_FILE_BYTES:
				var parser := JSON.new()
				parse_ok = parser.parse(file.get_as_text()) == OK
				if parse_ok:
					parsed = parser.data
			file.close()
			if not parse_ok or not _valid_record(parsed):
				last_error = "Local statistics file is invalid."
			else:
				best = int(parsed["best_kills"])
				last_error = ""
	_best_by_identity[identity] = best
	return best


func _valid_record(value: Variant) -> bool:
	if not (value is Dictionary) or value.size() != 2:
		return false
	var version: Variant = value.get("version")
	var best: Variant = value.get("best_kills")
	if version is bool or best is bool:
		return false
	if not (version is int or version is float) or not (best is int or best is float):
		return false
	if not is_finite(float(version)) or not is_finite(float(best)):
		return false
	if floor(float(version)) != float(version) or floor(float(best)) != float(best):
		return false
	return int(version) == DATA_VERSION and float(best) >= 0.0 and float(best) <= float(MAX_KILLS)


func _write_record(identity: String, best: int) -> bool:
	var path := _path_for_identity(identity)
	var directory := path.get_base_dir()
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	if err != OK and err != ERR_ALREADY_EXISTS:
		last_error = "Unable to create local statistics directory."
		return false
	var temp_path := path + ".tmp"
	var temp := FileAccess.open(temp_path, FileAccess.WRITE)
	if temp == null:
		last_error = "Unable to write local statistics."
		return false
	temp.store_string(JSON.stringify({"version": DATA_VERSION, "best_kills": best}))
	temp.flush()
	var write_error := temp.get_error()
	temp.close()
	if write_error != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
		last_error = "Unable to flush local statistics."
		return false
	var absolute_temp := ProjectSettings.globalize_path(temp_path)
	if DirAccess.rename_absolute(absolute_temp, ProjectSettings.globalize_path(path)) != OK:
		DirAccess.remove_absolute(absolute_temp)
		last_error = "Unable to replace local statistics."
		return false
	last_error = ""
	return true


func _on_session_changed() -> void:
	if not _run_active and not LevelManager.practice_mode:
		_best_for_identity(_current_identity())
	stats_changed.emit()


func _exit_tree() -> void:
	_finish_timing_interval()
