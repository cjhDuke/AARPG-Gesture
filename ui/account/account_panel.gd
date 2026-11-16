extends CanvasLayer

signal closed

var _font: SystemFont
var _root: Control
var _panel: Panel
var _content: VBoxContainer
var _status: Label
var _email: LineEdit
var _password: LineEdit
var _confirm: LineEdit
var _code: LineEdit
var _remember: CheckBox
var _mode_button: Button
var _reset_button: Button
var _submit: Button
var _send_code: Button
var _password_toggle: Button
var _mode := "LOGIN"
var _challenge_id := ""
var _challenge_email := ""
var _challenge_purpose := ""
var _countdown := 0
var _countdown_timer: Timer
var _sensitive_controls: Array[LineEdit] = []
var _pending_code_email := ""
var _pending_code_purpose := ""
var _username: LineEdit
var _profile_name: LineEdit
var _profile_email: Label
var _save_name: Button
var _form_rows: Array[Control] = []
var login_required: bool = false
var _close_button: Button

func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(["Arial", "sans-serif"])
	_build()
	visible = false
	AuthManager.request_finished.connect(_on_request_finished)
	AuthManager.busy_changed.connect(_on_busy_changed)
	AuthManager.session_changed.connect(_on_session_changed)
	_countdown_timer = Timer.new()
	_countdown_timer.wait_time = 1.0
	_countdown_timer.timeout.connect(_tick_countdown)
	add_child(_countdown_timer)

func open(login_required: bool = false) -> void:
	self.login_required = login_required
	if visible:
		_refresh()
		return
	visible = true
	_mode = "LOGIN"
	_clear_sensitive()
	if AuthManager.authenticated:
		_profile_name.text = AuthManager.username
	else:
		_status.text = AuthManager.last_error if login_required and not AuthManager.last_error.is_empty() else ("Sign in to continue." if login_required else "")
	_refresh()
	if AuthManager.authenticated:
		_profile_name.grab_focus()
	else:
		_email.grab_focus()

func close() -> void:
	if not visible:
		return
	if login_required and not AuthManager.authenticated:
		_status.text = "Sign in to continue."
		return
	_clear_sensitive()
	visible = false
	closed.emit()

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause"):
		if login_required and not AuthManager.authenticated:
			_status.text = "Sign in to continue."
		else:
			close()
		get_viewport().set_input_as_handled()

func _unhandled_input(_event: InputEvent) -> void:
	if visible:
		get_viewport().set_input_as_handled()

func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var shade := ColorRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.color = Color(0.03, 0.025, 0.035, 0.72)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(shade)
	_panel = Panel.new()
	_panel.name = "Panel"
	_panel.theme = DungeonTheme.THEME
	_panel.add_theme_stylebox_override("panel", DungeonTheme.panel())
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.position = Vector2(-220, -121)
	_panel.size = Vector2(440, 242)
	_root.add_child(_panel)
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.position = Vector2(12, 10)
	scroll.size = Vector2(416, 222)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(scroll)
	_content = VBoxContainer.new()
	_content.name = "Content"
	_content.custom_minimum_size.x = 400
	_content.add_theme_constant_override("separation", 3)
	scroll.add_child(_content)
	var header := HBoxContainer.new()
	_content.add_child(header)
	var title := _label("ACCOUNT", 19, DungeonTheme.GOLD_BRIGHT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_close_button = _button("X", _close_or_quit)
	header.add_child(_close_button)
	_status = _label("", 10, DungeonTheme.MUTED)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content.add_child(_status)
	var email_row := HBoxContainer.new()
	_form_rows.append(email_row)
	_content.add_child(email_row)
	_email = _line("Email address")
	_email.max_length = 254
	_email.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_email.text_changed.connect(_on_email_changed)
	email_row.add_child(_email)
	var pw_row := HBoxContainer.new()
	_form_rows.append(pw_row)
	_content.add_child(pw_row)
	var pw_fields := HBoxContainer.new()
	pw_fields.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pw_row.add_child(pw_fields)
	_password = _line("Password")
	_password.max_length = 128
	_password.secret = true
	_password.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sensitive_controls.append(_password)
	pw_fields.add_child(_password)
	_confirm = _line("Confirm password")
	_confirm.max_length = 128
	_confirm.secret = true
	_confirm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sensitive_controls.append(_confirm)
	pw_fields.add_child(_confirm)
	_password_toggle = _button("SHOW", _toggle_password)
	pw_row.add_child(_password_toggle)
	_username = _line("Display name (2-24 characters)")
	_username.max_length = 24
	_sensitive_controls.append(_username)
	_content.add_child(_username)
	_code = _line("Verification code")
	_code.max_length = 6
	_sensitive_controls.append(_code)
	var code_row := HBoxContainer.new()
	_form_rows.append(code_row)
	_content.add_child(code_row)
	_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	code_row.add_child(_code)
	_send_code = _button("SEND CODE", _request_code)
	code_row.add_child(_send_code)
	_remember = CheckBox.new()
	_remember.text = "Remember me on this device"
	_remember.button_pressed = false
	_content.add_child(_remember)
	var actions := HBoxContainer.new()
	_form_rows.append(actions)
	_content.add_child(actions)
	_submit = _button("LOGIN", _submit_form)
	_submit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(_submit)
	_mode_button = _button("CREATE ACCOUNT", _cycle_mode)
	_mode_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(_mode_button)
	_reset_button = _button("FORGOT PASSWORD", _open_reset)
	_content.add_child(_reset_button)
	var cloud := _label("Game saves are stored on this device.", 10, DungeonTheme.PSI)
	_content.add_child(cloud)
	var privacy := _label("Camera stays on this device.", 9, DungeonTheme.MUTED)
	_content.add_child(privacy)
	var logout := _button("LOG OUT", _logout)
	logout.name = "Logout"
	_content.add_child(logout)
	_profile_name = _line("Display name")
	_profile_name.max_length = 24
	_profile_email = _label("", 10, DungeonTheme.MUTED)
	_save_name = _button("SAVE NAME", _save_username)
	_content.add_child(_profile_name)
	_content.add_child(_profile_email)
	_content.add_child(_save_name)
	_content.move_child(_profile_name, 2)
	_content.move_child(_profile_email, 3)
	_content.move_child(_save_name, 4)
	for node in _content.get_children():
		if node is Control:
			node.theme = DungeonTheme.THEME

func _label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func _line(placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.custom_minimum_size.y = 22
	field.add_theme_font_override("font", _font)
	field.add_theme_font_size_override("font_size", 12)
	return field

func _button(value: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 22
	button.pressed.connect(action)
	return button

func _refresh() -> void:
	_close_button.text = "QUIT" if login_required and not AuthManager.authenticated else "X"
	_close_button.custom_minimum_size = Vector2(60 if login_required and not AuthManager.authenticated else 28, 24)
	var logged := AuthManager.authenticated
	for row in _form_rows:
		row.visible = not logged
	for c in [_email, _password, _confirm, _code, _remember, _submit, _mode_button, _send_code, _password_toggle, _reset_button, _username]:
		c.visible = not logged
	$Root/Panel/Scroll/Content/Logout.visible = logged
	_profile_name.visible = logged
	_profile_email.visible = logged
	_save_name.visible = logged
	if logged:
		_profile_email.text = AuthManager.mask_email()
		_profile_name.editable = not AuthManager.busy
		_save_name.disabled = AuthManager.busy
		return
	_email.editable = not AuthManager.busy
	_password.editable = not AuthManager.busy
	_confirm.editable = not AuthManager.busy
	_username.editable = not AuthManager.busy
	_code.editable = not AuthManager.busy
	_remember.disabled = AuthManager.busy
	_mode_button.disabled = AuthManager.busy
	_reset_button.disabled = AuthManager.busy
	_submit.disabled = AuthManager.busy
	_send_code.disabled = AuthManager.busy or _countdown > 0 or _email.text.strip_edges().is_empty()
	_password_toggle.disabled = AuthManager.busy
	_confirm.visible = _mode in ["REGISTER", "RESET"]
	_username.visible = _mode == "REGISTER"
	_code.visible = _mode in ["REGISTER", "RESET"]
	_send_code.visible = _mode in ["REGISTER", "RESET"]
	_remember.visible = _mode in ["LOGIN", "REGISTER"]
	_reset_button.visible = _mode == "LOGIN"
	_submit.text = _mode
	_mode_button.text = "CREATE ACCOUNT" if _mode == "LOGIN" else "BACK TO LOGIN"
	if _countdown > 0:
		_send_code.text = "WAIT %ds" % _countdown
	else:
		_send_code.text = "SEND CODE"

func _cycle_mode() -> void:
	if _mode == "LOGIN":
		_mode = "REGISTER"
	else:
		_mode = "LOGIN"
	if _mode != _challenge_purpose.to_upper():
		_clear_challenge()
		_pending_code_email = ""
		_pending_code_purpose = ""
	_clear_sensitive()
	_status.text = "Password: 12-128 characters; A-Z, a-z and 0-9 are all allowed."
	_refresh()

func _open_reset() -> void:
	if AuthManager.busy:
		return
	_mode = "RESET"
	if _challenge_purpose != "reset":
		_clear_challenge()
		_pending_code_email = ""
		_pending_code_purpose = ""
	_clear_sensitive()
	_status.text = "Enter your email and request a reset code."
	_refresh()

func _request_code() -> void:
	var addr := _email.text.strip_edges().to_lower()
	var purpose := "register" if _mode == "REGISTER" else "reset"
	if addr.is_empty():
		_status.text = "Enter your email address first."
		return
	if _challenge_email != addr or _challenge_purpose != purpose:
		_clear_challenge()
	_pending_code_email = addr
	_pending_code_purpose = purpose
	AuthManager.send_code(addr, purpose)
	_status.text = "Sending verification code…"

func _submit_form() -> void:
	if AuthManager.busy:
		return
	var addr := _email.text.strip_edges().to_lower()
	if _mode != "LOGIN" and (_password.text.length() < 12 or _password.text.length() > 128):
		_status.text = "Use a password of 12-128 characters."
		return
	if _mode == "LOGIN":
		if _password.text.is_empty():
			_status.text = "Enter your password."
			return
		AuthManager.login(addr, _password.text, _remember.button_pressed)
	elif _mode == "REGISTER":
		if not _valid_username(_username.text):
			_status.text = "Display name must be 2-24 letters, numbers, spaces, _ or -."
			return
		if _password.text != _confirm.text:
			_status.text = "Passwords do not match."
			return
		if not _valid_challenge(addr, "register"):
			_status.text = "Request and enter a new registration code."
			return
		AuthManager.register_account(addr, _password.text, _challenge_id, _code.text.strip_edges(), _remember.button_pressed, _username.text.strip_edges())
	else:
		if _password.text.is_empty():
			_status.text = "Enter a new password."
			return
		if _password.text != _confirm.text:
			_status.text = "Passwords do not match."
			return
		if not _valid_challenge(addr, "reset"):
			_status.text = "Request and enter a password reset code."
			return
		AuthManager.reset_password(addr, _password.text, _challenge_id, _code.text.strip_edges())
	_status.text = "Working…"

func _valid_challenge(addr: String, purpose: String) -> bool:
	return not _challenge_id.is_empty() and _challenge_email == addr and _challenge_purpose == purpose and not _code.text.strip_edges().is_empty()

func _on_request_finished(operation: String, ok: bool, message: String, data: Dictionary) -> void:
	if not visible:
		return
	if operation == "email_codes":
		if ok:
			var current_purpose := ""
			if _mode == "REGISTER":
				current_purpose = "register"
			elif _mode == "RESET":
				current_purpose = "reset"
			if _pending_code_email != _email.text.strip_edges().to_lower() or _pending_code_purpose != current_purpose:
				return
			_challenge_id = str(data.get("challenge_id", ""))
			_challenge_email = _pending_code_email
			_challenge_purpose = _pending_code_purpose
			_countdown = int(data.get("retry_after", 60))
			if _countdown > 0:
				_countdown_timer.start()
			else:
				_countdown_timer.stop()
			_status.text = message if not message.is_empty() else "Code sent. Check your email."
		else:
			_status.text = message if not message.is_empty() else AuthManager.last_error
			if int(data.get("retry_after", 0)) > 0:
				_countdown = int(data["retry_after"])
				_countdown_timer.start()
	elif operation == "update_profile":
		_status.text = message if not message.is_empty() else ("Name saved." if ok else (AuthManager.last_error if not AuthManager.last_error.is_empty() else "Could not save display name. Please try again."))
		if ok:
			_profile_name.text = AuthManager.username
	elif operation in ["register", "login", "password_reset", "logout", "restore"]:
		_status.text = message if not message.is_empty() else ("Success." if ok else AuthManager.last_error)
		if ok and operation in ["login", "register"]:
			_clear_sensitive()
		if ok and operation == "password_reset":
			_clear_sensitive()
			_clear_challenge()
			_mode = "LOGIN"
	_refresh()

func _on_busy_changed(_busy: bool) -> void:
	if visible:
		_refresh()

func _close_or_quit() -> void:
	if login_required and not AuthManager.authenticated:
		get_tree().quit()
	else:
		close()

func _on_session_changed() -> void:
	if visible:
		if AuthManager.authenticated:
			_profile_name.text = AuthManager.username
		_refresh()

func _on_email_changed(value: String) -> void:
	if value.strip_edges().to_lower() != _challenge_email:
		_clear_challenge()
		_pending_code_email = ""
		_pending_code_purpose = ""
	_refresh()

func _clear_challenge() -> void:
	_challenge_id = ""
	_challenge_email = ""
	_challenge_purpose = ""
	_pending_code_email = ""
	_pending_code_purpose = ""
	_countdown = 0
	if is_instance_valid(_countdown_timer):
		_countdown_timer.stop()

func _tick_countdown() -> void:
	_countdown = maxi(0, _countdown - 1)
	_refresh()
	if _countdown == 0:
		_countdown_timer.stop()

func _toggle_password() -> void:
	var show := _password.secret
	_password.secret = not show
	_confirm.secret = not show
	_password_toggle.text = "HIDE" if show else "SHOW"

func _valid_username(value: String) -> bool:
	var name := value.strip_edges()
	if name.length() < 2 or name.length() > 24:
		return false
	var regex := RegEx.new()
	regex.compile("^[\\p{L}\\p{N}_ -]+$")
	return regex.search(name) != null

func _save_username() -> void:
	if AuthManager.busy:
		return
	if not _valid_username(_profile_name.text):
		_status.text = "Display name must be 2-24 letters, numbers, spaces, _ or -."
		return
	_status.text = "Saving display name…"
	AuthManager.update_username(_profile_name.text.strip_edges())

func _logout() -> void:
	if not AuthManager.busy:
		AuthManager.logout()

func _clear_sensitive() -> void:
	for field in _sensitive_controls:
		field.clear()
	_password.secret = true
	_confirm.secret = true
	_password_toggle.text = "SHOW"
