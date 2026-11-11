class_name HandController extends Node
## 手引生存的操控：手的位置映射成光标，主角追着光标走并自动挥剑；
## 握拳时主角站定，用念力操控回旋镖追光标；张开时回旋镖飞回。
## 没有识别端（或手不在画面里）时用键盘：WASD 走位，按住 L（ability）操控回旋镖。

## 房间中心（16x9 格、每格 32 像素）
const CENTER := Vector2( 256, 144 )
## 主角（脚底原点）可走范围。房间地板是 (0,0)-(512,288)，镜头固定在 CENTER、
## 视野 480x270，所以可见地板是 x 16..496、y 9..279；左右各留 12 像素，上方留出头部（精灵约 37 像素高），
## 下方留出底部状态行和念力条。矩形以 CENTER 为中心，手在操作框正中时主角就在房间正中。
## 主角碰撞圆半径 10，墙在地板边缘，所以这个范围不会撞墙。
const ARENA_RECT := Rect2( 28, 44, 456, 200 )

## 手的活动区域（操作框归一化 0-1）映射到光标可达矩形 CURSOR_RECT。
## 以下数字按默认操作框 right（250x420 摄像头像素）推出：
## 横向 0.05-0.95 = 225 像素 -> 338 游戏像素（增益约 1.5，操作框宽度已用满，再降就够不到两侧）；
## 纵向 0.25-0.75 = 210 像素 -> 200 游戏像素（增益约 0.95）。
## 换了操作框尺寸（预设 right-wide 等）要重算。协议里没有操作框的像素尺寸，所以用归一化常量。
const HAND_X_MIN : float = 0.05
const HAND_X_MAX : float = 0.95
const HAND_Y_MIN : float = 0.25
const HAND_Y_MAX : float = 0.75
## 光标可达矩形：纵向铺满 ARENA_RECT，横向在 ARENA_RECT 内居中（两侧各约 59 像素够不到）
const CURSOR_RECT := Rect2( 87, 44, 338, 200 )
## 手势模式下光标每秒最多移动的像素数
const CURSOR_MAX_SPEED : float = 240.0
## 光标朝手的位置做指数平滑的时间常数（秒），越大越"肉"
const CURSOR_SMOOTH_TIME : float = 0.12
## 手势模式主角走速 = clamp( 离光标距离 * WALK_SPEED_GAIN, WALK_SPEED_MIN, WALK_SPEED_MAX )
const WALK_SPEED_GAIN : float = 5.0
const WALK_SPEED_MIN : float = 40.0
const WALK_SPEED_MAX : float = 130.0
## 头顶念力条的最小 y（世界坐标），保证不超出镜头上沿
const PSI_BAR_MIN_Y : float = 12.0
## 离光标多远开始走 / 停下（滞回）
const WALK_START_DIST : float = 10.0
const WALK_STOP_DIST : float = 4.0
## 手丢失后保持原状态的宽限（秒）
const HAND_GRACE : float = 0.3

## 自动挥剑：敌人（原点）到主角（原点）的距离小于它就挥剑。
## 依据：AttackHitBox 圆半径 20、敌人受击圆在其原点上方 7 像素；
## 无界面实测上下左右四个方向、敌人静止在 20 / 30 / 35 像素处，都能被命中（距离 >35 未测）。
const ATTACK_RANGE : float = 36.0
const ATTACK_COOLDOWN : float = 0.45

## 念力
const PSI_START_MIN : float = 0.3
const PSI_DRAIN : float = 1.0 / 3.0
const PSI_REGEN : float = 1.0 / 4.0
## 起飞后这段时间内目标点固定在主角朝向前方，不追光标（握拳瞬间掌心会跳）
const LAUNCH_FIXED_TIME : float = 0.15
const LAUNCH_FIXED_DIST : float = 70.0
## 键盘模式：目标点 = 回旋镖当前位置 + 方向键方向 * KEY_STEP
const KEY_STEP : float = 80.0

## 为 false 时不响应任何操作（例如结算面板显示期间）
var enabled : bool = true :
	set( v ):
		enabled = v
		if not enabled:
			_shutdown_control()

## 念力 0-1
var psi : float = 1.0
## 正在操控回旋镖
var guided : bool = false

var _player : Player
var _abilities : PlayerAbilities
var _cursor : HandCursor
var _psi_bar : PsiBar
var _boomerang : Boomerang
var _hud : SurvivalHud
var _hand_lost_time : float = 0.0
var _cursor_pos : Vector2 = CENTER
var _walking : bool = false
var _attack_cd : float = 0.0
var _prev_fist : bool = false
var _guided_by_hand : bool = false
var _guided_time : float = 0.0
## 上一帧是否在手势模式且有手（用来判断光标是否要直接跳到目标点）
var _had_hand : bool = false


func _ready() -> void:
	_player = PlayerManager.player
	_abilities = _player.get_node( "Abilities" )
	_hud = get_parent().get_node_or_null( "SurvivalHud" )
	_cursor = HandCursor.new()
	# 父节点还在 _ready 里搭子节点，延后再挂光标
	get_parent().add_child.call_deferred( _cursor )
	_psi_bar = PsiBar.new()
	get_parent().add_child.call_deferred( _psi_bar )


## 每局开始：念力回满，结束操控
func reset() -> void:
	_shutdown_control()
	psi = 1.0
	_attack_cd = 0.0
	_prev_fist = false
	_update_hud()


## 关卡卸载时复原主角状态
func release_player() -> void:
	_shutdown_control()


func _process( delta : float ) -> void:
	if get_tree().paused or not enabled:
		return

	var hand_mode := _update_hand_state( delta )
	_attack_cd = maxf( _attack_cd - delta, 0.0 )

	if _player.is_dead:
		_end_guided()
		_player.use_move_override = false
		_player.move_speed_override = 0.0
		if is_instance_valid( _cursor ):
			_cursor.visible = false
		if is_instance_valid( _psi_bar ):
			_psi_bar.hide_now()
		return

	# 回旋镖被外部销毁时，操控也结束
	if guided and not _abilities.has_boomerang():
		_end_guided()

	var fist := hand_mode and GestureInput.is_fist and GestureInput.hand_present
	var hand_now := hand_mode and GestureInput.hand_present
	if hand_now:
		var goal := _hand_to_arena( GestureInput.hand_pos )
		# 手刚出现的第一帧直接跳过去，之后先平滑再限速
		if _had_hand:
			var smoothed := _cursor_pos.lerp( goal, 1.0 - exp( -delta / CURSOR_SMOOTH_TIME ) )
			_cursor_pos = _cursor_pos.move_toward( smoothed, CURSOR_MAX_SPEED * delta )
		else:
			_cursor_pos = goal
	_had_hand = hand_now

	# 开始 / 结束操控
	if not guided:
		var want_start := false
		if hand_mode:
			want_start = fist and not _prev_fist
		else:
			want_start = Input.is_action_just_pressed( "ability" )
		if want_start and not _abilities.has_boomerang():
			if psi >= PSI_START_MIN:
				_start_guided( hand_mode )
			else:
				_psi_low_feedback()
	else:
		var stop := false
		if _guided_by_hand:
			# 手张开（有手但不是拳），或手丢失超过宽限 / 断连（hand_mode 变假）
			stop = not hand_mode or (GestureInput.hand_present and not GestureInput.is_fist)
		else:
			stop = hand_mode or not Input.is_action_pressed( "ability" )
		if stop:
			_end_guided()
	_prev_fist = fist

	# 念力：操控中消耗，否则恢复
	if guided:
		psi = maxf( psi - PSI_DRAIN * delta, 0.0 )
		if psi <= 0.0:
			_end_guided()
	else:
		psi = minf( psi + PSI_REGEN * delta, 1.0 )

	if guided:
		_update_guided( delta, hand_mode )
	_update_walk( hand_mode )
	_update_cursor( hand_mode )
	_update_auto_attack()
	_update_hud()


## 更新手丢失计时，返回当前是否用手势操控
func _update_hand_state( delta : float ) -> bool:
	if GestureInput.hand_present:
		_hand_lost_time = 0.0
	else:
		_hand_lost_time += delta
	return GestureInput.connected and GestureInput.calibrated \
		and (GestureInput.hand_present or _hand_lost_time < HAND_GRACE)


# ---------- 走位 ----------

func _update_walk( hand_mode : bool ) -> void:
	if not hand_mode:
		_player.use_move_override = false
		_player.move_speed_override = 0.0
		_walking = false
		return
	_player.use_move_override = true
	if guided:
		_player.move_override = Vector2.ZERO
		_player.move_speed_override = 0.0
		_walking = false
		return
	var to_cursor := _cursor_pos - _player.global_position
	var d := to_cursor.length()
	if _walking:
		_walking = d >= WALK_STOP_DIST
	else:
		_walking = d > WALK_START_DIST
	_player.move_override = to_cursor / d if _walking and d > 0.001 else Vector2.ZERO
	_player.move_speed_override = clampf( d * WALK_SPEED_GAIN, WALK_SPEED_MIN, WALK_SPEED_MAX ) if _walking else 0.0


## 操作框归一化坐标 -> 房间里的光标目标点（手活动区域线性映射到 CURSOR_RECT 并钳制）
func _hand_to_arena( p : Vector2 ) -> Vector2:
	var u := clampf( (p.x - HAND_X_MIN) / (HAND_X_MAX - HAND_X_MIN), 0.0, 1.0 )
	var v := clampf( (p.y - HAND_Y_MIN) / (HAND_Y_MAX - HAND_Y_MIN), 0.0, 1.0 )
	return CURSOR_RECT.position + Vector2( u, v ) * CURSOR_RECT.size


# ---------- 回旋镖 ----------

func _start_guided( by_hand : bool ) -> void:
	var b := _abilities.start_guided( _player.cardinal_direction )
	if b == null:
		return
	_boomerang = b
	guided = true
	_guided_by_hand = by_hand
	_guided_time = 0.0
	_player.can_move = false
	_player.move_override = Vector2.ZERO


func _end_guided() -> void:
	if not guided:
		return
	guided = false
	_boomerang = null
	_abilities.release_guided()
	_player.can_move = true


func _update_guided( delta : float, hand_mode : bool ) -> void:
	_guided_time += delta
	if not is_instance_valid( _boomerang ):
		return
	var sprite_off := Boomerang.SPRITE_OFFSET
	var target : Vector2
	if _guided_time < LAUNCH_FIXED_TIME:
		target = _player.global_position + _player.cardinal_direction * LAUNCH_FIXED_DIST
	elif hand_mode:
		# 让回旋镖的精灵对准光标：节点原点 = 光标 - 精灵偏移
		target = _cursor_pos - sprite_off
	else:
		var key_dir := Vector2(
			Input.get_axis( "left", "right" ),
			Input.get_axis( "up", "down" )
		).normalized()
		var p := _boomerang.global_position + sprite_off + key_dir * KEY_STEP
		p = Vector2(
			clampf( p.x, ARENA_RECT.position.x, ARENA_RECT.end.x ),
			clampf( p.y, ARENA_RECT.position.y, ARENA_RECT.end.y ) )
		_cursor_pos = p
		target = p - sprite_off
	_boomerang.set_target( target )


# ---------- 光标 ----------

func _update_cursor( hand_mode : bool ) -> void:
	if not is_instance_valid( _cursor ) or not _cursor.is_inside_tree():
		return
	# 手势模式一直显示；键盘模式只在操控回旋镖时显示
	_cursor.visible = hand_mode or guided
	_cursor.fist = guided if not hand_mode else (GestureInput.is_fist and GestureInput.hand_present)
	_cursor.global_position = _cursor_pos


# ---------- 自动挥剑 ----------

func _update_auto_attack() -> void:
	if _attack_cd > 0.0:
		return
	var state := _player.state_machine.current_state
	if not (state is State_Idle or state is State_Walk):
		return
	var target := _nearest_enemy()
	if target == null:
		return
	var to_enemy := target.global_position - _player.global_position
	if to_enemy.length() >= ATTACK_RANGE:
		return
	_attack_cd = ATTACK_COOLDOWN
	var dir := _cardinal( to_enemy )
	_player.face( dir )
	_swing( dir )


## 最近的、已经淡入完成且活着的敌人
func _nearest_enemy() -> Enemy:
	var best : Enemy = null
	var best_d := INF
	for c in get_parent().get_children():
		if c is Enemy and not c.spawning and c.hp > 0 and not c.is_queued_for_deletion():
			var d : float = c.global_position.distance_to( _player.global_position )
			if d < best_d:
				best_d = d
				best = c
	return best


func _cardinal( v : Vector2 ) -> Vector2:
	if absf( v.x ) > absf( v.y ):
		return Vector2.RIGHT if v.x > 0.0 else Vector2.LEFT
	return Vector2.DOWN if v.y > 0.0 else Vector2.UP


## 注入 attack 按下，下一帧松开：状态机里就是一次普通攻击
func _swing( dir : Vector2 ) -> void:
	_send_attack( true )
	await get_tree().process_frame
	# 走路时蓄力状态可能把朝向改回走路方向，松开前再校正一次
	_player.face( dir )
	_send_attack( false )


func _send_attack( pressed : bool ) -> void:
	var ev := InputEventAction.new()
	ev.action = "attack"
	ev.pressed = pressed
	Input.parse_input_event( ev )


# ---------- 收尾 ----------

func _shutdown_control() -> void:
	if not is_instance_valid( _player ):
		return
	_end_guided()
	_player.can_move = true
	_player.use_move_override = false
	_player.move_override = Vector2.ZERO
	_player.move_speed_override = 0.0
	_walking = false
	_had_hand = false
	if is_instance_valid( _cursor ):
		_cursor.visible = false
	if is_instance_valid( _psi_bar ):
		_psi_bar.hide_now()


## 头顶念力条：操控中或还没回满时显示
func _update_hud() -> void:
	if is_instance_valid( _psi_bar ) and _psi_bar.is_inside_tree():
		var bar_pos := _player.global_position + PsiBar.OFFSET
		# 镜头可见范围的上沿是 y=9：主角贴着上墙时别让念力条跑出画面
		bar_pos.y = maxf( bar_pos.y, PSI_BAR_MIN_Y )
		_psi_bar.global_position = bar_pos
		_psi_bar.update_state( psi, guided or psi < 1.0 )


## 念力不足起飞失败：念力条闪烁，提示框显示 PSI LOW
func _psi_low_feedback() -> void:
	if is_instance_valid( _psi_bar ):
		_psi_bar.flash()
	GestureInput.flash_toast( "PSI LOW", 1.0 )
