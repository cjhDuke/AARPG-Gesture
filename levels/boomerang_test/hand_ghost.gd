class_name HandGhost extends Node2D
## 练习场的"手影"原型：把摄像头里的手淡淡地画进游戏画面，让用户知道手在操作框里的位置。
## G 键循环 OFF -> HAND -> CAMERA -> OFF（默认 HAND）。只在练习场使用，不进正式关卡。
##
## HAND：在光标处画手的半透明剪影（轮廓多边形，掌心对准光标，等比例缩放），
##       并把操作框的边界画成细线框，手靠近检测边界时边界线会出现在手影旁边。
## CAMERA：把摄像头画面里操作框那一块按手 -> 光标的映射（不钳制）严格对齐地铺在房间上。
## 层级：z_index 0、位置在原点，夹在地板（z -1）和主角（z 2）/ 敌人（y 排序）之间。

enum Mode { OFF, HAND, CAMERA }

## 手影缩放：每个摄像头像素对应多少游戏像素
const GHOST_SCALE : float = 0.6
const COLOR_OPEN := Color( 1, 1, 1 )
const COLOR_FIST := Color( 1.0, 0.6, 0.15 )
const COLOR_EDGE := Color( 1.0, 0.25, 0.2 )
const FILL_ALPHA : float = 0.30
const OUTLINE_ALPHA : float = 0.9
## 描边和线框下面垫的深色边，保证在浅色地板上也看得清
const SHADOW_COLOR := Color( 0, 0, 0, 0.45 )
## 操作框线框的透明度；手贴边（edge）时变红、加粗
const BOX_ALPHA : float = 0.6
const BOX_ALPHA_EDGE : float = 0.8
## CAMERA 模式的画面透明度
const CAMERA_ALPHA : float = 0.22

var mode : Mode = Mode.HAND :
	set( v ):
		mode = v
		queue_redraw()

var _controller : HandController


func _ready() -> void:
	_controller = get_parent().get_node( "HandController" )
	z_index = 0
	process_mode = Node.PROCESS_MODE_ALWAYS


func mode_name() -> String:
	return Mode.keys()[mode]


func cycle_mode() -> void:
	mode = ( (mode + 1) % Mode.size() ) as Mode


func _unhandled_input( event : InputEvent ) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_G:
		cycle_mode()
		get_viewport().set_input_as_handled()


func _process( _delta : float ) -> void:
	# 每帧重画：手影跟着手和光标动
	if mode != Mode.OFF:
		queue_redraw()


func _draw() -> void:
	if mode == Mode.OFF or not GestureInput.connected:
		return
	var st : Dictionary = GestureInput.last_state
	var roi := _read_pair( st.get( "roi", null ), 4 )
	var frame := _read_pair( st.get( "frame", null ), 2 )
	if roi.is_empty() or frame.is_empty() or roi[2] <= 0.0 or roi[3] <= 0.0:
		return
	if mode == Mode.HAND:
		_draw_hand( st, roi )
	else:
		_draw_camera( roi, frame )


## 把 JSON 数组读成 float 列表；格式不对返回空数组
func _read_pair( v : Variant, n : int ) -> Array[float]:
	var out : Array[float] = []
	if not ( v is Array ) or v.size() < n:
		return out
	for i in n:
		out.append( float( v[i] ) )
	return out


func _draw_hand( st : Dictionary, roi : Array[float] ) -> void:
	if not bool( st.get( "hand", false ) ):
		return
	var roi_size := Vector2( roi[2], roi[3] )
	var palm_px := Vector2( float( st.get( "cx", 0.5 ) ), float( st.get( "cy", 0.5 ) ) ) * roi_size
	# 摄像头像素 -> 世界坐标：光标位置 + (点 - 掌心) * 缩放
	var origin := _controller.cursor_pos - palm_px * GHOST_SCALE
	var base := COLOR_FIST if GestureInput.is_fist else COLOR_OPEN

	var edge := bool( st.get( "edge", false ) )
	var box_color := COLOR_EDGE if edge else base
	box_color.a = BOX_ALPHA_EDGE if edge else BOX_ALPHA
	var box := Rect2( origin, roi_size * GHOST_SCALE )
	draw_rect( box, SHADOW_COLOR, false, 4.0 if edge else 3.0 )
	draw_rect( box, box_color, false, 2.0 if edge else 1.0 )

	var contour : Variant = st.get( "contour", null )
	if not ( contour is Array ) or contour.size() < 3:
		return
	var pts := PackedVector2Array()
	for p in contour:
		if p is Array and p.size() >= 2:
			pts.append( origin + Vector2( float( p[0] ), float( p[1] ) ) * roi_size * GHOST_SCALE )
	if pts.size() < 3:
		return
	# 填充：三角化失败（自相交等）时只画描边
	if not Geometry2D.triangulate_polygon( pts ).is_empty():
		var fill := base
		fill.a = FILL_ALPHA
		draw_colored_polygon( pts, fill )
	var line := base
	line.a = OUTLINE_ALPHA
	var closed := pts.duplicate()
	closed.append( pts[0] )
	draw_polyline( closed, SHADOW_COLOR, 3.0 )
	draw_polyline( closed, line, 1.0 )


func _draw_camera( roi : Array[float], frame : Array[float] ) -> void:
	var tex := GestureInput.frame_texture
	if tex == null:
		return
	# 操作框在整幅画面里的位置 -> 纹理像素区域（纹理可能是整幅缩略图，也可能是别的阶段的画面，按比例裁）
	var tw := float( tex.get_width() )
	var th := float( tex.get_height() )
	var src := Rect2( roi[0] / frame[0] * tw, roi[1] / frame[1] * th, roi[2] / frame[0] * tw, roi[3] / frame[1] * th )
	# 归一化 (0,0) 和 (1,1) 两个角用不钳制的映射换成世界坐标，作为这张图的矩形（会超出屏幕、横纵比例不同）
	var a := _controller.hand_to_arena_unclamped( Vector2.ZERO )
	var b := _controller.hand_to_arena_unclamped( Vector2.ONE )
	draw_texture_rect_region( tex, Rect2( a, b - a ), src, Color( 1, 1, 1, CAMERA_ALPHA ) )
