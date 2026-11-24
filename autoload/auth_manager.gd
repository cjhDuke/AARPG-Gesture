extends Node

signal session_changed()
signal request_finished(operation: String, ok: bool, message: String, data: Dictionary)
signal busy_changed(value: bool)

const DEFAULT_API := "https://game.dukechen.top/api/v1"
const SESSION_PATH := "user://account/session.dat"
const TUTORIAL_DIR := "user://account/tutorial"
const TUTORIAL_RETRY_MS := 30000
const UUID_PATTERN := "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
const REQUEST_TIMEOUT := 15.0
const RESPONSE_LIMIT := 65536
const REFRESH_SKEW_SECONDS := 30
const DPAPI_TIMEOUT_MS := 5000
const GENERIC_ERROR := "The request could not be completed. Please try again."
const NETWORK_ERROR := "Network connection failed. Please try again."
const INVALID_ERROR := "The response was invalid. Please try again."

var busy: bool = false
var email: String = ""
var username: String = ""
var user_id: String = ""
var authenticated: bool = false
var startup_check_complete: bool = false
var startup_prompt_handled: bool = false
var last_error: String = ""

var _access_token := ""
var _refresh_token := ""
var _access_expires_at := 0
var _refresh_expires_at := 0
var _remember := false
var _refresh_pending := false
var _refresh_retry_at := 0
var _api_base := DEFAULT_API
var _http: HTTPRequest
var _operation := ""
var _pending_operation := ""
var _pending_data: Dictionary = {}
var _pending_remember := false
var _after_refresh := ""
var _after_refresh_data: Dictionary = {}
var _storage_continuation_operation := ""
var _storage_continuation_data: Dictionary = {}
var _restore_started := false
var _storage_thread: Thread
var _storage_result: Dictionary = {}
var _storage_generation := 0
var _tutorial_state := ""
var _tutorial_pending: Dictionary = {}
var _tutorial_unwritten: Dictionary = {}
var _tutorial_write_retry_at := 0
var _tutorial_http: HTTPRequest
var _tutorial_retry_at := 0
var _tutorial_auth_retried := false
var _tutorial_refresh_needed := false

const SERVICE_PATHS := {
	"POST /ranked-runs": true,
	"PUT /ranked-runs/{id}/result": true,
	"GET /leaderboards": true,
	"GET /me/leaderboard": true,
	"GET /me/stats": true,
	"PUT /me/stats": true,
}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if LevelManager.practice_mode:
		startup_check_complete = true
		return
	_http = HTTPRequest.new()
	_http.process_mode = Node.PROCESS_MODE_ALWAYS
	_http.timeout = REQUEST_TIMEOUT
	_http.body_size_limit = RESPONSE_LIMIT
	_http.max_redirects = 0
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_select_api_base()
	if FileAccess.file_exists(SESSION_PATH):
		_restore_started = _start_storage("load", "")
		startup_check_complete = not _restore_started
	else:
		startup_check_complete = true


func _process(_delta: float) -> void:
	if _storage_thread != null and not _storage_thread.is_alive():
		_storage_result = _storage_thread.wait_to_finish()
		_storage_thread = null
		_on_storage_finished(_storage_result)
	if not busy:
		var now := int(Time.get_unix_time_from_system())
		if authenticated and _access_expires_at > 0 and now >= _access_expires_at - REFRESH_SKEW_SECONDS:
			_begin_refresh("", {}, _remember)
		elif _refresh_pending and now >= _refresh_retry_at:
			_begin_refresh("", {}, _remember)
	_process_tutorial_sync()


func should_start_tutorial() -> bool:
	return authenticated and _tutorial_state == "pending" and _pending_tutorial_state(user_id).is_empty()


func finish_tutorial(user_id: String, state: String) -> void:
	var owner := user_id.to_lower()
	if LevelManager.practice_mode or state not in ["completed", "skipped"] or RegEx.create_from_string(UUID_PATTERN).search(owner) == null:
		return
	# The caller passes the UUID captured at tutorial entry, even after sign-out.
	if not _pending_tutorial_state(owner).is_empty():
		return
	if authenticated and self.user_id == owner and _is_confirmed_tutorial_state(_tutorial_state):
		return
	_tutorial_pending[owner] = state
	if not _write_tutorial_state(owner, state):
		_tutorial_unwritten[owner] = state
		_tutorial_write_retry_at = Time.get_ticks_msec() + TUTORIAL_RETRY_MS
		push_warning("Could not save the pending tutorial result. It will be retried.")


func _pending_tutorial_state(owner: String) -> String:
	if not _tutorial_pending.has(owner):
		var file := FileAccess.open(TUTORIAL_DIR.path_join(owner + ".state"), FileAccess.READ)
		var state := file.get_as_text() if file != null and file.get_length() <= 16 else ""
		_tutorial_pending[owner] = state if state in ["completed", "skipped"] else ""
	return _tutorial_pending[owner]


func _write_tutorial_state(owner: String, state: String) -> bool:
	if DirAccess.make_dir_recursive_absolute(TUTORIAL_DIR) != OK:
		return false
	var path := TUTORIAL_DIR.path_join(owner + ".state")
	var temporary := "%s.%d.tmp" % [path, OS.get_process_id()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(state)
	file.flush()
	var error := file.get_error()
	file.close()
	if error == OK and DirAccess.rename_absolute(temporary, path) == OK:
		return true
	DirAccess.remove_absolute(temporary)
	return false


func _process_tutorial_sync() -> void:
	var now := Time.get_ticks_msec()
	if not _tutorial_unwritten.is_empty() and now >= _tutorial_write_retry_at:
		_tutorial_write_retry_at = now + TUTORIAL_RETRY_MS
		for owner: String in _tutorial_unwritten.keys():
			if _write_tutorial_state(owner, _tutorial_unwritten[owner]):
				_tutorial_unwritten.erase(owner)
	if not authenticated or busy or _storage_thread != null or _tutorial_http != null or now < _tutorial_retry_at:
		return
	var state := _pending_tutorial_state(user_id)
	if state.is_empty():
		return
	if _tutorial_refresh_needed:
		_tutorial_refresh_needed = false
		if refresh_service_session(user_id) != OK:
			_delay_tutorial_sync()
		return
	var token := cloud_access_token()
	if token.is_empty():
		return
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT
	http.body_size_limit = RESPONSE_LIMIT
	http.max_redirects = 0
	add_child(http)
	_tutorial_http = http
	http.request_completed.connect(_on_tutorial_completed.bind(http, user_id, token))
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json", "Authorization: Bearer " + token])
	if http.request(_api_base + "/me/tutorial", headers, HTTPClient.METHOD_POST, JSON.stringify({"state": state})) != OK:
		_cancel_tutorial_request()
		_delay_tutorial_sync()


func _on_tutorial_completed(result: int, status: int, headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest, owner: String, token: String) -> void:
	if _tutorial_http != http:
		return
	_tutorial_http = null
	http.queue_free()
	if not authenticated or user_id != owner:
		return
	if result == HTTPRequest.RESULT_SUCCESS and status in [401, 403] and not _tutorial_auth_retried:
		_tutorial_auth_retried = true
		_tutorial_refresh_needed = token == cloud_access_token()
		return
	if result == HTTPRequest.RESULT_SUCCESS and status >= 200 and status < 300:
		var parser := JSON.new()
		if parser.parse(body.get_string_from_utf8()) == OK and parser.data is Dictionary and _is_confirmed_tutorial_state(parser.data.get("tutorial_state")):
			_tutorial_state = parser.data["tutorial_state"]
			_tutorial_pending[owner] = ""
			_tutorial_unwritten.erase(owner)
			DirAccess.remove_absolute(TUTORIAL_DIR.path_join(owner + ".state"))
			_tutorial_auth_retried = false
			return
	_delay_tutorial_sync(headers)


func _delay_tutorial_sync(headers: PackedStringArray = PackedStringArray()) -> void:
	var retry_ms := TUTORIAL_RETRY_MS
	for header in headers:
		if header.to_lower().begins_with("retry-after:"):
			var value := header.get_slice(":", 1).strip_edges()
			if value.is_valid_int():
				retry_ms = clampi(int(value), 1, 86400) * 1000
	_tutorial_retry_at = Time.get_ticks_msec() + retry_ms
	_tutorial_auth_retried = false


func _cancel_tutorial_request() -> void:
	if _tutorial_http != null:
		var http := _tutorial_http
		_tutorial_http = null
		http.cancel_request()
		http.queue_free()


func _reset_tutorial_session() -> void:
	_cancel_tutorial_request()
	_tutorial_state = ""
	_tutorial_retry_at = 0
	_tutorial_auth_retried = false
	_tutorial_refresh_needed = false


func _is_confirmed_tutorial_state(state: Variant) -> bool:
	return state is String and state in ["exempt", "completed", "skipped"]


func _read_tutorial_state(user: Dictionary) -> void:
	# A profile response started before a successful POST can still carry pending.
	if _is_confirmed_tutorial_state(_tutorial_state):
		return
	var state: Variant = user.get("tutorial_state")
	_tutorial_state = state if (state is String and state == "pending") or _is_confirmed_tutorial_state(state) else ""


func send_code(target_email: String, purpose: String) -> void:
	if purpose != "register" and purpose != "reset":
		_finish_immediate("email_codes", false, "Invalid request.")
		return
	_start_request("email_codes", "/auth/email-codes", {"email": target_email.strip_edges(), "purpose": purpose}, false)


func register_account(target_email: String, password: String, challenge_id: String, code: String, remember: bool, display_username: String = "") -> void:
	var payload := {"email": target_email.strip_edges(), "password": password, "challenge_id": challenge_id, "code": code}
	if not display_username.is_empty():
		payload["username"] = display_username
	_start_request("register", "/auth/register", payload, remember)


func update_username(value: String) -> void:
	if not authenticated:
		_finish_immediate("update_profile", false, "Please sign in again.")
		return
	_start_request("update_profile", "/me", {"username": value}, _remember, true)


func display_name() -> String:
	return username if not username.is_empty() else mask_email()


func cloud_access_token() -> String:
	return _access_token if authenticated and Time.get_unix_time_from_system() < _access_expires_at else ""


func cloud_api_base() -> String:
	return _api_base


func refresh_for_cloud() -> bool:
	if busy or _refresh_token.is_empty():
		return false
	_begin_refresh("", {}, _remember)
	return true


func get_api_base() -> String:
	return _api_base


func send_service_request(http: HTTPRequest, path: String, method: int, payload: Dictionary, owner_id: String = "", authorized: bool = true) -> int:
	if LevelManager.practice_mode:
		return ERR_UNAVAILABLE
	if http == null or not _is_service_route(path, method, authorized):
		return ERR_INVALID_PARAMETER
	if authorized:
		if not authenticated or owner_id.is_empty() or user_id.to_lower() != owner_id.to_lower():
			return ERR_UNAUTHORIZED
		if busy or _storage_thread != null:
			return ERR_BUSY
		if _access_expires_at <= int(Time.get_unix_time_from_system()) + REFRESH_SKEW_SECONDS:
			if not busy:
				_begin_refresh("", {}, _remember)
			return ERR_BUSY
	if http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return ERR_BUSY
	http.max_redirects = 0
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	if authorized:
		headers.append("Authorization: Bearer " + _access_token)
	var body := "" if method == HTTPClient.METHOD_GET else JSON.stringify(payload)
	return http.request(_api_base + path, headers, method, body)


func refresh_service_session(owner_id: String) -> int:
	if LevelManager.practice_mode:
		return ERR_UNAVAILABLE
	if busy or _storage_thread != null:
		return ERR_BUSY
	if not authenticated or user_id.to_lower() != owner_id.to_lower() or _refresh_token.is_empty():
		return ERR_UNAUTHORIZED
	_begin_refresh("", {}, _remember)
	return OK


func _is_service_route(path: String, method: int, authorized: bool) -> bool:
	var verb: String = "GET" if method == HTTPClient.METHOD_GET else ""
	if method == HTTPClient.METHOD_POST:
		verb = "POST"
	elif method == HTTPClient.METHOD_PUT:
		verb = "PUT"
	if not authorized and (method != HTTPClient.METHOD_GET or not path.begins_with("/leaderboards")):
		return false
	var route := path.split("?", true, 1)[0]
	if path.contains("?"):
		if route == "/leaderboards":
			if not RegEx.create_from_string("^/leaderboards\\?(ruleset_id=[A-Za-z0-9_]+(&cursor=[A-Za-z0-9_.~-]+)?|cursor=[A-Za-z0-9_.~-]+(&ruleset_id=[A-Za-z0-9_]+)?)$").search(path):
				return false
		elif route == "/me/leaderboard" and authorized and path in ["/me/leaderboard?ruleset_id=survival_v1", "/me/leaderboard?ruleset_id=survival_v2"]:
			pass
		else:
			return false
	if route.begins_with("/ranked-runs/") and route.ends_with("/result") and method == HTTPClient.METHOD_PUT:
		var run_id := route.trim_prefix("/ranked-runs/").trim_suffix("/result")
		return RegEx.create_from_string("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$").search(run_id) != null
	if route == "/leaderboards":
		return method == HTTPClient.METHOD_GET
	return SERVICE_PATHS.has(verb + " " + route)


func login(target_email: String, password: String, remember: bool) -> void:
	_start_request("login", "/auth/login", {"email": target_email.strip_edges(), "password": password}, remember)


func reset_password(target_email: String, password: String, challenge_id: String, code: String) -> void:
	_start_request("password_reset", "/auth/password-reset", {"email": target_email.strip_edges(), "password": password, "challenge_id": challenge_id, "code": code}, false)


func logout() -> void:
	if busy:
		return
	if not _explicit_auth_allowed():
		_finish_immediate("logout", false, "Account actions are available from the title screen.")
		return
	if _refresh_token.is_empty():
		_clear_session()
		_clear_local_storage()
		request_finished.emit("logout", true, "Signed out.", {})
		return
	_start_request("logout", "/auth/logout", {"refresh_token": _refresh_token}, false, not _access_token.is_empty())


func clear_local_credentials() -> void:
	if busy:
		return
	_storage_generation += 1
	_clear_local_storage()
	_remember = false


func mask_email() -> String:
	if email.is_empty():
		return ""
	var parts := email.split("@", false, 1)
	if parts.size() != 2:
		return ""
	var local := parts[0]
	if local.length() <= 2:
		return local.substr(0, 1) + "***@" + parts[1]
	return local.substr(0, 1) + "***" + local.substr(local.length() - 1, 1) + "@" + parts[1]


func _select_api_base() -> void:
	if not OS.is_debug_build():
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--auth-api="):
			var candidate := arg.trim_prefix("--auth-api=").trim_suffix("/")
			if candidate.begins_with("http://127.0.0.1:") or candidate.begins_with("http://localhost:") or candidate.begins_with("https://"):
				_api_base = candidate
			return


func _start_request(operation: String, path: String, payload: Dictionary, remember: bool, authorization: bool = false) -> void:
	if busy:
		return
	if operation in ["email_codes", "register", "login", "password_reset", "logout", "update_profile"] and not _explicit_auth_allowed():
		_finish_immediate(operation, false, "Account actions are available from the title screen.")
		return
	if operation in ["register", "login"] and remember and OS.get_name() != "Windows":
		_finish_immediate(operation, false, "Remember me is unavailable on this device.")
		return
	if authorization and _access_token.is_empty():
		_finish_immediate(operation, false, "Please sign in again.")
		return
	if authenticated and not authorization and operation in ["login", "register"]:
		_finish_immediate(operation, false, "Sign out before changing accounts.")
		return
	_pending_operation = operation
	_pending_data = {"path": path, "payload": payload, "authorization": authorization}
	_pending_remember = remember
	if _storage_thread != null:
		_set_busy(true)
		return
	if authenticated and operation not in ["email_codes", "password_reset", "logout"] and not _access_token.is_empty() and Time.get_unix_time_from_system() >= _access_expires_at - REFRESH_SKEW_SECONDS:
		_begin_refresh(operation, _pending_data, remember)
		return
	_send_http(operation, path, payload, authorization)


func _send_http(operation: String, path: String, payload: Dictionary, authorization: bool = false) -> void:
	_set_busy(true)
	_operation = operation
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	if authorization and not _access_token.is_empty():
		headers.append("Authorization: Bearer " + _access_token)
	var method := HTTPClient.METHOD_GET if path == "/me" else HTTPClient.METHOD_POST
	if operation == "update_profile":
		method = HTTPClient.METHOD_PATCH
	var body := "" if method == HTTPClient.METHOD_GET else JSON.stringify(payload)
	var err := _http.request(_api_base + path, headers, method, body)
	if err != OK:
		_complete(operation, false, NETWORK_ERROR, {})


func _begin_refresh(resume_operation: String, resume_data: Dictionary, remember_after: bool) -> void:
	if busy:
		return
	if _refresh_token.is_empty():
		if not resume_operation.is_empty():
			_complete(resume_operation, false, "Please sign in again.", {})
		return
	_after_refresh = resume_operation
	_after_refresh_data = resume_data
	_pending_remember = remember_after if not resume_operation.is_empty() else _remember
	_send_http("restore", "/auth/refresh", {"refresh_token": _refresh_token})


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var operation := _operation
	_operation = ""
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8()) if result == HTTPRequest.RESULT_SUCCESS and body.size() <= RESPONSE_LIMIT else null
	var data: Dictionary = parsed if parsed is Dictionary else {}
	var ok := result == HTTPRequest.RESULT_SUCCESS and response_code >= 200 and response_code < 300
	if not ok:
		var message := NETWORK_ERROR if result != HTTPRequest.RESULT_SUCCESS else _safe_error(operation, data)
		if operation == "restore":
			if result == HTTPRequest.RESULT_SUCCESS and response_code in [401, 403]:
				_clear_session()
				_clear_local_storage()
			else:
				_access_token = ""
				_access_expires_at = 0
				authenticated = false
				_cancel_tutorial_request()
				_refresh_pending = not _refresh_token.is_empty()
				_refresh_retry_at = int(Time.get_unix_time_from_system()) + 30
				session_changed.emit()
			var resume_operation := _after_refresh
			_after_refresh = ""
			_after_refresh_data = {}
			if resume_operation.is_empty():
				_complete("restore", false, "Saved sign-in could not be verified. You can play as a guest.", {})
			else:
				_complete(resume_operation, false, "Account service is unavailable. Please try again.", {})
			return
		if operation == "logout" and response_code in [401, 403]:
			_clear_session()
			_clear_local_storage()
			_complete("logout", true, "Signed out.", {})
			return
		var failure_data: Dictionary = {}
		var error_info: Variant = data.get("error", {})
		if error_info is Dictionary:
			var safe_code := str(error_info.get("code", ""))
			if safe_code in ["invalid_password_length", "invalid_email", "invalid_code_input", "invalid_username", "invalid_code", "invalid_login", "invalid_input", "rate_limited"]:
				failure_data["error"] = {"code": safe_code}
		if response_code == 429:
			var error_value: Variant = data.get("error", {})
			if error_value is Dictionary:
				var retry_value: Variant = error_value.get("retry_after", null)
				if retry_value is int or retry_value is float:
					failure_data["retry_after"] = clampi(int(retry_value), 0, 86400)
		_complete(operation, false, message, failure_data)
		return
	if result != HTTPRequest.RESULT_SUCCESS or parsed == null:
		if operation == "restore":
			_refresh_pending = not _refresh_token.is_empty()
			_refresh_retry_at = int(Time.get_unix_time_from_system()) + 30
		_complete(operation, false, INVALID_ERROR, {})
		return
	if operation == "email_codes":
		var challenge_id: Variant = data.get("challenge_id", "")
		var retry_value: Variant = data.get("retry_after", null)
		if not (challenge_id is String) or str(challenge_id).is_empty() or not (retry_value is int or retry_value is float):
			_complete(operation, false, INVALID_ERROR, {})
		else:
			_complete(operation, true, "If eligible, a code will arrive shortly. Check your email.", {"challenge_id": challenge_id, "retry_after": clampi(int(retry_value), 0, 86400)})
	elif operation in ["register", "login", "restore"]:
		if not _accept_session(data):
			if operation == "restore":
				_refresh_pending = not _refresh_token.is_empty()
				_refresh_retry_at = int(Time.get_unix_time_from_system()) + 30
			_complete(operation, false, INVALID_ERROR, {})
			return
		if operation == "restore":
			var resume := _after_refresh
			var resume_data := _after_refresh_data
			_after_refresh = ""
			_after_refresh_data = {}
			if _remember and _start_storage("protect", _refresh_token):
				_storage_continuation_operation = "restore" if resume.is_empty() else resume
				_storage_continuation_data = resume_data
				return
			if _remember:
				_clear_local_storage()
			if not resume.is_empty():
				_send_http(resume, str(resume_data.get("path", "")), resume_data.get("payload", {}), bool(resume_data.get("authorization", false)))
				return
			_complete("restore", true, "Session restored.", {"email": email, "user_id": user_id})
		else:
			_remember = _pending_remember
			if _remember:
				if not _start_storage("protect", _refresh_token):
					_clear_session()
					_complete(operation, false, "Remember me is unavailable on this device.", {})
					return
				return
			else:
				_clear_local_storage()
			_complete(operation, true, "Signed in.", {"email": email, "user_id": user_id})
	elif operation == "password_reset":
		_clear_session()
		_clear_local_storage()
		_complete(operation, true, "Password reset. Please sign in again.", {})
	elif operation == "logout":
		_clear_session()
		_clear_local_storage()
		_complete(operation, true, "Signed out.", {})
	elif operation == "update_profile":
		var updated_name: Variant = data.get("username")
		if data.get("id") != user_id or data.get("email") != email or not (updated_name is String) or str(updated_name).length() < 2 or str(updated_name).length() > 24:
			_complete(operation, false, INVALID_ERROR, {})
			return
		username = updated_name
		_read_tutorial_state(data)
		session_changed.emit()
		_complete(operation, true, "Display name saved.", {"username": username})
	elif operation == "me":
		var profile: Variant = data.get("user", data)
		if not authenticated or not (profile is Dictionary) or profile.get("id") != user_id:
			_complete(operation, false, INVALID_ERROR, {})
			return
		_read_tutorial_state(profile)
		_complete(operation, true, "Account loaded.", profile)
	else:
		_complete(operation, true, "Request completed.", data)


func _accept_session(data: Dictionary) -> bool:
	var user: Variant = data.get("user", {})
	var access: Variant = data.get("access_token")
	var refresh: Variant = data.get("refresh_token")
	var expires: Variant = data.get("expires_in")
	var refresh_expires: Variant = data.get("refresh_expires_at")
	if not (access is String) or not (refresh is String) or not (user is Dictionary):
		return false
	var token_pattern := RegEx.create_from_string("^[A-Za-z0-9_-]{40,128}$")
	if token_pattern.search(access) == null or token_pattern.search(refresh) == null:
		return false
	var identity: Variant = user.get("id")
	var address: Variant = user.get("email")
	var display_username: Variant = user.get("username", "")
	if not (display_username is String) or str(display_username).length() > 24:
		return false
	if not (identity is String) or not (address is String) or not str(address).contains("@") or str(address).length() > 254:
		return false
	if RegEx.create_from_string(UUID_PATTERN).search(identity) == null:
		return false
	if not (expires is int or expires is float) or not is_finite(float(expires)) or float(expires) < 1 or float(expires) > 86400:
		return false
	if not (refresh_expires is int or refresh_expires is float) or not is_finite(float(refresh_expires)) or float(refresh_expires) <= 0:
		return false
	_access_token = access
	_refresh_token = refresh
	_access_expires_at = int(Time.get_unix_time_from_system()) + int(expires)
	_refresh_expires_at = int(refresh_expires)
	if user_id != identity:
		_reset_tutorial_session()
	user_id = identity
	_read_tutorial_state(user)
	email = str(user.get("email", ""))
	username = display_username
	authenticated = true
	_refresh_pending = false
	_refresh_retry_at = 0
	last_error = ""
	session_changed.emit()
	return true


func _safe_error(operation: String, data: Dictionary) -> String:
	# Deliberately do not display server-provided text or echo submitted credentials.
	var error_data: Variant = data.get("error", {})
	var code := str(error_data.get("code", "")) if error_data is Dictionary else ""
	if code == "rate_limited":
		return "Too many attempts. Please wait and try again."
	if code == "invalid_username":
		return "Use 2-24 letters, numbers, spaces, underscores or hyphens for your display name."
	if code == "invalid_password_length":
		return "Use 8-128 characters for your password. Uppercase, lowercase and numbers are allowed."
	if code == "invalid_email":
		return "Enter a valid email address."
	if code == "invalid_code_input":
		return "Request a new verification code for this email and enter all 6 digits."
	if code == "invalid_input":
		return "Check your email and code. Passwords: 8-128 characters; A-Z, a-z and 0-9 are supported."
	if code == "invalid_code":
		return "The code is incorrect or expired. Request a new one."
	if code == "invalid_login":
		return "Email or password is incorrect. Passwords are case-sensitive."
	if operation == "update_profile":
		return "Could not save your display name. Please try again."
	if operation in ["login", "register"]:
		return "Sign in failed. Check your details and try again."
	if operation == "email_codes":
		return "Could not send the verification code. Please try again."
	if operation == "password_reset":
		return "Password reset failed. Check the code and try again."
	if operation == "logout":
		return "Sign out failed. Please try again."
	return GENERIC_ERROR


func _complete(operation: String, ok: bool, message: String, data: Dictionary) -> void:
	if operation == "restore":
		startup_check_complete = true
	if not ok:
		last_error = message
	else:
		last_error = ""
	_pending_operation = ""
	_pending_data = {}
	if operation == "restore":
		_after_refresh = ""
		_after_refresh_data = {}
	_set_busy(false)
	request_finished.emit(operation, ok, message, data)


func _finish_immediate(operation: String, ok: bool, message: String) -> void:
	last_error = "" if ok else message
	request_finished.emit(operation, ok, message, {})


func _set_busy(value: bool) -> void:
	if busy == value:
		return
	busy = value
	busy_changed.emit(value)


func _explicit_auth_allowed() -> bool:
	var scene := get_tree().current_scene
	return not LevelManager.practice_mode and scene != null and scene.scene_file_path == "res://ui/title/title_scene.tscn"


func _clear_session() -> void:
	_reset_tutorial_session()
	_access_token = ""
	_refresh_token = ""
	_access_expires_at = 0
	_refresh_expires_at = 0
	_refresh_pending = false
	_refresh_retry_at = 0
	email = ""
	username = ""
	user_id = ""
	authenticated = false
	_remember = false
	session_changed.emit()


func _clear_local_storage() -> void:
	var path := ProjectSettings.globalize_path(SESSION_PATH)
	if FileAccess.file_exists(SESSION_PATH):
		DirAccess.remove_absolute(path)


func _start_storage(action: String, value: String) -> bool:
	if OS.get_name() != "Windows":
		return false
	if _storage_thread != null:
		return false
	_storage_generation += 1
	var generation := _storage_generation
	var script_path := _credentials_script_path()
	if script_path.is_empty():
		return false
	_storage_thread = Thread.new()
	var session_path := ProjectSettings.globalize_path(SESSION_PATH)
	var err := _storage_thread.start(_run_storage.bind(action, value, script_path, session_path, generation))
	if err != OK:
		_storage_thread = null
		return false
	_set_busy(true)
	return true


func _credentials_script_path() -> String:
	var candidates := PackedStringArray()
	if OS.is_debug_build():
		candidates.append(ProjectSettings.globalize_path("res://platform/windows/account_credentials.ps1"))
	var executable_dir := OS.get_executable_path().get_base_dir()
	candidates.append(executable_dir.path_join("platform/windows/account_credentials.ps1"))
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			return candidate
	return ""


func _run_storage(action: String, value: String, script_path: String, session_path: String, generation: int) -> Dictionary:
	var input_payload := Marshalls.raw_to_base64(value.to_utf8_buffer()) if not value.is_empty() else ""
	var args := PackedStringArray(["-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", script_path, "-Action", action, "-SessionPath", session_path])
	var powershell := OS.get_environment("SystemRoot").path_join("System32/WindowsPowerShell/v1.0/powershell.exe")
	var process := OS.execute_with_pipe(powershell, args, false)
	if process.is_empty():
		return {"ok": false, "code": "DPAPI_START", "generation": generation}
	var pipe: FileAccess = process.get("stdio")
	pipe.store_line(input_payload)
	pipe.flush()
	var pid := int(process.get("pid", -1))
	var started := Time.get_ticks_msec()
	var output := ""
	while Time.get_ticks_msec() - started < DPAPI_TIMEOUT_MS:
		var line := pipe.get_line()
		if not line.is_empty():
			output = line
			break
		if pid > 0 and not OS.is_process_running(pid):
			break
		OS.delay_msec(10)
	if output.is_empty() and pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
		return {"ok": false, "code": "DPAPI_TIMEOUT", "generation": generation}
	while pid > 0 and OS.is_process_running(pid) and Time.get_ticks_msec() - started < DPAPI_TIMEOUT_MS:
		OS.delay_msec(10)
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)
		return {"ok": false, "code": "DPAPI_TIMEOUT", "generation": generation}
	if pid > 0 and OS.get_process_exit_code(pid) != 0:
		return {"ok": false, "code": "DPAPI_FAILED", "generation": generation}
	if action == "protect":
		if Marshalls.base64_to_raw(output.strip_edges()).get_string_from_utf8() != "OK":
			return {"ok": false, "code": "DPAPI_FAILED", "generation": generation}
		return {"ok": true, "value": "stored", "generation": generation}
	var value_out := Marshalls.base64_to_raw(output.strip_edges()).get_string_from_utf8()
	if action == "load" and value_out == "NONE":
		value_out = ""
	return {"ok": true, "value": value_out, "generation": generation}


func _on_storage_finished(result: Dictionary) -> void:
	if int(result.get("generation", -1)) != _storage_generation:
		return
	var ok := bool(result.get("ok", false))
	if not ok:
		if _restore_started:
			_restore_started = false
			startup_check_complete = true
			_clear_local_storage()
			_set_busy(false)
			if not _pending_operation.is_empty():
				var pending := _pending_operation
				var pending_data := _pending_data
				_send_http(pending, str(pending_data.get("path", "")), pending_data.get("payload", {}), bool(pending_data.get("authorization", false)))
			return
		if not _storage_continuation_operation.is_empty():
			_clear_local_storage()
			_continue_after_storage()
			return
		if _pending_operation in ["login", "register"] and authenticated:
			_clear_session()
			_complete(_pending_operation, false, "Remember me is unavailable on this device.", {})
			return
		return
	if _restore_started and not authenticated and result.has("value"):
		_restore_started = false
		_set_busy(false)
		_refresh_token = str(result.get("value", ""))
		if not _refresh_token.is_empty():
			_remember = true
			_begin_refresh(_pending_operation, _pending_data, _pending_remember)
		elif not _pending_operation.is_empty():
			var pending := _pending_operation
			var pending_data := _pending_data
			_send_http(pending, str(pending_data.get("path", "")), pending_data.get("payload", {}), bool(pending_data.get("authorization", false)))
		else:
			startup_check_complete = true
		return
	if not _storage_continuation_operation.is_empty():
		_continue_after_storage()
		return
	if _pending_operation in ["login", "register"] and authenticated:
		var op := _pending_operation
		if result.has("value"):
			_complete(op, true, "Signed in.", {"email": email, "user_id": user_id})
		else:
			_complete(op, false, "Remember me is unavailable on this device.", {})
		return


func _continue_after_storage() -> void:
	var continuation := _storage_continuation_operation
	var continuation_data := _storage_continuation_data
	_storage_continuation_operation = ""
	_storage_continuation_data = {}
	if continuation == "restore":
		_complete("restore", true, "Session restored.", {"email": email, "user_id": user_id})
	else:
		_send_http(continuation, str(continuation_data.get("path", "")), continuation_data.get("payload", {}), bool(continuation_data.get("authorization", false)))


func _exit_tree() -> void:
	if _storage_thread != null:
		_storage_thread.wait_to_finish()
		_storage_thread = null
