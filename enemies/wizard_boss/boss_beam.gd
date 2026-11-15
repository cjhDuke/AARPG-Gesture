class_name BossBeam extends Node2D
## 巫师的光束：先在地面画 WARN_TIME 秒预警线（位置在生成时锁定，不再跟随主角），
## 然后 FIRE_TIME 秒光束（energy_beam.png 沿线平铺），线内的主角受 1 点伤害（一道光束最多伤一次）。
## 光束只检测主角受击层，不伤小怪。贯穿整个房间，画在主角之上。

enum BeamState { WARN, FIRE, DONE }

const TEXTURE : Texture2D = preload( "res://enemies/wizard_boss/energy_beam.png" )
const SOUND : AudioStream = preload( "res://enemies/wizard_boss/boss_beam.wav" )
const WARN_TIME : float = 1.0
const FIRE_TIME : float = 0.6
## 光束宽度（像素）
const WIDTH : float = 22.0
## 光束覆盖的范围（世界坐标）：比可见地板（x 16..496、y 9..279）两头各多出一截
const SPAN_MIN := Vector2( -16, -16 )
const SPAN_MAX := Vector2( 528, 304 )
const PLAYER_HURT_LAYER : int = 2

var horizontal : bool = true
## 横向光束是 y 坐标，纵向是 x 坐标
var line_pos : float = 0.0
var state : BeamState = BeamState.WARN
## 当前状态已持续的时间
var t : float = 0.0
var hit_box : HitBox


## 在 parent 下生成一道光束
static func spawn( parent : Node, is_horizontal : bool, pos : float ) -> BossBeam:
	var b := BossBeam.new()
	b.horizontal = is_horizontal
	b.line_pos = pos
	b.add_to_group( "boss_fx" )
	b.z_index = 6
	parent.add_child( b )
	b.global_position = Vector2.ZERO
	return b


func is_firing() -> bool:
	return state == BeamState.FIRE


func _process( delta : float ) -> void:
	t += delta
	match state:
		BeamState.WARN:
			if t >= WARN_TIME:
				_begin_fire()
		BeamState.FIRE:
			if t >= FIRE_TIME:
				state = BeamState.DONE
				queue_free()
				return
	queue_redraw()


func _begin_fire() -> void:
	state = BeamState.FIRE
	t = 0.0
	hit_box = BeamHitBox.new()
	hit_box.damage = 1
	hit_box.collision_layer = 0
	hit_box.collision_mask = PLAYER_HURT_LAYER
	hit_box.monitorable = false
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	if horizontal:
		rect.size = Vector2( SPAN_MAX.x - SPAN_MIN.x, WIDTH )
		shape.position = Vector2( ( SPAN_MAX.x + SPAN_MIN.x ) * 0.5, line_pos )
	else:
		rect.size = Vector2( WIDTH, SPAN_MAX.y - SPAN_MIN.y )
		shape.position = Vector2( line_pos, ( SPAN_MAX.y + SPAN_MIN.y ) * 0.5 )
	shape.shape = rect
	hit_box.add_child( shape )
	add_child( hit_box )
	var audio := AudioStreamPlayer.new()
	audio.stream = SOUND
	audio.volume_db = -4.0
	audio.bus = &"SFX"
	add_child( audio )
	audio.play()


func _band() -> Rect2:
	if horizontal:
		return Rect2( SPAN_MIN.x, line_pos - WIDTH * 0.5, SPAN_MAX.x - SPAN_MIN.x, WIDTH )
	return Rect2( line_pos - WIDTH * 0.5, SPAN_MIN.y, WIDTH, SPAN_MAX.y - SPAN_MIN.y )


func _draw() -> void:
	var band := _band()
	if state == BeamState.WARN:
		var k := t / WARN_TIME
		# 越接近发射闪得越快
		var blink := 0.5 + 0.5 * sin( t * ( 10.0 + 22.0 * k ) )
		draw_rect( band, Color( 1.0, 0.2, 0.3, 0.1 + 0.12 * blink + 0.08 * k ) )
		_dashed_edges( band, Color( 1.0, 0.35, 0.35, 0.55 + 0.4 * blink ) )
		# 中心细线
		if horizontal:
			draw_line( Vector2( band.position.x, line_pos ), Vector2( band.end.x, line_pos ), Color( 1.0, 0.6, 0.6, 0.35 ), 1.0 )
		else:
			draw_line( Vector2( line_pos, band.position.y ), Vector2( line_pos, band.end.y ), Color( 1.0, 0.6, 0.6, 0.35 ), 1.0 )
	elif state == BeamState.FIRE:
		var fade := clampf( ( FIRE_TIME - t ) / 0.15, 0.0, 1.0 )
		var jitter := 1.0 + 0.08 * sin( t * 90.0 )
		var col := Color( 1, 1, 1, fade )
		var span := band.size.x if horizontal else band.size.y
		var n := int( ceil( span / 32.0 ) )
		for i in n:
			if horizontal:
				var r := Rect2( band.position.x + i * 32.0, line_pos - WIDTH * 0.5 * jitter, 32.0, WIDTH * jitter )
				draw_texture_rect_region( TEXTURE, r, Rect2( 0, 0, 32, 16 ), col )
			else:
				var r := Rect2( line_pos - WIDTH * 0.5 * jitter, band.position.y + i * 32.0, WIDTH * jitter, 32.0 )
				draw_texture_rect_region( TEXTURE, r, Rect2( 0, 0, 32, 16 ), col, true )
		# 白色高亮芯
		if horizontal:
			draw_line( Vector2( band.position.x, line_pos ), Vector2( band.end.x, line_pos ), Color( 1, 0.9, 1, 0.8 * fade ), 3.0 )
		else:
			draw_line( Vector2( line_pos, band.position.y ), Vector2( line_pos, band.end.y ), Color( 1, 0.9, 1, 0.8 * fade ), 3.0 )


## 预警带的两条虚线边
func _dashed_edges( band : Rect2, col : Color ) -> void:
	var dash := 8.0
	if horizontal:
		var x := band.position.x
		while x < band.end.x:
			draw_line( Vector2( x, band.position.y ), Vector2( x + dash, band.position.y ), col, 1.0 )
			draw_line( Vector2( x, band.end.y ), Vector2( x + dash, band.end.y ), col, 1.0 )
			x += dash * 2.0
	else:
		var y := band.position.y
		while y < band.end.y:
			draw_line( Vector2( band.position.x, y ), Vector2( band.position.x, y + dash ), col, 1.0 )
			draw_line( Vector2( band.end.x, y ), Vector2( band.end.x, y + dash ), col, 1.0 )
			y += dash * 2.0


## 光束的判定：伤到主角一次后就关闭
class BeamHitBox extends HitBox:
	func _on_area_entered( a : Area2D ) -> void:
		super._on_area_entered( a )
		if a is HurtBox:
			set_deferred( "monitoring", false )
