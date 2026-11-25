extends Node

const SESSION_ENV := "AARPG_UPDATE_SESSION"
const POLL_INTERVAL := 0.1
const MAX_STATUS_BYTES := 256 * 1024
const STATES := ["checking", "current", "available", "downloading", "ready", "error"]

signal state_changed(snapshot: Dictionary)

var _session_dir := ""
var _status: Dictionary = {}
var _elapsed := 0.0
var _request_sequence := 0
var _deferred := false
var _preparing := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var path := OS.get_environment(SESSION_ENV)
	if OS.has_feature("windows") and path.is_absolute_path() and DirAccess.dir_exists_absolute(path):
		_session_dir = path
		_refresh_status()
	set_process(is_enabled())


func is_enabled() -> bool:
	return not _session_dir.is_empty()


func is_deferred() -> bool:
	return _deferred


func defer_for_session() -> void:
	_deferred = true


func get_status() -> Dictionary:
	return _status.duplicate()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= POLL_INTERVAL:
		_elapsed = 0.0
		_refresh_status()


func request_download() -> Error:
	var state := str(_status.get("state", ""))
	if state != "available" and not (state == "error" and _status.get("error_code") == "download_failed"):
		return ERR_UNAVAILABLE
	return _write_request("download", str(_status.get("target_version", "")))


func cancel_download() -> Error:
	if _status.get("state") not in ["available", "downloading", "ready", "error"]:
		return ERR_UNAVAILABLE
	return _write_request("cancel", str(_status.get("target_version", "")))


func prepare_and_apply() -> Error:
	if _preparing:
		return ERR_BUSY
	var target := str(_status.get("target_version", ""))
	if _status.get("state") != "ready" or target.is_empty():
		return ERR_UNAVAILABLE
	var save_error := AudioManager.flush_settings()
	if save_error != OK:
		return save_error
	_preparing = true
	var stop_error := await GestureInput.stop_managed_recognizer()
	if stop_error != OK:
		_preparing = false
		return stop_error
	_refresh_status()
	var error := ERR_UNAVAILABLE
	if _status.get("state") == "ready" and _status.get("target_version") == target:
		error = _write_request("apply", target)
	if error != OK:
		GestureInput.restart_managed_recognizer()
		_preparing = false
		return error
	get_tree().quit()
	return OK


func _refresh_status() -> void:
	var next := _read_status()
	if next != _status:
		_status = next
		state_changed.emit(get_status())


func _read_status() -> Dictionary:
	if not DirAccess.dir_exists_absolute(_session_dir):
		return {}
	var file := FileAccess.open(_session_dir.path_join("status.json"), FileAccess.READ)
	if file == null or file.get_length() > MAX_STATUS_BYTES:
		return _status
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		return _status
	var data: Dictionary = parser.data
	if data.get("schema") != 1 or data.get("state") not in STATES:
		return _status
	var progress: Variant = data.get("progress", 0)
	return {
		"schema": 1,
		"state": data["state"],
		"current_version": str(data.get("current_version", "")),
		"target_version": str(data.get("target_version", "")),
		"notes": str(data.get("notes", "")),
		"progress": clampf(float(progress), 0.0, 100.0) if progress is float or progress is int else 0.0,
		"error_code": str(data.get("error_code", "")),
	}


func _write_request(action: String, target: String) -> Error:
	if not is_enabled() or target.is_empty():
		return ERR_UNAVAILABLE
	_request_sequence += 1
	var path := _session_dir.path_join("request.json")
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({
		"schema": 1,
		"id": "%d-%d" % [OS.get_process_id(), _request_sequence],
		"action": action,
		"target_version": target,
	}))
	file.flush()
	var error := file.get_error()
	file.close()
	if error == OK:
		error = DirAccess.rename_absolute(temporary, path)
	if error != OK:
		DirAccess.remove_absolute(temporary)
	return error
