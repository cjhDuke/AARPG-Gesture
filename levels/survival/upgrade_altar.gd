class_name UpgradeAltar extends Node2D
## 强化三选一台座：水平一排（最多 3 个），主角走到台座 RADIUS 像素内连续停留 DWELL_TIME 秒就选中它。
## 出现后先有 FADE_TIME 秒淡入期不可选（主角开箱后多半还站在附近）；离开范围进度清零。
## 台座上画图标（上下浮动）、名称；说明只显示离主角最近、且在 DESC_SHOW_DIST 内的那个台座的，
## 这样三个台座的文字不会互相重叠。脚下一圈进度环。
## 选中后发 chosen( id )，由关卡施加强化并调用 dismiss()；关卡清场时直接 queue_free 即可。

const FONT : Font = preload( "res://ui/fonts/abaddon_light.ttf" )
## 台座一排的纵坐标（房间里偏下，避开高台、宝箱位置，在手势光标可达范围内）和间距
const ROW_Y : float = 222.0
const SPACING : float = 84.0
const FADE_TIME : float = 0.8
const DWELL_TIME : float = 0.8
## 触发范围半径（主角脚底原点到台座中心，像素）
const RADIUS : float = 14.0
const DESC_SHOW_DIST : float = 44.0
const NAME_SIZE : int = 8
const DESC_SIZE : int = 8

signal chosen( id : String )

var player : Player
## 台座上的强化 id（最多 3 个）
var ids : Array[String] = []

var _slots : Array[Dictionary] = []
var _age : float = 0.0
var _done : bool = false
var _top : Node2D


func _ready() -> void:
	# 台座本体铺在地上（低于主角的 z_index 2），图标和文字放到最上层
	z_index = 1
	var n := ids.size()
	for i in n:
		var p := Vector2( HandController.CENTER.x + ( i - ( n - 1 ) * 0.5 ) * SPACING, ROW_Y )
		_slots.append( { "id": ids[i], "pos": p, "progress": 0.0 } )
	_top = Node2D.new()
	_top.z_index = 50
	_top.draw.connect( _draw_top )
	add_child( _top )
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property( self, "modulate:a", 1.0, FADE_TIME )


## 台座的世界坐标（测试和关卡用）
func slot_position( i : int ) -> Vector2:
	return _slots[i]["pos"]


func slot_ids() -> Array[String]:
	return ids


## 选完后调用：台座淡出消失
func dismiss() -> void:
	_done = true
	var tween := create_tween()
	tween.tween_property( self, "modulate:a", 0.0, 0.25 )
	tween.tween_callback( queue_free )


func _process( delta : float ) -> void:
	_age += delta
	queue_redraw()
	_top.queue_redraw()
	if _done or player == null or player.is_dead or _age < FADE_TIME:
		return
	for s in _slots:
		if player.global_position.distance_to( s["pos"] ) <= RADIUS:
			s["progress"] += delta
			if s["progress"] >= DWELL_TIME:
				_done = true
				chosen.emit( s["id"] )
				return
		else:
			s["progress"] = 0.0


## 台座本体和进度环
func _draw() -> void:
	for s in _slots:
		var p : Vector2 = s["pos"]
		# 石座：底盘椭圆 + 短柱 + 顶面椭圆
		draw_colored_polygon( _ellipse( p + Vector2( 0, 2 ), 13.0, 5.0 ), Color( 0.22, 0.23, 0.28 ) )
		draw_rect( Rect2( p + Vector2( -8, -5 ), Vector2( 16, 7 ) ), Color( 0.32, 0.33, 0.4 ) )
		draw_colored_polygon( _ellipse( p + Vector2( 0, -5 ), 9.0, 3.5 ), Color( 0.5, 0.52, 0.62 ) )
		# 触发范围环（淡）和进度弧
		draw_arc( p, RADIUS, 0.0, TAU, 28, Color( 1, 1, 1, 0.22 ), 1.0 )
		var k : float = clampf( s["progress"] / DWELL_TIME, 0.0, 1.0 )
		if k > 0.0:
			draw_arc( p, RADIUS, -PI / 2.0, -PI / 2.0 + TAU * k, 28, Color( 0.5, 1.0, 0.7 ), 2.0 )


func _draw_top() -> void:
	var t := _age
	var near := -1
	var near_d := DESC_SHOW_DIST
	if player != null:
		for i in _slots.size():
			var d := player.global_position.distance_to( _slots[i]["pos"] )
			if d < near_d:
				near_d = d
				near = i
	for i in _slots.size():
		var s : Dictionary = _slots[i]
		var p : Vector2 = s["pos"]
		var def := Upgrades.get_def( s["id"] )
		var bob := sin( t * 3.0 + i * 1.3 ) * 2.0
		Upgrades.draw_icon( _top, s["id"], p + Vector2( 0, -20 + bob ), 20.0 )
		_text( String( def["name"] ), p + Vector2( 0, -38 ), NAME_SIZE, Color( 1.0, 0.95, 0.7 ) )
	if near >= 0:
		var def := Upgrades.get_def( _slots[near]["id"] )
		_text( String( def["desc"] ), _slots[near]["pos"] + Vector2( 0, 16 ), DESC_SIZE, Color( 0.75, 0.9, 1.0 ) )


## 水平居中、带黑色描边的文字（pos 是文字基线中点）
func _text( text : String, pos : Vector2, size : int, color : Color ) -> void:
	var w := 160.0
	var at := pos + Vector2( -w * 0.5, 0 )
	_top.draw_string_outline( FONT, at, text, HORIZONTAL_ALIGNMENT_CENTER, w, size, 3, Color.BLACK )
	_top.draw_string( FONT, at, text, HORIZONTAL_ALIGNMENT_CENTER, w, size, color )


func _ellipse( c : Vector2, rx : float, ry : float ) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * i / 16.0
		pts.append( c + Vector2( cos( a ) * rx, sin( a ) * ry ) )
	return pts
