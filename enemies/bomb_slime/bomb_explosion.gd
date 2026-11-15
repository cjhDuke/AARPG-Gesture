class_name BombExplosion extends Node2D
## 炸弹史莱姆死后留下的"引信炸弹"：先闪烁膨胀 fuse_time 秒（外圈是爆炸范围预警），然后爆炸一次。
## 爆炸对主角伤害 player_damage，对范围内的敌人伤害 enemy_damage（无视受击硬直无敌，也无视盾牌；
## 炸到别的炸弹史莱姆会让它死亡并留下新的引信炸弹，形成连锁）。
## 动画和音效播完自行释放；加入 loot_fx 组，重开 / 切关时随 LootDropper.clear() 清掉。
## 伤害用物理形状查询一次结算，目标的受击框和圆有重叠就算命中（所以实际波及距离是半径加目标的受击框半径）。

const SHEET : Texture2D = preload( "res://enemies/bomb_slime/bomb.png" )
const SOUND : AudioStream = preload( "res://enemies/bomb_slime/bomb_explosion.wav" )
## 精灵表 384x384：3x3 格，每格 128x128。第 1 格是 4 列 x 3 行的 32x32 小炸弹，其余 8 格是爆炸帧
const CELL : int = 128
const BOMB_ICON := Rect2( 0, 0, 32, 32 )
const EXPLOSION_CELLS : Array[Vector2i] = [
	Vector2i( 1, 0 ), Vector2i( 2, 0 ), Vector2i( 0, 1 ), Vector2i( 1, 1 ),
	Vector2i( 2, 1 ), Vector2i( 0, 2 ), Vector2i( 1, 2 ), Vector2i( 2, 2 ),
]
## 爆炸帧里爆炸主体的直径约 100 像素，据此把精灵缩放到和范围一致
const BODY_DIAMETER : float = 100.0
const ANIM_TIME : float = 0.45
## 爆炸中心比节点原点高多少（身体中心）
const CENTER_OFFSET := Vector2( 0, -8 )
const PLAYER_HURT_LAYER : int = 2
const ENEMY_HURT_LAYER : int = 256

var radius : float = 40.0
var fuse_time : float = 0.5
var player_damage : int = 1
var enemy_damage : int = 2

var _age : float = 0.0
var _exploded : bool = false
var _icon : Sprite2D
var _blast : Sprite2D


## 在 world_pos（敌人原点）放一颗引信炸弹，加到 parent 下
static func arm( parent : Node, world_pos : Vector2, p_radius : float, p_fuse : float,
		p_player_damage : int, p_enemy_damage : int ) -> BombExplosion:
	var b := BombExplosion.new()
	b.radius = p_radius
	b.fuse_time = p_fuse
	b.player_damage = p_player_damage
	b.enemy_damage = p_enemy_damage
	b.add_to_group( "loot_fx" )
	# 和主角、敌人同一层才能按 y 排序（主角 z_index 是 2）
	b.z_index = 2
	parent.add_child( b )
	b.global_position = world_pos
	return b


func _ready() -> void:
	_icon = Sprite2D.new()
	_icon.texture = SHEET
	_icon.region_enabled = true
	_icon.region_rect = BOMB_ICON
	_icon.position = CENTER_OFFSET
	add_child( _icon )


func _process( delta : float ) -> void:
	if _exploded:
		return
	_age += delta
	if _age >= fuse_time:
		_explode()
		return
	# 越接近爆炸闪得越快、膨胀得越大
	var t := _age / fuse_time
	var s := 1.0 + 0.6 * t
	_icon.scale = Vector2( s, s )
	var flash := int( _age * ( 8.0 + 16.0 * t ) ) % 2 == 0
	_icon.modulate = Color( 1.6, 0.5, 0.4 ) if flash else Color( 2.0, 2.0, 2.0 )
	queue_redraw()


## 范围预警圈：随引信推进变实
func _draw() -> void:
	if _exploded:
		return
	var t := clampf( _age / fuse_time, 0.0, 1.0 )
	draw_circle( CENTER_OFFSET, radius, Color( 1.0, 0.2, 0.1, 0.10 + 0.15 * t ) )
	draw_arc( CENTER_OFFSET, radius, 0.0, TAU, 32, Color( 1.0, 0.3, 0.2, 0.5 + 0.4 * t ), 1.0 )


func _explode() -> void:
	_exploded = true
	_icon.queue_free()
	queue_redraw()
	_apply_damage()

	_blast = Sprite2D.new()
	_blast.texture = SHEET
	_blast.region_enabled = true
	_blast.position = CENTER_OFFSET
	var s := radius * 2.0 / BODY_DIAMETER
	_blast.scale = Vector2( s, s )
	add_child( _blast )
	_set_frame( 0 )

	var audio := AudioStreamPlayer.new()
	audio.stream = SOUND
	audio.bus = &"SFX"
	add_child( audio )
	audio.play()

	var tween := create_tween()
	tween.tween_method( _set_frame, 0.0, float( EXPLOSION_CELLS.size() ) - 0.01, ANIM_TIME )
	await tween.finished
	if audio.playing:
		await audio.finished
	queue_free()


func _set_frame( f : float ) -> void:
	var cell : Vector2i = EXPLOSION_CELLS[ clampi( int( f ), 0, EXPLOSION_CELLS.size() - 1 ) ]
	_blast.region_rect = Rect2( cell.x * CELL, cell.y * CELL, CELL, CELL )


## 一次性结算伤害：圆形查询主角和敌人的受击框
func _apply_damage() -> void:
	var center := global_position + CENTER_OFFSET
	var shape := CircleShape2D.new()
	shape.radius = radius
	var q := PhysicsShapeQueryParameters2D.new()
	q.shape = shape
	q.transform = Transform2D( 0.0, center )
	q.collision_mask = PLAYER_HURT_LAYER | ENEMY_HURT_LAYER
	q.collide_with_areas = true
	q.collide_with_bodies = false
	q.margin = 0.0
	var hits := get_world_2d().direct_space_state.intersect_shape( q, 64 )

	var on_player := _make_hit_box( player_damage, center )
	var on_enemy := _make_hit_box( enemy_damage, center )
	var done : Dictionary = {}
	for h : Dictionary in hits:
		var hurt := h["collider"] as HurtBox
		if hurt == null or done.has( hurt ):
			continue
		done[hurt] = true
		hurt.take_damage( on_player if ( hurt.collision_layer & PLAYER_HURT_LAYER ) != 0 else on_enemy )


## 不参与碰撞的伤害载体，只提供 damage / 位置（敌人据此决定击退方向）
func _make_hit_box( dmg : int, center : Vector2 ) -> HitBox:
	var hb := HitBox.new()
	hb.damage = dmg
	hb.ignores_stun_invulnerability = true
	hb.unblockable = true
	hb.collision_layer = 0
	hb.collision_mask = 0
	hb.monitoring = false
	hb.monitorable = false
	add_child( hb )
	hb.global_position = center
	return hb
