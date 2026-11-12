class_name Enemy extends CharacterBody2D

signal direction_changed( new_direction : Vector2)
signal enemy_damaged( hit_box : HitBox )
signal enemy_destroyed( hit_box : HitBox )

## 高台碰撞层（project.godot 里命名为 Ledge）
const LEDGE_LAYER : int = 32
const DIR_4 = [ Vector2.RIGHT , Vector2.DOWN , Vector2.LEFT , Vector2.UP ]

@export var hp : int = 3
## 生成时的淡入时长；淡入期间无敌、不造成伤害
@export var fade_in_time : float = 0.4
## 被消灭时掉苹果的概率（LootDropper 读取；另有保底）
@export var apple_drop_chance : float = 0.08

var cardinal_direction : Vector2 = Vector2.DOWN
var direction : Vector2 = Vector2.ZERO
var player : Player
var invulnerable : bool = false
## 正处于受击硬直（EnemyStateStun 置位）；用来区分硬直无敌和淡入 / 死亡无敌
var stunned : bool = false
## 移动速度倍率（冰霜减速时为 0.5）；在 _physics_process 里对所有怪统一生效
var speed_scale : float = 1.0
var _is_defeated : bool = false
var _slow_left : float = 0.0
var _slow_base_tint : Color = Color.WHITE
## 正在淡入生成中，状态脚本据此暂缓开启攻击判定
var spawning : bool = false

@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var sprite_2d: Sprite2D = $Sprite2D
@onready var state_machine : EnemyStateMachine = $EnemyStateMachine
@onready var hurt_box: HurtBox = $HurtBox
@onready var hit_box: HitBox = $HitBox



# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# 高台（Ledge 层）挡敌人；地牢里没有这一层的物体，不影响
	collision_mask |= LEDGE_LAYER
	state_machine.initialize( self )
	player = PlayerManager.player 
	hurt_box.Damaged.connect( _take_damage )
	if fade_in_time > 0.0:
		_fade_in()


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta):
	pass
	

func _physics_process(_delta):
	if _is_defeated:
		return
	_update_slow( _delta )
	if speed_scale != 1.0:
		# 只缩放这一步的位移，状态脚本里累加的速度（硬直减速等）保持原值
		var v := velocity
		velocity = v * speed_scale
		move_and_slide()
		velocity = v
	else:
		move_and_slide()


func set_direction( _new_direction : Vector2 ) -> bool:
	direction = _new_direction
	if direction == Vector2.ZERO:
		return false
	
	var direction_id : int = int ( 
		round( direction + cardinal_direction * 0.1 ).angle() / TAU * DIR_4.size() ) 
	
	var new_dir = DIR_4[ direction_id ]
	
	if new_dir == cardinal_direction:
		return false
		
	cardinal_direction = new_dir
	direction_changed.emit( new_dir )
	sprite_2d.scale.x = -1 if cardinal_direction == Vector2.LEFT else 1
	return true
	
	
func update_animation( state : String ) -> void:
	animation_player.play(state + "_" + anim_direction())
	pass
	
func anim_direction() -> String:
	if cardinal_direction == Vector2.DOWN:
		return "down"
	elif cardinal_direction == Vector2.UP:
		return "up"
	else:
		return "side"


func _take_damage( hit_box : HitBox ) ->void:
	if invulnerable == true and not ( stunned and hit_box.ignores_stun_invulnerability ):
		return
	if can_block( hit_box ):
		on_blocked( hit_box )
		return
	var src := hit_box.get_parent()
	if src is Boomerang and src.frost:
		apply_slow( src.frost_time, src.frost_factor )
	hp -= hit_box.damage
	if hp > 0:
		enemy_damaged.emit( hit_box )
	else:
		enemy_destroyed.emit( hit_box )


## 减速 seconds 秒（倍率 factor），期间染成浅蓝；重复施加只刷新时间
func apply_slow( seconds : float, factor : float = 0.5 ) -> void:
	if _is_defeated:
		return
	if _slow_left <= 0.0:
		_slow_base_tint = sprite_2d.self_modulate
		sprite_2d.self_modulate = _slow_base_tint * Color( 0.65, 0.85, 1.3 )
	speed_scale = factor
	_slow_left = maxf( _slow_left, seconds )


func _update_slow( delta : float ) -> void:
	if _slow_left <= 0.0:
		return
	_slow_left -= delta
	if _slow_left <= 0.0:
		_slow_left = 0.0
		speed_scale = 1.0
		sprite_2d.self_modulate = _slow_base_tint


## 这次伤害能否被挡住（盾牌哥布林重写）；挡住则不掉血、不进硬直
func can_block( _hit_box : HitBox ) -> bool:
	return false


## 挡住后的表现（盾牌哥布林重写）
func on_blocked( _hit_box : HitBox ) -> void:
	pass


## 被消灭、且已计入波次存活数之后，由 WaveSpawner 调用（先于 enemy_destroyed_at 发出，
## 所以在这里 spawner.spawn_extra() 生成的怪赶得上清波判定）。大史莱姆在这里分裂
func on_defeated( _spawner : Node ) -> void:
	pass


func mark_defeated() -> void:
	_is_defeated = true


func _fade_in() -> void:
	spawning = true
	invulnerable = true
	hit_box.monitoring = false
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property( self, "modulate:a", 1.0, fade_in_time )
	await tween.finished
	spawning = false
	invulnerable = false
	hit_box.monitoring = true
