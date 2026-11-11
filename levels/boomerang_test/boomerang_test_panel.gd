class_name BoomerangTestPanel extends CanvasLayer
## 回旋镖练习场的调试面板：左侧实时状态 + 可调参数表，右侧事件日志 + 按键说明。
## 参数改动立刻作用到 HandController，并同步到场上已有的和之后新建的回旋镖。
## 按键：[ ] 选参数，- = 减 / 加一档，0 全部恢复默认，I 切换念力无限。

const BOOMERANG_SCENE : PackedScene = preload( "res://player/boomerang.tscn" )
const FONT_SIZE : int = 8
const LINE_H : float = 9.0
const LOG_LINES : int = 6
const COL_TEXT := Color( 0.92, 0.92, 0.92 )
const COL_DIM := Color( 0.6, 0.62, 0.66 )
const COL_HEAD := Color( 0.4, 0.9, 1.0 )
const COL_SELECT := Color( 1.0, 0.85, 0.3 )
const COL_WARN := Color( 1.0, 0.5, 0.4 )
const COL_BG := Color( 0, 0, 0, 0.55 )

## 左栏起点：摄像头面板（紧凑模式 64x48）下方；右栏起点：右上角血量下方
const LEFT_POS := Vector2( 2, 54 )
const LEFT_W : float = 92.0
const RIGHT_POS := Vector2( 386, 34 )
const RIGHT_W : float = 92.0

## 可调参数表，每项：name 显示名、kind（boom 回旋镖 / ctrl 控制器 / psi_sec 念力秒数）、key 属性名、
## step 步长、min / max 上下限、decimals 小数位
var _params : Array[Dictionary] = []
var _selected : int = 0
## 回旋镖三项参数的当前值，由 _apply_to_boomerang 同步到每个回旋镖实例
var _boom_values : Dictionary = {}
var _defaults : Array[float] = []
var _log : Array[Array] = []  # [发生时间（秒），文字]

var _controller : HandController
var _player : Player
var _status_label : Label
var _params_label : RichTextLabel
var _log_label : Label
var _help_label : Label


func _ready() -> void:
	_controller = get_parent().get_node( "HandController" )
	_player = PlayerManager.player
	_read_boomerang_defaults()
	_build_params()
	for p in _params:
		_defaults.append( _get_param( p ) )
	_build_ui()
	_controller.control_event.connect( _on_control_event )
	get_tree().node_added.connect( _on_node_added )
	_refresh_params()


## 回旋镖三项参数的默认值取自场景里的实际值，不在这里重复写数字
func _read_boomerang_defaults() -> void:
	var proto := BOOMERANG_SCENE.instantiate() as Boomerang
	_boom_values = {
		"guided_max_speed": proto.guided_max_speed,
		"guided_accel": proto.guided_accel,
		"guided_gain": proto.guided_gain,
	}
	proto.free()


func _build_params() -> void:
	_params = [
		_param( "BOOM SPEED", "boom", "guided_max_speed", 20.0, 100.0, 800.0, 0 ),
		_param( "BOOM ACCEL", "boom", "guided_accel", 200.0, 400.0, 6000.0, 0 ),
		_param( "BOOM GAIN", "boom", "guided_gain", 1.0, 2.0, 30.0, 0 ),
		_param( "CURSOR SMOOTH", "ctrl", "guided_cursor_smooth_time", 0.01, 0.01, 0.3, 2 ),
		_param( "CURSOR SPEED", "ctrl", "guided_cursor_max_speed", 20.0, 100.0, 1000.0, 0 ),
		_param( "HAND GRACE", "ctrl", "guided_hand_grace", 0.1, 0.0, 2.0, 1 ),
		# 面板上显示"连续操控多少秒耗尽"，控制器里存的是每秒消耗量
		_param( "PSI DRAIN SEC", "psi_sec", "psi_drain", 0.5, 1.0, 20.0, 1 ),
	]


func _param( label : String, kind : String, key : String, step : float, lo : float, hi : float, decimals : int ) -> Dictionary:
	return { "name": label, "kind": kind, "key": key, "step": step, "min": lo, "max": hi, "decimals": decimals }


func _get_param( p : Dictionary ) -> float:
	match p["kind"]:
		"boom":
			return _boom_values[p["key"]]
		"psi_sec":
			return 1.0 / _controller.psi_drain
		_:
			return _controller.get( p["key"] )


func _set_param( p : Dictionary, v : float ) -> void:
	match p["kind"]:
		"boom":
			_boom_values[p["key"]] = v
			_apply_to_boomerang( _find_boomerang() )
		"psi_sec":
			_controller.psi_drain = 1.0 / v
		_:
			_controller.set( p["key"], v )


func _build_ui() -> void:
	var left := _make_box( LEFT_POS, Vector2( LEFT_W, 17 * LINE_H + 4 ) )
	_status_label = _make_label( left )
	_status_label.size = Vector2( LEFT_W - 4, 9 * LINE_H )
	_params_label = RichTextLabel.new()
	_params_label.bbcode_enabled = true
	_params_label.fit_content = false
	_params_label.scroll_active = false
	_params_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_params_label.position = Vector2( 2, 9 * LINE_H + 4 )
	_params_label.size = Vector2( LEFT_W - 4, 8 * LINE_H )
	_style( _params_label )
	_params_label.add_theme_color_override( "default_color", COL_TEXT )
	left.add_child( _params_label )

	var right := _make_box( RIGHT_POS, Vector2( RIGHT_W, (LOG_LINES + 1 + 6) * LINE_H + 6 ) )
	_log_label = _make_label( right )
	_log_label.size = Vector2( RIGHT_W - 4, (LOG_LINES + 1) * LINE_H )
	_help_label = _make_label( right )
	_help_label.position.y = (LOG_LINES + 1) * LINE_H + 6
	_help_label.size = Vector2( RIGHT_W - 4, 6 * LINE_H )
	_help_label.add_theme_color_override( "font_color", COL_DIM )
	_help_label.text = "[ ]  SELECT\n- =  ADJUST\n0  RESET ALL\nI  INFINITE PSI\nF1 PANEL  F3 RESCAN\nESC  MENU"


func _make_box( pos : Vector2, size : Vector2 ) -> ColorRect:
	var box := ColorRect.new()
	box.color = COL_BG
	box.position = pos
	box.size = size
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child( box )
	return box


func _make_label( parent : Control ) -> Label:
	var l := Label.new()
	l.position = Vector2( 2, 2 )
	l.clip_text = true
	l.add_theme_color_override( "font_color", COL_TEXT )
	_style( l )
	parent.add_child( l )
	return l


## 小字号 + 去掉行距，所有文字控件共用
func _style( c : Control ) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_theme_font_size_override( "font_size", FONT_SIZE )
	c.add_theme_font_size_override( "normal_font_size", FONT_SIZE )
	c.add_theme_constant_override( "line_spacing", 0 )
	c.add_theme_constant_override( "outline_size", 0 )


func _process( _delta : float ) -> void:
	_refresh_status()
	_refresh_log()  # 日志里是相对现在的秒数，每帧都要刷新


func _unhandled_input( event : InputEvent ) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_BRACKETLEFT:
			_selected = (_selected + _params.size() - 1) % _params.size()
		KEY_BRACKETRIGHT:
			_selected = (_selected + 1) % _params.size()
		KEY_MINUS:
			_adjust( -1 )
		KEY_EQUAL:
			_adjust( 1 )
		KEY_0:
			_reset_all()
		KEY_I:
			_controller.psi_infinite = not _controller.psi_infinite
		_:
			return
	_refresh_params()
	get_viewport().set_input_as_handled()


func _adjust( dir : int ) -> void:
	var p : Dictionary = _params[_selected]
	var v := _get_param( p ) + dir * float( p["step"] )
	# 按小数位取整，避免 0.1 累加出 0.30000001
	v = snappedf( clampf( v, float( p["min"] ), float( p["max"] ) ), pow( 10.0, -int( p["decimals"] ) ) )
	_set_param( p, v )


func _reset_all() -> void:
	for i in _params.size():
		_set_param( _params[i], _defaults[i] )
	_controller.psi_infinite = false


# ---------- 回旋镖参数同步 ----------

func _find_boomerang() -> Boomerang:
	var abilities : PlayerAbilities = _player.get_node( "Abilities" )
	return abilities.boomerang_instance if abilities.has_boomerang() else null


func _apply_to_boomerang( b : Boomerang ) -> void:
	if b == null:
		return
	b.guided_max_speed = _boom_values["guided_max_speed"]
	b.guided_accel = _boom_values["guided_accel"]
	b.guided_gain = _boom_values["guided_gain"]


## 之后新建的回旋镖（每次起飞都会实例化一个）在进入场景树时套用当前参数
func _on_node_added( node : Node ) -> void:
	if node is Boomerang:
		_apply_to_boomerang( node )


# ---------- 显示 ----------

func _on_control_event( text : String ) -> void:
	_log.append( [ Time.get_ticks_msec() / 1000.0, text ] )
	while _log.size() > LOG_LINES:
		_log.pop_front()
	_refresh_log()


func _refresh_status() -> void:
	var gi := GestureInput
	var st : Dictionary = gi.last_state
	var gesture := str( st.get( "gesture", "none" ) ).to_upper() if gi.connected else "OFFLINE"
	var dist_text := "--"
	var b := _find_boomerang()
	if b != null and _controller.guided:
		var d := (b.global_position + Boomerang.SPRITE_OFFSET).distance_to( _controller.cursor_pos )
		dist_text = "%d" % int( d )
	_status_label.text = "\n".join( [
		"GESTURE %s" % gesture,
		"OPEN %.2f" % float( st.get( "open_ratio", 0.0 ) ),
		"HAND %s" % ( "YES" if gi.hand_present else "NO" ),
		"EDGE %s" % ( "YES" if bool( st.get( "edge", false ) ) else "NO" ),
		"PX/PY %.2f %.2f" % [ gi.hand_pos.x, gi.hand_pos.y ],
		"GUIDED %s" % ( "YES" if _controller.guided else "NO" ),
		"PSI %d%%%s" % [ int( roundf( _controller.psi * 100.0 ) ), "  INF" if _controller.psi_infinite else "" ],
		"DIST %s" % dist_text,
	] )


func _refresh_params() -> void:
	var lines : PackedStringArray = [ "[color=#66e5ff]PARAMS[/color]" ]
	for i in _params.size():
		var p : Dictionary = _params[i]
		var v := _get_param( p )
		var changed : bool = not is_equal_approx( v, _defaults[i] )
		var text := "%s %s" % [ p["name"], String.num( v, int( p["decimals"] ) ) ]
		if i == _selected:
			lines.append( "[color=#ffd94d]> %s[/color]" % text )
		elif changed:
			lines.append( "[color=#ff8066]  %s[/color]" % text )
		else:
			lines.append( "  " + text )
	_params_label.text = "\n".join( lines )


func _refresh_log() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var lines : PackedStringArray = [ "EVENTS" ]
	for i in range( _log.size() - 1, -1, -1 ):
		lines.append( "%5.1fs %s" % [ now - float( _log[i][0] ), _log[i][1] ] )
	_log_label.text = "\n".join( lines )
