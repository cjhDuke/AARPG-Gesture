class_name Enemy extends CharacterBody2D

signal direction_changed( new_direction : Vector2)
signal enemy_damaged( hit_box : HitBox )
signal enemy_destroyed( hit_box : HitBox )

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
var _is_defeated : bool = false
## 正在淡入生成中，状态脚本据此暂缓开启攻击判定
var spawning : bool = false

@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var sprite_2d: Sprite2D = $Sprite2D
@onready var state_machine : EnemyStateMachine = $EnemyStateMachine
@onready var hurt_box: HurtBox = $HurtBox
@onready var hit_box: HitBox = $HitBox



# Called when the node enters the scene tree for the first time.
func _ready() -> void:
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
	if invulnerable == true:
		return
	hp -= hit_box.damage
	if hp > 0:
		enemy_damaged.emit( hit_box )
	else:
		enemy_destroyed.emit( hit_box )


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
