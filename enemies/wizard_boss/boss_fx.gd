class_name BossExplosion extends Node2D
## Boss 战的一次性爆炸特效：energy_explosion.png（8 帧 128x128）播完自行释放。
## 加入节点组 boss_fx，关卡清理 Boss 时统一释放。

const SHEET : Texture2D = preload( "res://enemies/wizard_boss/energy_explosion.png" )
const FRAMES : int = 8

var _sprite : Sprite2D


## 在 world_pos 放一次爆炸。k 是缩放（1 = 128 像素），time 是播放时长（秒）
static func spawn( parent : Node, world_pos : Vector2, k : float = 1.0, time : float = 0.5, tint : Color = Color.WHITE ) -> BossExplosion:
	var fx := BossExplosion.new()
	fx.add_to_group( "boss_fx" )
	fx.z_index = 6
	parent.add_child( fx )
	fx.global_position = world_pos
	fx._play( k, time, tint )
	return fx


func _play( k : float, time : float, tint : Color ) -> void:
	_sprite = Sprite2D.new()
	_sprite.texture = SHEET
	_sprite.hframes = FRAMES
	_sprite.scale = Vector2( k, k )
	_sprite.modulate = tint
	add_child( _sprite )
	var tween := create_tween()
	tween.tween_property( _sprite, "frame", FRAMES - 1, time ).from( 0 )
	tween.tween_callback( queue_free )


## 地面阴影：跟着 Boss 的 x，固定在地面高度；Boss 离地越高阴影越小越淡
class BossShadow extends Node2D:
	const GROUND_Y_OFFSET : float = 28.0
	var boss : Node2D
	var ground_y : float = 0.0

	func _ready() -> void:
		z_index = 1
		add_to_group( "boss_fx" )

	func _process( _delta : float ) -> void:
		if is_instance_valid( boss ):
			global_position = Vector2( boss.global_position.x, ground_y + GROUND_Y_OFFSET )
			visible = boss.visible
			queue_redraw()

	func _draw() -> void:
		if not is_instance_valid( boss ):
			return
		var h := clampf( ( ground_y - boss.global_position.y ) / 30.0, 0.0, 1.0 )
		var w := lerpf( 26.0, 20.0, h )
		var a := lerpf( 0.35, 0.2, h ) * boss.modulate.a
		draw_set_transform( Vector2.ZERO, 0.0, Vector2( 1.0, 0.35 ) )
		draw_circle( Vector2.ZERO, w, Color( 0, 0, 0, a ) )
