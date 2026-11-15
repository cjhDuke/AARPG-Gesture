extends CanvasLayer
## 手势提示框：画面正上方居中的小框，告诉玩家当前识别结果。
## 由 GestureInput 在 _ready 里实例化为子节点，所以标题、关卡、结算时都能看到。
## 不受 F1（隐藏摄像头面板）影响。

const FONT_SIZE := 12
const TOP_Y := 3.0
const SCREEN_W := 480.0
const PAD := Vector2(6, 3)
## 张开状态弹出后停留多久再淡出（秒）
const OPEN_HOLD := 1.0
const OPEN_FADE := 0.35

const COL_WARN := Color("#e2967a")
const COL_SCAN := DungeonTheme.GOLD_BRIGHT
const COL_FIST := DungeonTheme.PSI
const COL_OPEN := DungeonTheme.TEXT
const COL_READY := DungeonTheme.PSI
## 标定完成后 READY 提示停留多久（毫秒）
const READY_HOLD_MSEC := 1500

var _gi: Node
var _root: Control
var _bg: Panel
var _label: Label
var _text := ""
var _tween: Tween
## 临时消息（如 PSI LOW）：文字和到期时间（毫秒）
var _flash_text := ""
var _flash_until_msec := 0
## 上一帧是否已标定；未连接时记为 true，避免连上一个早已标定好的识别端就弹 READY
var _prev_calibrated := true
var _ready_until_msec := 0


func _ready() -> void:
	_gi = get_parent()
	_root = Control.new()
	_root.theme = DungeonTheme.THEME
	_ignore(_root)
	add_child(_root)

	_bg = Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = DungeonTheme.BACKGROUND
	style.border_color = DungeonTheme.GOLD
	style.set_border_width_all(1)
	_bg.add_theme_stylebox_override("panel", style)
	_ignore(_bg)
	_root.add_child(_bg)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_label.add_theme_constant_override("outline_size", 0)
	_label.position = PAD
	_ignore(_label)
	_root.add_child(_label)
	_root.modulate.a = 0.0


## 临时消息：盖过 OPEN / FIST 提示，但不盖过 CAMERA OFFLINE / 采集 / 未采背景 / READY / NO HAND
func flash_message(text: String, seconds: float) -> void:
	_flash_text = text
	_flash_until_msec = Time.get_ticks_msec() + int(seconds * 1000.0)


func _ignore(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.focus_mode = Control.FOCUS_NONE


func _process(_delta: float) -> void:
	if not _gi.connected:
		_prev_calibrated = true
	elif _gi.calibrated and not _prev_calibrated:
		_ready_until_msec = Time.get_ticks_msec() + READY_HOLD_MSEC
	if _gi.connected:
		_prev_calibrated = _gi.calibrated
	var info := _current_info()
	var text: String = info[0]
	if text == _text:
		return
	_text = text
	if text == "":
		_hide()
		return
	_show(text, info[1], info[2])


## 返回 [文字, 颜色, 是否常驻]；文字为空表示不显示
func _current_info() -> Array:
	if not _gi.connected:
		return ["CAMERA OFFLINE", COL_WARN, true]
	if _gi.calibrating:
		return ["KEEP HAND OUT", COL_SCAN, true]
	if not _gi.calibrated:
		return ["HAND OUT, PRESS F3", COL_WARN, true]
	# 背景刚采完：提示可以把手放进来（和状态类提示同级，暂停时也显示）
	if Time.get_ticks_msec() < _ready_until_msec:
		return ["READY - HAND IN", COL_READY, true]
	# 暂停（标题、暂停菜单、结算面板）时手势不控制菜单，只保留上面的状态类提示
	if get_tree().paused:
		return ["", COL_OPEN, false]
	if not _gi.hand_present:
		return ["NO HAND", COL_WARN, true]
	if Time.get_ticks_msec() < _flash_until_msec:
		return [_flash_text, COL_WARN, false]
	if _gi.is_fist:
		return ["FIST - BOOMERANG", COL_FIST, true]
	return ["OPEN - MOVE", COL_OPEN, false]


func _hide() -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_root, "modulate:a", 0.0, 0.1)


func _show(text: String, color: Color, persistent: bool) -> void:
	_label.text = text
	_label.add_theme_color_override("font_color", color)
	var size := _label.get_minimum_size() + PAD * 2.0
	_bg.size = size
	_root.size = size
	_root.position = Vector2(roundf((SCREEN_W - size.x) * 0.5), TOP_Y)
	_root.pivot_offset = size * 0.5

	if _tween:
		_tween.kill()
	_root.scale = Vector2(1.18, 1.18)
	_root.modulate.a = 0.0
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_root, "scale", Vector2.ONE, 0.12)
	_tween.tween_property(_root, "modulate:a", 1.0, 0.08)
	if not persistent:
		_tween.chain().tween_interval(OPEN_HOLD)
		_tween.chain().tween_property(_root, "modulate:a", 0.0, OPEN_FADE)
