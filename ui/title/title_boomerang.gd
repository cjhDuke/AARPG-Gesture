class_name TitleBoomerang extends Node2D
## 标题用的回旋镖精灵（player/sprites/boomerang.png，8 帧旋转）。
## orbit = true：沿椭圆绕标题飞行并带拖尾（拖尾风格抄 boomerang.gd）；
## orbit = false：原地旋转，用作按钮的选择标记。

const TEXTURE: Texture2D = preload("res://player/sprites/boomerang.png")
const TRAIL_MAX_POINTS := 16

@export var orbit: bool = false
## 椭圆中心和半径（屏幕坐标）
@export var center: Vector2 = Vector2( 240, 80 )
@export var radius: Vector2 = Vector2( 172, 46 )
## 角速度（弧度/秒）
@export var angular_speed: float = 2.3
## 旋转动画帧率
@export var spin_fps: float = 26.0

var _sprite: Sprite2D
var _trail: Line2D
var _angle: float = PI * 1.5
var _time: float = 0.0


func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.texture = TEXTURE
	_sprite.hframes = 8
	add_child( _sprite )
	if orbit:
		_make_trail()
		_place()


func _process( delta: float ) -> void:
	_time += delta
	_sprite.frame = int( _time * spin_fps ) % 8
	if orbit:
		_angle += angular_speed * delta
		_place()
		_trail.add_point( global_position )
		while _trail.get_point_count() > TRAIL_MAX_POINTS:
			_trail.remove_point( 0 )


func _place() -> void:
	position = center + Vector2( cos( _angle ) * radius.x, sin( _angle ) * radius.y ).round()


func _make_trail() -> void:
	_trail = Line2D.new()
	_trail.top_level = true
	_trail.width = 3.0
	_trail.default_color = Color( 0.4, 0.9, 1.0, 0.9 )
	var g := Gradient.new()
	g.colors = PackedColorArray( [ Color( 0.4, 0.9, 1.0, 0.0 ), Color( 0.7, 1.0, 1.0, 0.9 ) ] )
	g.offsets = PackedFloat32Array( [ 0.0, 1.0 ] )
	_trail.gradient = g
	add_child( _trail )
	_trail.global_position = Vector2.ZERO
	# 拖尾画在精灵下面
	_trail.show_behind_parent = true
