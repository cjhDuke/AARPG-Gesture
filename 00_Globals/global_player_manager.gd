extends Node
## 全局唯一的主角实例：跨关卡保留，关卡加载时由关卡接管 / 交还

const PLAYER = preload("uid://b4sse476kdci4")

var player : Player


func _ready() -> void:
	add_player_instance()


func add_player_instance() -> void:
	player = PLAYER.instantiate()
	add_child( player )


## 满血、清零速度、回到初始状态，用于重新开始一局
func reset_player() -> void:
	player.hp = player.max_hp
	player.velocity = Vector2.ZERO
	player.direction = Vector2.ZERO
	player.invulnerable = false
	player.is_dead = false
	player.hurt_box.monitoring = true
	player.state_machine.reset_to_initial_state()
	player.face( Vector2.DOWN )
	player.update_hp( 0 )
	player.update_animation( "idle" )


func set_as_parent( _p : Node2D ) -> void:
	if player.get_parent():
		player.get_parent().remove_child( player )
	_p.add_child( player )


## 关卡卸载前把主角交还给自己，避免主角随关卡一起被释放
func unparent_player( _p : Node2D ) -> void:
	_p.remove_child( player )
	add_child( player )


func play_audio( _audio : AudioStream ) -> void:
	player.audio.stream = _audio
	player.audio.play()
