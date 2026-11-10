extends CanvasLayer
## 手势调试面板：左上角小窗，显示识别画面和当前手势。
## F1 显示/隐藏，F2 切换阶段 0-3，F3 请求标定，F4 切换操作框位置。

const PANEL_W := 110
const FONT_SIZE := 16
const STAGE_NAMES := ["RAW", "BPROJ", "THRESH", "MORPH"]
const ZONE_TEXT := {"center": "-", "up": "UP", "down": "DOWN", "left": "LEFT", "right": "RIGHT"}

var _gi: Node
var _root: Control
var _image: TextureRect
var _offline: Label
var _line_gesture: Label
var _line_perf: Label
var _line_stage: Label
var _stage := 0


func _ready() -> void:
	_gi = get_parent()
	_root = Control.new()
	# 放左上角：右上角是 PlayerHud 的心形血量
	_root.position = Vector2(2, 2)
	_root.size = Vector2(PANEL_W, 124)
	_ignore(_root)
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.size = _root.size
	_ignore(bg)
	_root.add_child(bg)

	_image = TextureRect.new()
	_image.position = Vector2(0, 0)
	_image.size = Vector2(PANEL_W, 80)
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_ignore(_image)
	_root.add_child(_image)

	_offline = _make_label(Vector2(0, 34), "NO CAMERA")
	_offline.size.x = PANEL_W
	_offline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_line_gesture = _make_label(Vector2(2, 80), "")
	_line_perf = _make_label(Vector2(2, 93), "")
	_line_stage = _make_label(Vector2(2, 106), "")

	_gi.state_updated.connect(_on_state)
	_gi.frame_updated.connect(func(t: ImageTexture) -> void: _image.texture = t)
	_gi.connection_changed.connect(_on_connection)
	_on_connection(_gi.connected)
	_refresh_stage()


func _ignore(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.focus_mode = Control.FOCUS_NONE


func _make_label(pos: Vector2, text: String) -> Label:
	var l := Label.new()
	l.position = pos
	l.text = text
	l.add_theme_font_size_override("font_size", FONT_SIZE)
	_ignore(l)
	_root.add_child(l)
	return l


func _on_connection(c: bool) -> void:
	_offline.visible = not c
	if not c:
		_image.texture = null
		_line_gesture.text = ""
		_line_perf.text = ""


func _on_state(st: Dictionary) -> void:
	var g := str(st.get("gesture", "none")).to_upper()
	var z: String = ZONE_TEXT.get(str(st.get("zone", "center")), "-")
	_line_gesture.text = "%s %s" % [g, z]
	_line_perf.text = "%dfps %.1fms" % [int(float(st.get("fps", 0.0))), float(st.get("proc_ms", 0.0))]
	_refresh_stage()


func _refresh_stage() -> void:
	var cal := ""
	if not _gi.last_state.is_empty() and not bool(_gi.last_state.get("calibrated", false)):
		cal = " !CAL"
	_line_stage.text = "S%d %s%s" % [_stage, STAGE_NAMES[_stage], cal]


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_F1:
			_root.visible = not _root.visible
		KEY_F2:
			_stage = (_stage + 1) % 4
			_gi.set_stage(_stage)
			_refresh_stage()
		KEY_F3:
			_gi.request_calibrate()
		KEY_F4:
			_gi.cycle_roi()
