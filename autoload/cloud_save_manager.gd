extends Node

signal changed()

const TITLE := "res://ui/title/title_scene.tscn"
const STATE_VERSION := 1
var owner_id: String = ""
var _state: Dictionary = {}
var _device_id := ""
var _last_owner := ""
var _epoch := 0
var _http: HTTPRequest
var _current: Dictionary = {}
var _catalog: Dictionary = {}
var _cursor := ""
var _want_catalog := true
var _catalog_active := false
var _persist_ok := true
var _offline := false
var _auth_blocked := false
var _refresh_attempted := false
var _error := ""
var _next_request := 0
var _next_poll := 0
var _next_scan := 0
var _retry_seconds := 2
var _tick := 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if LevelManager.practice_mode:
		return
	_load_device()
	AuthManager.session_changed.connect(_on_session)
	AuthManager.request_finished.connect(_on_auth_finished)
	SaveManager.save_changed.connect(_on_save_changed)
	_on_session.call_deferred()

func _process(delta: float) -> void:
	if LevelManager.practice_mode:
		return
	_tick += delta
	if _tick < 0.25:
		return
	_tick = 0.0
	_on_session()
	if owner_id.is_empty():
		return
	if Time.get_ticks_msec() >= _next_scan:
		_scan_local()
		_next_scan = Time.get_ticks_msec() + 5000
	if not _current.is_empty() or Time.get_ticks_msec() < _next_request:
		return
	if not _persist_ok and not _save_state():
		return
	if not _error.is_empty():
		return
	if not AuthManager.authenticated or AuthManager.user_id != owner_id or AuthManager.busy or _auth_blocked:
		return
	if AuthManager.cloud_access_token().is_empty():
		AuthManager.refresh_for_cloud()
		return
	if not _catalog_active and Time.get_ticks_msec() >= _next_poll:
		_want_catalog = true
	if _want_catalog:
		_catalog = {}
		_cursor = ""
		_catalog_active = true
		_want_catalog = false
	if _catalog_active:
		_request("list", "/saves" + ("?after=" + _cursor if not _cursor.is_empty() else ""))
		return
	if _safe_to_apply():
		for id in _state.records:
			var entry: Dictionary = _state.records[id]
			if entry.get("choice", "") == "cloud" or entry.has("download"):
				var remote: Dictionary = entry.get("download", entry.get("conflict", {}))
				if remote.is_empty():
					continue
				if bool(remote.deleted):
					_apply_tombstone(id, remote)
				else:
					_request("get", "/saves/" + id, {}, {"id": id, "local_hash": str(entry.get("download_hash", "")), "expected_revision": int(remote.revision)})
				return
	for id in _state.records:
		var entry: Dictionary = _state.records[id]
		if entry.has("conflict") or not str(entry.get("error", "")).is_empty():
			continue
		var op: Dictionary = entry.get("op", {})
		if not op.is_empty():
			_request(str(op.kind), "/saves/" + id, op.body, {"id": id, "op": op.duplicate(true)})
			return

func is_account_context() -> bool:
	return not owner_id.is_empty()

func pending_count() -> int:
	var count := 0
	for entry in _state.get("records", {}).values():
		if not entry.get("op", {}).is_empty() or entry.has("conflict") or entry.has("download"):
			count += 1
	return count

func summary() -> String:
	if LevelManager.practice_mode:
		return "PRACTICE / LOCAL ONLY"
	if owner_id.is_empty():
		return "GUEST / SIGN IN FOR CLOUD SAVES"
	if not _error.is_empty():
		return _error
	if _auth_blocked:
		return "SIGN IN AGAIN / LOCAL SAVES ARE SAFE"
	if not AuthManager.authenticated or AuthManager.user_id != owner_id or _offline:
		return "OFFLINE / %d PENDING" % pending_count()
	if not _current.is_empty() or _catalog_active or _want_catalog:
		return "SYNCING / %d PENDING" % pending_count()
	if not conflicts().is_empty():
		return "%d CONFLICTS / RESOLVE" % conflicts().size()
	if pending_count() > 0:
		return "%d PENDING / SAVED ON THIS DEVICE" % pending_count()
	return "SYNCED / " + str(_state.get("last_sync", ""))

func save_status(id: String) -> String:
	if owner_id.is_empty():
		return "LOCAL"
	var entry: Dictionary = _state.get("records", {}).get(id, {})
	if entry.has("conflict"):
		return "CONFLICT"
	if not str(entry.get("error", "")).is_empty():
		return "ERROR"
	if _current.get("id", "") == id:
		return "SYNCING"
	if entry.has("download") or not entry.get("op", {}).is_empty():
		return "PENDING"
	if int(entry.get("revision", 0)) > 0 and str(entry.get("ack_hash", "")) == SaveManager.record_hash(id):
		return "SYNCED"
	return "PENDING"

func sync_now() -> void:
	if LevelManager.practice_mode or owner_id.is_empty():
		return
	_error = ""
	_offline = false
	_next_request = 0
	_next_poll = 0
	for entry in _state.records.values():
		entry.erase("error")
	_save_state()
	_emit_changed()

func conflicts() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for id in _state.get("records", {}):
		var entry: Dictionary = _state.records[id]
		if entry.has("conflict"):
			var record: Dictionary = SaveManager.read_record(id)
			var deleted: bool = record.has("error")
			if deleted:
				record = SaveManager.read_deleted_record(id)
			result.append({"id": id, "local": {} if record.has("error") else record, "local_deleted": deleted, "remote": entry.conflict})
	return result

func guest_saves() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record in SaveManager.guest_records():
		var checkpoint: Dictionary = record.checkpoint
		result.append({"id": record.id, "name": record.name, "time": record.saved_at, "valid": true,
			"progress": "STAGE %d / WAVE %d" % [int(checkpoint.stage) + 1, int(checkpoint.wave)]})
	return result

func import_guest_save(id: String) -> bool:
	if owner_id.is_empty() or LevelManager.practice_mode or not _safe_context():
		return false
	var source: Dictionary = {}
	for record in SaveManager.guest_records():
		if record.id == id:
			source = record
			break
	if source.is_empty():
		return false
	var key: String = id + ":" + _hash_record(source)
	var mapped: String = str(_state.imports.get(key, ""))
	if not mapped.is_empty() and not SaveManager.read_record(mapped).has("error"):
		return true
	if mapped.is_empty() or SaveManager.deleted_ids().has(mapped) or bool(_state.records.get(mapped, {}).get("deleted", false)):
		mapped = Crypto.new().generate_random_bytes(16).hex_encode()
		_state.imports[key] = mapped
		if not _save_state():
			return false
	var ok: bool = SaveManager.copy_guest_record(id, mapped)
	if not ok:
		_error = SaveManager.last_error
	_emit_changed()
	return ok

func resolve_conflict(id: String, choice: String) -> void:
	if not _safe_context() or not _state.get("records", {}).has(id) or choice not in ["local", "cloud", "both"]:
		return
	var entry: Dictionary = _state.records[id]
	if not entry.has("conflict"):
		return
	var remote: Dictionary = entry.conflict
	var record: Dictionary = SaveManager.read_record(id)
	if choice == "both" or (choice == "local" and bool(remote.deleted)):
		var copy_id: String = str(entry.get("preserved_id", ""))
		if copy_id.is_empty():
			copy_id = Crypto.new().generate_random_bytes(16).hex_encode()
			entry["preserved_id"] = copy_id
			if not _save_state():
				return
		if SaveManager.read_record(copy_id).has("error") and not SaveManager.copy_record(id, copy_id):
			_error = SaveManager.last_error
			_emit_changed()
			return
		choice = "cloud"
	if choice == "cloud":
		entry["choice"] = "cloud"
		entry["download_hash"] = SaveManager.record_hash(id)
		entry.erase("op")
	else:
		entry["revision"] = int(remote.revision)
		entry.erase("conflict")
		entry.erase("choice")
		entry.erase("error")
		entry.erase("op")
		_make_op(id, "delete" if record.has("error") else "put")
	_save_state()
	_next_request = 0
	_emit_changed()

func _on_session() -> void:
	if LevelManager.practice_mode:
		return
	var desired: String = AuthManager.user_id
	if desired.is_empty() and not AuthManager.startup_check_complete and FileAccess.file_exists(AuthManager.SESSION_PATH):
		desired = _last_owner
	if desired.is_empty() and FileAccess.file_exists(AuthManager.SESSION_PATH) and not AuthManager.last_error.is_empty():
		desired = _last_owner
	if desired == owner_id:
		return
	var scene := get_tree().current_scene
	if scene != null and scene.scene_file_path != TITLE:
		return
	if not owner_id.is_empty():
		_save_state()
	_epoch += 1
	if is_instance_valid(_http):
		_http.cancel_request()
		_http.queue_free()
	_current = {}
	if not SaveManager.set_profile(desired):
		return
	owner_id = desired
	_state = {"version": STATE_VERSION, "records": {}, "imports": {}, "last_sync": ""}
	_error = ""
	_auth_blocked = false
	_refresh_attempted = false
	_persist_ok = true
	if not owner_id.is_empty():
		_last_owner = owner_id
		_save_device()
		var path := _state_path()
		if FileAccess.file_exists(path):
			var file := FileAccess.open(path, FileAccess.READ)
			if file != null and file.get_length() <= 4 * 1024 * 1024:
				var parsed: Variant = JSON.parse_string(file.get_as_text())
				if parsed is Dictionary and parsed.get("version") == STATE_VERSION and parsed.get("records") is Dictionary and parsed.get("imports") is Dictionary:
					if _valid_state(parsed):
						_state = parsed
					else:
						_error = "SYNC METADATA DAMAGED / REVIEW CLOUD CONFLICTS"
				else:
					_error = "SYNC METADATA DAMAGED / REVIEW CLOUD CONFLICTS"
		_catalog_active = false
	_want_catalog = true
	_next_request = 0
	_next_poll = 0
	_scan_local()
	_emit_changed()

func _on_auth_finished(operation: String, ok: bool, _message: String, _data: Dictionary) -> void:
	if operation in ["login", "register", "restore"] and ok:
		_auth_blocked = false
		_offline = false
		_next_request = 0
		_next_poll = 0
	_on_session()
	_emit_changed()

func _on_save_changed(id: String, operation: String) -> void:
	if owner_id.is_empty() or SaveManager.profile_id != owner_id or LevelManager.practice_mode:
		return
	_make_op(id, operation)
	_save_state()
	_next_request = mini(_next_request, Time.get_ticks_msec() + 400)
	_emit_changed()

func _scan_local() -> void:
	if owner_id.is_empty():
		return
	var touched := false
	for entry in SaveManager.list_saves():
		if not entry.get("valid", false):
			continue
		var id: String = entry.id
		var metadata: Dictionary = _state.records.get(id, {})
		if metadata.has("conflict") or metadata.has("download") or not metadata.get("op", {}).is_empty():
			continue
		if SaveManager.record_hash(id) != str(metadata.get("ack_hash", "")):
			_make_op(id, "put")
			touched = true
	for id in SaveManager.deleted_ids():
		var metadata: Dictionary = _state.records.get(id, {})
		if not metadata.has("conflict") and metadata.get("op", {}).is_empty() and not bool(metadata.get("deleted", false)):
			_make_op(id, "delete")
			touched = true
	if touched:
		_save_state()
		_emit_changed()

func _make_op(id: String, kind: String) -> void:
	var entry: Dictionary = _state.records.get(id, {"revision": 0, "ack_hash": ""})
	_state.records[id] = entry
	# Freeze an operation until acknowledged; later edits are detected by their hash.
	if not entry.get("op", {}).is_empty() or entry.has("conflict"):
		return
	if entry.has("download"):
		_set_conflict(id, entry.download)
		return
	var body := {"base_revision": int(entry.get("revision", 0)), "operation_id": _uuid(), "device_id": _device_id}
	var hash := ""
	if kind == "put":
		var record: Dictionary = SaveManager.read_record(id)
		if record.has("error"):
			entry["error"] = "Cannot read local save."
			return
		body["record"] = record
		hash = _hash_record(record)
	entry["op"] = {"kind": kind, "body": body, "local_hash": hash}
	entry.erase("error")

func _request(kind: String, path: String, body: Dictionary = {}, context: Dictionary = {}) -> void:
	if not _save_state():
		return
	_http = HTTPRequest.new()
	_http.process_mode = Node.PROCESS_MODE_ALWAYS
	_http.timeout = 15.0
	_http.body_size_limit = 131072
	_http.max_redirects = 0
	add_child(_http)
	_current = context.duplicate(true)
	_current.merge({"kind": kind, "owner": owner_id, "epoch": _epoch, "nonce": _uuid(), "node": _http})
	_http.request_completed.connect(_on_response.bind(_current.duplicate()))
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json", "Authorization: Bearer " + AuthManager.cloud_access_token()])
	var method := HTTPClient.METHOD_GET
	if kind == "put": method = HTTPClient.METHOD_PUT
	if kind == "delete": method = HTTPClient.METHOD_DELETE
	var wire: Dictionary = body.duplicate(true)
	if wire.has("base_revision"): wire["base_revision"] = int(wire.base_revision)
	var error: int = _http.request(AuthManager.cloud_api_base() + path, headers, method, "" if wire.is_empty() else JSON.stringify(wire, "", true, true))
	if error != OK:
		var failed := _current.duplicate()
		_on_response(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray(), failed)
	_emit_changed()

func _on_response(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray, context: Dictionary) -> void:
	if is_instance_valid(context.get("node")):
		context.node.queue_free()
	if context.get("epoch") != _epoch or context.get("owner") != owner_id or context.get("nonce") != _current.get("nonce"):
		return
	_current = {}
	_next_request = Time.get_ticks_msec() + 400
	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8()) if result == HTTPRequest.RESULT_SUCCESS else null
	var data: Dictionary = parsed if parsed is Dictionary else {}
	if code == 401:
		if not _refresh_attempted:
			_refresh_attempted = true
			if not AuthManager.refresh_for_cloud(): _auth_blocked = true
		else:
			_auth_blocked = true
		_emit_changed()
		return
	if result != HTTPRequest.RESULT_SUCCESS or code >= 500 or code == 429:
		_offline = true
		_next_request = Time.get_ticks_msec() + (60 if code == 429 else _retry_seconds) * 1000
		_retry_seconds = mini(_retry_seconds * 2, 60)
		if context.kind == "list": _catalog_active = false; _want_catalog = true
		_emit_changed()
		return
	_offline = false
	_retry_seconds = 2
	if code >= 200 and code < 300:
		_refresh_attempted = false
		if context.kind == "list":
			if not data.get("saves") is Array or data.get("protocol_version") != 1:
				_protocol_error()
				return
			for item in data.saves:
				if not _valid_meta(item):
					_protocol_error()
					return
				_catalog[item.save_id] = item
			var next: Variant = data.get("next_cursor")
			if next is String and not str(next).is_empty():
				if str(next) <= _cursor: _protocol_error(); return
				_cursor = next
			else:
				_catalog_active = false
				_next_poll = Time.get_ticks_msec() + 30000
				_process_catalog()
		elif context.kind == "get":
			_accept_download(context, data)
		else:
			if not _valid_meta(data) or data.save_id != context.id:
				_protocol_error()
				return
			if int(data.revision) != int(context.op.body.base_revision) + 1 or bool(data.deleted) != (context.kind == "delete"):
				_protocol_error()
				return
			var entry: Dictionary = _state.records[context.id]
			entry["revision"] = int(data.revision)
			entry["remote_hash"] = data.content_hash
			entry["ack_hash"] = str(context.op.local_hash)
			entry["deleted"] = bool(data.deleted)
			entry.erase("op")
			entry.erase("error")
			if data.deleted: SaveManager.clear_deleted_marker(context.id)
			# Acknowledged uploads never discard edits made during the request.
			_scan_local()
			_next_poll = 0
	else:
		if context.kind == "list":
			_catalog_active = false
			_error = "CLOUD SERVICE UNAVAILABLE / LOCAL SAVES ARE SAFE"
			_next_poll = Time.get_ticks_msec() + 30000
		elif code == 409 and data.get("error") is Dictionary and data.error.get("current") is Dictionary and _valid_meta(data.error.current):
			_set_conflict(context.id, data.error.current)
		elif context.kind == "get" and code == 404:
			_next_poll = 0
		else:
			var id: String = context.get("id", "")
			if _state.records.has(id):
				var error_info: Variant = data.get("error", {})
				var error_code: String = str(error_info.get("code", "")) if error_info is Dictionary else ""
				_state.records[id]["error"] = "Cloud quota reached. Delete an unused save." if error_code == "save_quota" else "Sync failed. Check this save and retry."
	_save_state()
	if pending_count() == 0 and not _catalog_active:
		_state["last_sync"] = Time.get_datetime_string_from_system(false, true)
		_save_state()
	_emit_changed()

func _process_catalog() -> void:
	for id in _catalog:
		var remote: Dictionary = _catalog[id]
		var entry: Dictionary = _state.records.get(id, {"revision": 0, "ack_hash": ""})
		_state.records[id] = entry
		if not entry.get("op", {}).is_empty() or entry.has("conflict"):
			continue
		var hash: String = SaveManager.record_hash(id)
		var local_dirty: bool = not hash.is_empty() and hash != str(entry.get("ack_hash", ""))
		if SaveManager.deleted_ids().has(id):
			if remote.deleted:
				_accept_deleted(id, remote)
			elif int(remote.revision) != int(entry.get("revision", 0)):
				_set_conflict(id, remote)
			continue
		if int(remote.revision) == int(entry.get("revision", 0)) and not hash.is_empty():
			continue
		if local_dirty:
			_set_conflict(id, remote)
		elif remote.deleted and hash.is_empty():
			_accept_deleted(id, remote)
		else:
			entry["download"] = remote
			entry["download_hash"] = hash

func _accept_download(context: Dictionary, data: Dictionary) -> void:
	if not _valid_meta(data) or data.save_id != context.id:
		_protocol_error()
		return
	if int(data.revision) != int(context.expected_revision):
		_set_conflict(context.id, data)
		return
	if bool(data.deleted):
		_state.records[context.id]["download"] = data
		return
	var raw: Variant = data.get("record_json")
	if not raw is String or str(raw).to_utf8_buffer().size() > 65536 or str(raw).sha256_text() != data.content_hash:
		_protocol_error()
		return
	if not _safe_to_apply():
		_state.records[context.id]["download"] = data
		_state.records[context.id]["download_hash"] = context.local_hash
		return
	if not SaveManager.apply_cloud_record(context.id, raw, context.local_hash):
		_set_conflict(context.id, data)
		return
	_state.records[context.id] = {"revision": int(data.revision), "remote_hash": data.content_hash, "ack_hash": SaveManager.record_hash(context.id), "deleted": false}

func _apply_tombstone(id: String, remote: Dictionary) -> void:
	var expected: String = str(_state.records[id].get("download_hash", ""))
	if SaveManager.record_hash(id) != expected:
		_set_conflict(id, remote)
		_save_state()
		return
	if not expected.is_empty() and not SaveManager.remove_cloud_record(id, expected):
		_set_conflict(id, remote)
		return
	_accept_deleted(id, remote)
	_save_state()
	_emit_changed()

func _accept_deleted(id: String, remote: Dictionary) -> void:
	_state.records[id] = {"revision": int(remote.revision), "ack_hash": "", "remote_hash": null, "deleted": true}
	SaveManager.clear_deleted_marker(id)

func _set_conflict(id: String, remote: Dictionary) -> void:
	var entry: Dictionary = _state.records.get(id, {})
	entry["conflict"] = remote
	entry.erase("choice")
	entry.erase("download")
	entry.erase("op")
	entry.erase("error")
	entry.erase("preserved_id")
	_state.records[id] = entry

func _valid_meta(value: Variant) -> bool:
	if not value is Dictionary or not value.get("save_id") is String or RegEx.create_from_string("^[0-9a-f]{32}$").search(str(value.save_id)) == null:
		return false
	if not value.get("deleted") is bool or not value.get("summary") is Dictionary:
		return false
	var revision: Variant = value.get("revision")
	if not (revision is int or revision is float) or float(revision) != floorf(float(revision)) or float(revision) < 1 or float(revision) > 9007199254740991:
		return false
	return bool(value.deleted) or (value.get("content_hash") is String and RegEx.create_from_string("^[0-9a-f]{64}$").search(str(value.content_hash)) != null)

func _safe_to_apply() -> bool:
	if not _safe_context():
		return false
	var page := get_node_or_null("/root/SavedGames")
	if page != null and page.is_open and (page.modal.visible or page.conflict_modal.visible):
		return false
	return true

func _safe_context() -> bool:
	if LevelManager.is_loading_level:
		return false
	var scene := get_tree().current_scene
	return scene != null and (scene.scene_file_path == TITLE or (is_instance_valid(get_node_or_null("/root/SavedGames")) and get_node("/root/SavedGames").is_open))

func _protocol_error() -> void:
	_error = "INVALID CLOUD RESPONSE / LOCAL SAVES ARE SAFE"
	_catalog_active = false
	_next_poll = Time.get_ticks_msec() + 30000
	_emit_changed()

func _hash_record(record: Dictionary) -> String:
	return JSON.stringify(record, "\t", true, true).sha256_text()

func _state_path() -> String:
	return "user://profiles".path_join(owner_id).path_join("cloud.json")

func _valid_state(value: Dictionary) -> bool:
	for id in value.records:
		if not id is String or RegEx.create_from_string("^[0-9a-f]{32}$").search(id) == null:
			return false
		var entry: Variant = value.records[id]
		if not entry is Dictionary or not entry.get("op", {}) is Dictionary:
			return false
		var revision: Variant = entry.get("revision", 0)
		if not (revision is int or revision is float) or not is_finite(float(revision)) or float(revision) < 0:
			return false
		if entry.has("conflict") and not _valid_meta(entry.conflict): return false
		if entry.has("download") and not _valid_meta(entry.download): return false
		var op: Dictionary = entry.get("op", {})
		if not op.is_empty():
			if op.get("kind") not in ["put", "delete"] or not op.get("body") is Dictionary:
				return false
			for key in ["operation_id", "device_id"]:
				if not op.body.get(key) is String: return false
			if op.kind == "put" and not op.body.get("record") is Dictionary: return false
	return true

func _save_state() -> bool:
	if owner_id.is_empty():
		return true
	var path := _state_path()
	if DirAccess.make_dir_recursive_absolute(path.get_base_dir()) != OK:
		_persist_ok = false
		_error = "CANNOT SAVE SYNC QUEUE / LOCAL SAVES ARE SAFE"
		return false
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		_persist_ok = false
		_error = "CANNOT SAVE SYNC QUEUE / LOCAL SAVES ARE SAFE"
		return false
	file.store_string(JSON.stringify(_state, "", true, true))
	file.flush()
	var ok: bool = file.get_error() == OK
	file.close()
	_persist_ok = ok and DirAccess.rename_absolute(path + ".tmp", path) == OK
	if not _persist_ok: _error = "CANNOT SAVE SYNC QUEUE / LOCAL SAVES ARE SAFE"
	return _persist_ok

func _load_device() -> void:
	var config := ConfigFile.new()
	if config.load("user://profiles/device.cfg") == OK:
		_device_id = str(config.get_value("device", "id", ""))
		_last_owner = str(config.get_value("device", "last_owner", ""))
	if RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$").search(_device_id) == null:
		_device_id = _uuid()
	if RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$").search(_last_owner) == null:
		_last_owner = ""
	_save_device()

func _save_device() -> void:
	DirAccess.make_dir_recursive_absolute("user://profiles")
	var config := ConfigFile.new()
	config.set_value("device", "id", _device_id)
	config.set_value("device", "last_owner", _last_owner)
	config.save("user://profiles/device.cfg")

func _uuid() -> String:
	var text: String = Crypto.new().generate_random_bytes(16).hex_encode()
	return "%s-%s-%s-%s-%s" % [text.substr(0, 8), text.substr(8, 4), text.substr(12, 4), text.substr(16, 4), text.substr(20, 12)]

func _emit_changed() -> void:
	changed.emit()
