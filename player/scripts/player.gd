class_name Player extends CharacterBody2D

var cardinal_direction : Vector2 = Vector2.DOWN
const DIR_4 = [ Vector2.RIGHT , Vector2.DOWN , Vector2.LEFT , Vector2.UP ]
var direction : Vector2 = Vector2.ZERO
var invulnerable : bool = false
var hp : int = 6
var max_hp : int = 6
var is_dead : bool = false
## 为 false 时主角站桩：direction 恒为零，不会走动
var can_move : bool = true
## 为 true 时移动方向取 move_override（已归一化或零），不读键盘；由关卡控制器（手势）使用
var use_move_override := false
var move_override := Vector2.ZERO
## 大于 0 时 State_Walk 用它当走速（手势模式变速）；<=0 用状态自带的速度
var move_speed_override : float = 0.0

@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var sprite_2d: Sprite2D = $Sprite2D
@onready var state_machine: PlayerStateMachine = $StateMachine
@onready var hurt_box: HurtBox = $HurtBox
@onready var effect_animation_player: AnimationPlayer = $EffectAnimationPlayer
@onready var audio: AudioStreamPlayer2D = $Audio/AudioStreamPlayer2D


signal DirectionChanged( new_direction : Vector2 )
signal player_damaged( hit_box : HitBox )
## 血量归零时发出，由关卡决定后续流程
signal died

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	PlayerManager.player = self
	state_machine.initialize(self)
	hurt_box.Damaged.connect( _take_damage )
	update_hp(99)
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if is_dead or not can_move:
		direction = Vector2.ZERO
		return

	if use_move_override:
		direction = move_override
	else:
		direction = Vector2(
			Input.get_axis("left", "right"),
			Input.get_axis("up", "down")
		).normalized()
	
	pass
	
	
func _physics_process(delta: float) -> void:
	move_and_slide()
	
	
func set_direction() -> bool:
	
	if direction == Vector2.ZERO:
		return false
	
	var direction_id : int = int( round( ( direction + cardinal_direction * 0.1 ).angle() / TAU * DIR_4.size() ) )
	
	var new_dir = DIR_4[ direction_id ]
	
			
	if new_dir == cardinal_direction:
		return false
	
	cardinal_direction = new_dir
	DirectionChanged.emit( new_dir )
	sprite_2d.scale.x = -1 if cardinal_direction == Vector2.LEFT else 1 
	
	return true

	
## 直接设置四方向朝向（dir 为上下左右之一），空闲时刷新动画
func face( dir : Vector2 ) -> void:
	if not DIR_4.has( dir ):
		return
	cardinal_direction = dir
	DirectionChanged.emit( dir )
	sprite_2d.scale.x = -1 if dir == Vector2.LEFT else 1
	if state_machine.current_state is State_Idle:
		update_animation( "idle" )


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

func _take_damage( hit_box : HitBox ) -> void:
	if invulnerable == true or is_dead == true:
		return
	update_hp( -hit_box.damage )
	if hp > 0:
		player_damaged.emit( hit_box )
	else :
		die()
	pass
	
	
func update_hp( delta : int ) -> void:
	hp = clampi( hp + delta, 0, max_hp)
	PlayerHud.update_hp( hp, max_hp )
	pass

func die() -> void:
	is_dead = true
	direction = Vector2.ZERO
	velocity = Vector2.ZERO
	state_machine.reset_to_initial_state()
	hurt_box.monitoring = false
	died.emit()
	
func make_invulnerable( _duration : float = 1.0 ) -> void:
	invulnerable = true
	hurt_box.monitoring = false

	await get_tree().create_timer( _duration ).timeout

	invulnerable = false
	hurt_box.monitoring = true
	pass 
