class_name GuardController extends Node
## 站桩主角的操控：手势 / 方向键 -> 转向 + 出剑；被击退后拉回房间中心

## 房间中心（16x9 格、每格 32 像素）
const CENTER := Vector2( 256, 144 )
const RECENTER_RATE : float = 12.0

## 为 false 时不响应转向和出招（例如结算面板显示期间）
var enabled : bool = true

var _player : Player


func _ready() -> void:
	_player = PlayerManager.player
	GestureInput.direction_triggered.connect( _on_direction_triggered )


func _process( delta : float ) -> void:
	# 只在空闲状态拉回：受击 / 出招期间保留击退的位移
	if _player.is_dead or not _player.state_machine.current_state is State_Idle:
		return
	_player.global_position = _player.global_position.lerp( CENTER, 1.0 - exp( -RECENTER_RATE * delta ) )
	if _player.global_position.distance_to( CENTER ) < 0.5:
		_player.global_position = CENTER


## 键盘兜底：方向键转向并出剑一次
func _unhandled_input( event : InputEvent ) -> void:
	if not _can_act() or event.is_echo():
		return
	for action in [ "up", "down", "left", "right" ]:
		if event.is_action_pressed( action ):
			_player.face( _action_vector( action ) )
			# 蓄力 / 出招中只转向：这时注入 attack 松开会打断蓄力
			if _player.state_machine.current_state is State_Idle:
				_swing()
			return


func _on_direction_triggered( dir : Vector2 ) -> void:
	# 出剑的 attack 脉冲由 GestureInput 自己注入，这里只转向
	if _can_act():
		_player.face( dir )


func _can_act() -> bool:
	return enabled and not get_tree().paused and not _player.is_dead


func _action_vector( action : String ) -> Vector2:
	match action:
		"up": return Vector2.UP
		"down": return Vector2.DOWN
		"left": return Vector2.LEFT
		_: return Vector2.RIGHT


## 注入 attack 按下，下一帧松开：状态机里就是一次普通攻击
func _swing() -> void:
	_send_attack( true )
	await get_tree().process_frame
	_send_attack( false )


func _send_attack( pressed : bool ) -> void:
	var ev := InputEventAction.new()
	ev.action = "attack"
	ev.pressed = pressed
	Input.parse_input_event( ev )
