class_name EnemyProjectile extends HitBox
## 可被玩家打掉的敌方投射物基类（箭；之后的火球也用它）。
## - 本身是 HitBox，直线飞行，命中主角受击框后造成 damage 并消失
## - 带一个敌人受击层的 HurtBox：回旋镖 / 念力爆破的 HitBox 碰到它就销毁（destroy_by_player）
## - 碰墙、飞出场地、超过 max_lifetime 都会消失
## - 加入节点组 enemy_projectile，WaveSpawner.clear() / 清波时统一清掉
## 阶段 D 的"弹反"强化：把 parry_by_spin 设为 true，旋转斩的判定也能打掉它。

const PLAYER_HURT_LAYER : int = 2
const ENEMY_HURT_LAYER : int = 256
const WALL_LAYER : int = 16
## 飞出 ARENA_RECT 这么远就消失（像素）
const OUT_MARGIN : float = 24.0
const BREAK_SOUND : AudioStream = preload( "res://enemies/shield_goblin/clang.wav" )

## 弹反：旋转斩的判定（挂在主角身上）是否也能打掉投射物。镖和念力爆破始终可以
static var parry_by_spin : bool = false

@export var speed : float = 120.0
@export var max_lifetime : float = 4.0
## 碰撞圆半径（同时用于命中主角和被镖打掉）
@export var hit_radius : float = 4.0

var direction : Vector2 = Vector2.RIGHT
var _age : float = 0.0
var _gone : bool = false
var _hurt : HurtBox


## 在 world_pos 发射一个 scene 实例，朝 dir 飞
static func fire( scene_script : GDScript, parent : Node, world_pos : Vector2, dir : Vector2 ) -> EnemyProjectile:
	var p : EnemyProjectile = scene_script.new()
	p.direction = dir.normalized()
	p.add_to_group( "enemy_projectile" )
	p.z_index = 2
	parent.add_child( p )
	p.global_position = world_pos
	return p


func _ready() -> void:
	damage = 1
	collision_layer = 0
	collision_mask = PLAYER_HURT_LAYER
	monitorable = false
	super._ready()
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = hit_radius
	shape.shape = circle
	add_child( shape )
	# 让玩家的攻击能打到：敌人受击层上的 HurtBox，不主动检测
	_hurt = HurtBox.new()
	_hurt.collision_layer = ENEMY_HURT_LAYER
	_hurt.collision_mask = 0
	_hurt.monitoring = false
	var hshape := CollisionShape2D.new()
	hshape.shape = circle
	_hurt.add_child( hshape )
	add_child( _hurt )
	_hurt.Damaged.connect( _on_hurt )
	rotation = direction.angle()
	_build_visual()


## 子类重写：创建外观（节点已按飞行方向旋转，+x 方向是前方）
func _build_visual() -> void:
	pass


func _physics_process( delta : float ) -> void:
	if _gone:
		return
	_age += delta
	var from := global_position
	var to := from + direction * speed * delta
	if _age >= max_lifetime or not HandController.ARENA_RECT.grow( OUT_MARGIN ).has_point( to ) or _hits_wall( from, to ):
		_gone = true
		queue_free()
		return
	global_position = to


func _hits_wall( from : Vector2, to : Vector2 ) -> bool:
	var q := PhysicsRayQueryParameters2D.create( from, to, WALL_LAYER )
	return not get_world_2d().direct_space_state.intersect_ray( q ).is_empty()


## 命中主角：造成伤害后消失（HitBox 的基类逻辑负责伤害）
func _on_area_entered( a : Area2D ) -> void:
	if _gone:
		return
	super._on_area_entered( a )
	if a is HurtBox:
		_gone = true
		queue_free()


func _on_hurt( hit_box : HitBox ) -> void:
	var src := hit_box.get_parent()
	if src is Boomerang or src is PsiBlast or ( parry_by_spin and src is Player ) or ( parry_by_spin and src.get_parent() is Player ):
		destroy_by_player()


## 被玩家的攻击打掉：小特效 + 音效，然后消失（不伤主角）
func destroy_by_player() -> void:
	if _gone:
		return
	_gone = true
	_spawn_pop()
	queue_free()


func _spawn_pop() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var fx := ProjectilePop.new()
	fx.add_to_group( "loot_fx" )
	fx.z_index = 5
	parent.add_child( fx )
	fx.global_position = global_position
	var audio := AudioStreamPlayer.new()
	audio.stream = BREAK_SOUND
	audio.volume_db = -8.0
	audio.pitch_scale = 1.6
	audio.bus = &"SFX"
	fx.add_child( audio )
	audio.play()


## 投射物被打掉时的小火花：几条向外扩散的短线，0.2 秒后自行释放
class ProjectilePop extends Node2D:
	var _t : float = 0.0

	func _process( delta : float ) -> void:
		_t += delta
		if _t >= 0.25:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var k := _t / 0.2
		var a := clampf( 1.0 - k, 0.0, 1.0 )
		for i in 6:
			var d := Vector2.from_angle( i * TAU / 6.0 + 0.3 )
			draw_line( d * ( 2.0 + 6.0 * k ), d * ( 5.0 + 9.0 * k ), Color( 1.0, 0.9, 0.5, a ), 1.0 )
