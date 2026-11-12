class_name ArcherGoblin extends Enemy
## 弓手哥布林：绿色，不追主角。离主角近于 keep_distance 就后退，否则站定；
## 每 shoot_interval 秒射一箭：先 telegraph_time 秒预警（朝主角画一条细瞄准线并停步），
## 预警结束时锁定方向发射。生成淡入期间不射箭。行为在 EnemyStateArcher（场景里的 Approach 节点）里。
## stationary 为 true 时完全不动（阶段 C 放在高台上用），仍然会射箭。

const BOW_SOUND : AudioStream = preload( "res://enemies/archer_goblin/bow_fire.wav" )

## 离主角近于这个距离就后退（像素）
@export var keep_distance : float = 90.0
## 后退速度（像素/秒）
@export var move_speed : float = 30.0
## 射击间隔、预警时长（秒）
@export var shoot_interval : float = 2.5
@export var telegraph_time : float = 0.5
## 箭速（像素/秒）、箭伤害
@export var arrow_speed : float = 120.0
@export var arrow_damage : int = 1
## 完全不动（高台弓手）
@export var stationary : bool = false

## 正在预警：瞄准线朝 aim_dir 画
var aiming : bool = false
var aim_dir : Vector2 = Vector2.DOWN

var _marks : Node2D


func _ready() -> void:
	super._ready()
	_marks = Node2D.new()
	_marks.draw.connect( _draw_aim )
	add_child( _marks )


func _process( _delta : float ) -> void:
	_marks.visible = aiming and not _is_defeated
	if _marks.visible:
		_marks.queue_redraw()


## 弓手射击 / 瞄准的出发点（身体中心）
func muzzle() -> Vector2:
	return global_position + Vector2( 0, -7 )


## 主角身体中心（主角受击框在原点上方 14 像素）
func target_point() -> Vector2:
	return player.global_position + Vector2( 0, -14 )


## 朝 dir 射出一支箭
func shoot( dir : Vector2 ) -> void:
	var arrow := EnemyProjectile.fire( Arrow, get_parent(), muzzle() + dir * 14.0, dir )
	arrow.speed = arrow_speed
	arrow.damage = arrow_damage
	var audio : AudioStreamPlayer2D = $AudioStreamPlayer2D
	audio.stream = BOW_SOUND
	audio.play()


func _draw_aim() -> void:
	var from := to_local( muzzle() )
	var to := from + aim_dir * minf( global_position.distance_to( player.global_position ) + 20.0, 200.0 )
	_marks.draw_line( from, to, Color( 1.0, 0.25, 0.2, 0.75 ), 1.0 )
	_marks.draw_circle( to, 1.5, Color( 1.0, 0.45, 0.3, 0.9 ) )
