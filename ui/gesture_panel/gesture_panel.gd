extends CanvasLayer
## 手势调试面板：左上角小窗，显示识别画面和当前手势。
## 默认是紧凑模式（只有一小块画面，少挡游戏区域）。
## F1 在 紧凑 / 完整（带文字）/ 隐藏 之间切换，F2 切换阶段 0-3，F3 重新采集背景，F4 切换操作框位置，F5 开始/停止录像。

const PANEL_W := 110
const COMPACT_SIZE := Vector2(64, 48)
const FULL_IMAGE_SIZE := Vector2(PANEL_W, 80)
const FULL_SIZE := Vector2(PANEL_W, 124)
enum Mode { COMPACT, FULL, HIDDEN }
const FONT_SIZE := 16
const STAGE_NAMES := ["RAW", "DIFF", "MASK", "MORPH"]

var _gi: Node
var _root: Control
var _image: TextureRect
var _offline: Label
var _line_gesture: Label
var _line_perf: Label
var _line_stage: Label
var _stage := 0
var _mode := Mode.COMPACT
var _bg: ColorRect


func _ready() -> void:
	_gi = get_parent()
	_root = Control.new()
	# 放左上角：右上角是 PlayerHud 的心形血量
	_root.position = Vector2(2, 2)
	_root.size = Vector2(PANEL_W, 124)
	_ignore(_root)
	add_child(_root)

	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, 0.6)
	_ignore(_bg)
	_root.add_child(_bg)

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
	_apply_mode()


## 紧凑模式只留一小块画面；没连上识别端时整个收起（正上方的提示框会显示 CAMERA OFFLINE）
func _apply_mode() -> void:
	var full := _mode == Mode.FULL
	_root.visible = full or (_mode == Mode.COMPACT and _gi.connected)
	_root.size = FULL_SIZE if full else COMPACT_SIZE
	_bg.size = _root.size
	_image.size = FULL_IMAGE_SIZE if full else COMPACT_SIZE
	_offline.visible = full and not _gi.connected
	for l in [_line_gesture, _line_perf, _line_stage]:
		l.visible = full


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
	_apply_mode()
	if not c:
		_image.texture = null
		_line_gesture.text = ""
		_line_perf.text = ""


func _on_state(st: Dictionary) -> void:
	var g := str(st.get("gesture", "none")).to_upper()
	_line_gesture.text = "%s %.2f" % [g, float(st.get("open_ratio", 0.0))]
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
			_mode = (_mode + 1) % Mode.size() as Mode
			_apply_mode()
		KEY_F2:
			_stage = (_stage + 1) % 4
			_gi.set_stage(_stage)
			_refresh_stage()
		KEY_F3:
			_gi.request_calibrate()
		KEY_F4:
			_gi.cycle_roi()
		KEY_F5:
			_gi.toggle_record()
