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

## 手的活动区域（掌心在操作框里的归一化坐标 0-1）映射到光标可达矩形 CURSOR_RECT。
## 关键约束：掌心不能要求贴到框边，否则半只手会出框（右边就是摄像头画面边缘）被裁掉，
## 张开 / 握拳会误判。用户录像里手宽约 150 摄像头像素，所以两侧各留约 0.22 的边距。
## 按默认操作框 right（270x480）推出：
## 横向 0.22-0.78 = 151 像素 -> 338 游戏像素（增益约 2.2，靠下面的平滑和限速压住手感）；
## 纵向 0.25-0.80 = 264 像素 -> 200 游戏像素（增益约 0.76）。
## 换了操作框尺寸要重算。协议里没有操作框的像素尺寸，所以用归一化常量。
const HAND_X_MIN : float = 0.22
const HAND_X_MAX : float = 0.78
const HAND_Y_MIN : float = 0.25
const HAND_Y_MAX : float = 0.80
## 光标可达矩形：纵向铺满 ARENA_RECT，横向在 ARENA_RECT 内居中（两侧各约 59 像素够不到）
const CURSOR_RECT := Rect2( 87, 44, 338, 200 )
## 头顶念力条的最小 y（世界坐标），保证不超出镜头上沿
const PSI_BAR_MIN_Y : float = 12.0
## 离光标多远开始走 / 停下（滞回）
const WALK_START_DIST : float = 10.0
const WALK_STOP_DIST : float = 4.0

## 自动攻击（旋转斩，一圈都打得到，不看朝向）：敌人（原点）到主角（原点）的距离小于它就放。
## 依据：ChargeSpinHitBox 是半径 38 的圆，伤害 2；取略小于半径的值保证放出来能打到。
## ATTACK_COOLDOWN 是两次旋转斩起手之间的最短间隔（一次旋转约 0.31 秒）
const ATTACK_RANGE : float = 34.0
## 大回旋强化：旋转斩半径 38 -> 50，自动攻击触发距离相应加大
const ATTACK_RANGE_WIDE : float = 44.0
## 强化参数
const POOL_DRAIN_FACTOR : float = 1.0 / 1.5
const POOL_REGEN_FACTOR : float = 1.3
const MAGNET_RANGE : float = 45.0
## 冲击波（实验项）：光标离主角多近算"在主角身上"、耗念力、半径、伤害、击退倍率
const SHOCK_CURSOR_DIST : float = 16.0
const SHOCK_PSI_COST : float = 0.3
const SHOCK_RADIUS : float = 50.0
const SHOCK_DAMAGE : int = 1
const SHOCK_KNOCKBACK : float = 2.5
const ATTACK_COOLDOWN : float = 0.7

## 念力：不低于它才能起飞 / 重新抓住
const PSI_START_MIN : float = 0.3
## 起飞后这段时间内目标点固定不动，不追光标（握拳瞬间掌心会跳）：
## 手势模式固定在握拳那一刻的光标位置；键盘模式固定在主角朝向前方 LAUNCH_FIXED_DIST 像素
const LAUNCH_FIXED_TIME : float = 0.15
const LAUNCH_FIXED_DIST : float = 70.0
## 光标离主角不到这么远时，起飞方向用主角朝向
const LAUNCH_AIM_MIN_DIST : float = 8.0
## 键盘模式：目标点 = 回旋镖当前位置 + 方向键方向 * KEY_STEP
const KEY_STEP : float = 80.0

## 操控状态变化时发出的简短英文事件（LAUNCH / REGRAB / RELEASE: ... / BLOCKED: ...），
## 给练习场面板的事件日志用
signal control_event( text : String )
## 已拥有的强化变化时发出（参数是按 Upgrades.LIST 顺序排列的 id 数组），HUD 图标行用
signal upgrades_changed( ids : Array )

## ---------- 调参（普通变量，练习场面板运行时会改它们） ----------
## 走位时光标每秒最多移动的像素数
var cursor_max_speed : float = 300.0
## 走位时光标朝手的位置做指数平滑的时间常数（秒），越大越"肉"
var cursor_smooth_time : float = 0.06
## 操控回旋镖时的光标限速 / 平滑（要更跟手，所以比走位时快）
var guided_cursor_max_speed : float = 420.0
var guided_cursor_smooth_time : float = 0.05
## 手势模式主角走速 = clamp( 离光标距离 * walk_speed_gain, walk_speed_min, walk_speed_max )
var walk_speed_gain : float = 7.0
var walk_speed_min : float = 40.0
var walk_speed_max : float = 130.0
## 手丢失后保持原状态的宽限（秒）；操控回旋镖时用 guided_hand_grace，回旋镖停在最后的目标点等待
var hand_grace : float = 0.3
var guided_hand_grace : float = 0.6
## 念力每秒消耗 / 回复（0-1 为满）
var psi_drain : float = 1.0 / 3.0
var psi_regen : float = 1.0 / 4.0
## 念力爆破（受控飞行结束时在镖的位置炸一次；手丢失不炸）：范围半径（像素）、伤害、
## 张开 / 松键触发时额外扣的念力（0-1，不够扣到 0 仍爆；念力耗尽触发的不额外扣）、
## 本次受控飞行至少持续多久才爆（秒，防止点一下就炸）。放在控制器里是因为触发在这里判断，练习场面板也在这里调参
var blast_radius : float = 36.0
var blast_damage : int = 2
var blast_psi_cost : float = 0.15
var blast_min_guided_time : float = 0.3
## 念力爆破是强化解锁的技能，默认关闭；由 has_upgrade("blast") 同步，每局开始 reset_upgrades() 复位
var blast_enabled : bool = false
## 自动攻击触发距离（大回旋强化时加大）
var attack_range : float = ATTACK_RANGE
## 已拥有的强化集合（id -> true）。放在控制器里的原因：念力、回旋镖起飞、自动攻击的参数都在这里，
## 强化是"开关状态 -> 效果"，set_upgrade() 会把效果同步到各处，关闭时恢复；reset() 每局清空
var upgrades : Dictionary = {}

## ---------- 开关（默认是正常游戏的行为；练习场面板会改） ----------
## false 时主角不走位，始终站定
var walk_enabled : bool = true
var auto_attack_enabled : bool = true
## true 时念力不消耗、始终满
var psi_infinite : bool = false

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
## 光标在世界坐标里的位置（只读，给练习场面板用）
var cursor_pos : Vector2 :
	get:
		return _cursor_pos

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
var _prev_hold : bool = false
## 念力耗尽收回之后，必须先张开（或松开按键）一次才能再起飞，防止握着拳立刻又飞出去
var _need_open : bool = false
## 手势起飞时握拳那一刻的光标位置（起飞后前 LAUNCH_FIXED_TIME 秒的目标）
var _launch_cursor : Vector2 = CENTER
var _guided_by_hand : bool = false
var _guided_time : float = 0.0
## 本次受控飞行已持续的时间（regrab 也从 0 重新算），判断爆破用
var _guided_age : float = 0.0
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
	reset_upgrades()
	_shutdown_control()
	psi = 1.0
	_attack_cd = 0.0
	_prev_hold = false
	_need_open = false
	_update_hud()


## 强化全部复位；reset() 会调用
func reset_upgrades() -> void:
	upgrades.clear()
	_apply_upgrades()
	upgrades_changed.emit( owned_ids() )


func has_upgrade( id : String ) -> bool:
	return upgrades.get( id, false )


## 按表顺序返回已拥有的强化 id
func owned_ids() -> Array:
	var r : Array = []
	for id in Upgrades.all_ids():
		if has_upgrade( id ):
			r.append( id )
	return r


## 开 / 关一项强化（每项只能拥有一次，重复开 / 关无效果）
func set_upgrade( id : String, on : bool ) -> void:
	if on == has_upgrade( id ) or Upgrades.get_def( id ).is_empty():
		return
	if on:
		upgrades[id] = true
	else:
		upgrades.erase( id )
	_apply_upgrades()
	upgrades_changed.emit( owned_ids() )


## 把当前强化集合同步成实际效果（可重复调用；各项都是"由集合推出状态"，所以开关都可逆）
func _apply_upgrades() -> void:
	blast_enabled = has_upgrade( "blast" )
	# 弹反：静态变量，复位时必须清掉
	EnemyProjectile.parry_by_spin = has_upgrade( "parry" )
	attack_range = ATTACK_RANGE_WIDE if has_upgrade( "wide_spin" ) else ATTACK_RANGE
	if is_instance_valid( _player ):
		var spin := _player.get_node_or_null( "StateMachine/ChargeAttack" ) as State_ChargeAttack
		if spin != null:
			spin.set_wide( has_upgrade( "wide_spin" ) )
		# 心之容器：上限 +2（一颗心），新增的容量立即补满；关闭 / 重开时恢复上限
		var want := Player.BASE_MAX_HP + ( 2 if has_upgrade( "heart" ) else 0 )
		if want != _player.max_hp:
			var diff := want - _player.max_hp
			_player.max_hp = want
			_player.hp = clampi( _player.hp + maxi( diff, 0 ), 0, want )
			_player.update_hp( 0 )
		_apply_to_boomerang( _abilities.boomerang_instance if _abilities != null and _abilities.has_boomerang() else null )


## 回旋镖相关强化：沉重 / 吸附 / 冰霜；每次起飞和强化切换时对当前实例套用
func _apply_to_boomerang( b : Boomerang ) -> void:
	if b == null:
		return
	b.set_heavy( has_upgrade( "pierce" ) )
	b.magnet_range = MAGNET_RANGE if has_upgrade( "magnet" ) else 18.0
	b.frost = has_upgrade( "frost" )


## 实际的念力每秒消耗 / 回复（念力池强化：持续时间 x1.5，回充 +30%）
func _drain_rate() -> float:
	return psi_drain * ( POOL_DRAIN_FACTOR if has_upgrade( "pool" ) else 1.0 )


func _regen_rate() -> float:
	return psi_regen * ( POOL_REGEN_FACTOR if has_upgrade( "pool" ) else 1.0 )


## 回复念力（amount 为 0-1 的比例，结果夹在 0-1），宝石 / 药水用
func add_psi( amount : float ) -> void:
	psi = clampf( psi + amount, 0.0, 1.0 )
	_update_hud()


## 关卡卸载时复原主角状态
func release_player() -> void:
	_shutdown_control()
	# 主角是全局节点：强化效果（血量上限、旋转斩范围、弹反静态变量）不能带出本关
	reset_upgrades()


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

	# 回旋镖被外部销毁时，操控也结束（并要求先张开，免得下一帧又飞出去）
	if guided and not _abilities.has_boomerang():
		_end_guided()
		_need_open = true

	var fist := hand_mode and GestureInput.is_fist and GestureInput.hand_present
	var hand_now := hand_mode and GestureInput.hand_present
	if hand_now:
		var goal := _hand_to_arena( GestureInput.hand_pos )
		# 手刚出现的第一帧直接跳过去，之后先平滑再限速（操控回旋镖时用更跟手的一组参数）
		if _had_hand:
			var smooth_t := guided_cursor_smooth_time if guided else cursor_smooth_time
			var max_v := guided_cursor_max_speed if guided else cursor_max_speed
			var smoothed := _cursor_pos.lerp( goal, 1.0 - exp( -delta / smooth_t ) )
			_cursor_pos = _cursor_pos.move_toward( smoothed, max_v * delta )
		else:
			_cursor_pos = goal
	_had_hand = hand_now

	# "想操控"：手势 = 握着拳；键盘 = 按住 ability。电平触发，只有上升沿才发反馈事件
	var hold := fist if hand_mode else Input.is_action_pressed( "ability" )
	var rise := hold and not _prev_hold
	_prev_hold = hold
	# 张开 / 松开键之后才解除"需要先张开"的锁
	if _need_open:
		var opened := (hand_now and not fist) if hand_mode else not hold
		if opened:
			_need_open = false

	if not guided:
		if hold:
			_try_start( hand_mode, rise )
	else:
		_check_release( hand_mode )

	# 念力：操控中消耗，否则恢复
	if psi_infinite:
		psi = 1.0
	elif guided:
		psi = maxf( psi - _drain_rate() * delta, 0.0 )
		if psi <= 0.0:
			_need_open = true
			_end_guided( "RELEASE: PSI EMPTY" )
	else:
		psi = minf( psi + _regen_rate() * delta, 1.0 )

	if guided:
		_update_guided( delta, hand_mode )
	_update_walk( hand_mode )
	_update_cursor( hand_mode )
	if auto_attack_enabled:
		_update_auto_attack()
	_update_hud()


## 更新手丢失计时，返回当前是否用手势操控
func _update_hand_state( delta : float ) -> bool:
	if GestureInput.hand_present:
		_hand_lost_time = 0.0
	else:
		_hand_lost_time += delta
	var grace := guided_hand_grace if guided else hand_grace
	return GestureInput.connected and GestureInput.calibrated 		and (GestureInput.hand_present or _hand_lost_time < grace)


## 想操控但还没在操控：满足条件就起飞（或重新抓住正在返回的回旋镖）
func _try_start( by_hand : bool, rise : bool ) -> void:
	if _need_open:
		if rise:
			control_event.emit( "BLOCKED: NEED OPEN" )
		return
	if psi < PSI_START_MIN and not psi_infinite:
		if rise:
			_psi_low_feedback()
			control_event.emit( "BLOCKED: PSI LOW" )
		return
	var b := _abilities.regrab_guided()
	if b != null:
		_begin_guided( b, by_hand, true )
		control_event.emit( "REGRAB" )
		return
	if _abilities.has_boomerang():
		return
	# 冲击波（实验项）：手势握拳时光标就在主角身上，不放镖，放一圈念力冲击波
	if by_hand and has_upgrade( "shockwave" ) 			and _cursor_pos.distance_to( _player.global_position ) <= SHOCK_CURSOR_DIST:
		if rise:
			_fire_shockwave()
		return
	var dir := _player.cardinal_direction
	if by_hand:
		# 朝光标方向起飞；光标就在主角身上时用主角朝向
		var to_cursor := _cursor_pos - (_player.global_position + Boomerang.SPRITE_OFFSET)
		if to_cursor.length() >= LAUNCH_AIM_MIN_DIST:
			dir = to_cursor.normalized()
		_launch_cursor = _cursor_pos
	b = _abilities.start_guided( dir )
	if b == null:
		return
	_apply_to_boomerang( b )
	_begin_guided( b, by_hand, false )
	control_event.emit( "LAUNCH" )


## 冲击波：耗 30% 念力，主角身上一圈念力爆炸（半径 50、伤害 1、强击退），之后要先张开再握拳
func _fire_shockwave() -> void:
	if not psi_infinite:
		psi = maxf( psi - SHOCK_PSI_COST, 0.0 )
	_need_open = true
	PsiBlast.spawn( _player.get_parent(), _player.global_position + Vector2( 0, -12 ), SHOCK_RADIUS, SHOCK_DAMAGE, SHOCK_KNOCKBACK )
	control_event.emit( "SHOCKWAVE" )


## 正在操控：判断是否该松手（张开 / 手丢失 / 松开按键）
func _check_release( hand_mode : bool ) -> void:
	if _guided_by_hand:
		if not hand_mode:
			_end_guided( "RELEASE: HAND LOST" )
		elif GestureInput.hand_present and not GestureInput.is_fist:
			_end_guided( "RELEASE: OPEN" )
	elif hand_mode:
		_end_guided( "RELEASE: OPEN" )
	elif not Input.is_action_pressed( "ability" ):
		_end_guided( "RELEASE: KEY UP" )


# ---------- 走位 ----------

func _update_walk( hand_mode : bool ) -> void:
	if not walk_enabled:
		# 站桩：手势和键盘都不能走位
		_player.use_move_override = true
		_player.move_override = Vector2.ZERO
		_player.move_speed_override = 0.0
		_walking = false
		return
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
	_player.move_speed_override = clampf( d * walk_speed_gain, walk_speed_min, walk_speed_max ) if _walking else 0.0


## 操作框归一化坐标 -> 房间里的光标目标点（手活动区域线性映射到 CURSOR_RECT 并钳制）
func _hand_to_arena( p : Vector2 ) -> Vector2:
	var u := clampf( (p.x - HAND_X_MIN) / (HAND_X_MAX - HAND_X_MIN), 0.0, 1.0 )
	var v := clampf( (p.y - HAND_Y_MIN) / (HAND_Y_MAX - HAND_Y_MIN), 0.0, 1.0 )
	return CURSOR_RECT.position + Vector2( u, v ) * CURSOR_RECT.size


# ---------- 回旋镖 ----------

## 进入操控状态。regrab 为 true 时回旋镖已在飞，不再固定目标点，直接追光标
func _begin_guided( b : Boomerang, by_hand : bool, regrab : bool ) -> void:
	_boomerang = b
	guided = true
	_guided_by_hand = by_hand
	_guided_time = LAUNCH_FIXED_TIME if regrab else 0.0
	_guided_age = 0.0
	_player.can_move = false
	_player.move_override = Vector2.ZERO


## reason 非空时发 control_event（外部清理、死亡等静默收尾传空）
func _end_guided( reason : String = "" ) -> void:
	if not guided:
		return
	guided = false
	# 先记下镖精灵的位置，再放开镖
	var blast_pos := Vector2.ZERO
	if is_instance_valid( _boomerang ):
		blast_pos = _boomerang.global_position + Boomerang.SPRITE_OFFSET
	var can_blast := is_instance_valid( _boomerang ) and _guided_age >= blast_min_guided_time
	_boomerang = null
	_abilities.release_guided()
	_player.can_move = true
	if reason != "":
		control_event.emit( reason )
	# 张开 / 松键 / 念力耗尽才爆，手丢失和静默收尾不爆
	if blast_enabled and can_blast and reason in [ "RELEASE: OPEN", "RELEASE: KEY UP", "RELEASE: PSI EMPTY" ]:
		if reason != "RELEASE: PSI EMPTY" and not psi_infinite:
			psi = maxf( psi - blast_psi_cost, 0.0 )
		PsiBlast.spawn( _player.get_parent(), blast_pos, blast_radius, blast_damage )
		control_event.emit( "BLAST" )


func _update_guided( delta : float, hand_mode : bool ) -> void:
	_guided_time += delta
	_guided_age += delta
	if not is_instance_valid( _boomerang ):
		return
	var sprite_off := Boomerang.SPRITE_OFFSET
	var target : Vector2
	if _guided_time < LAUNCH_FIXED_TIME:
		if _guided_by_hand:
			target = _launch_cursor - sprite_off
		else:
			target = _player.global_position + _player.cardinal_direction * LAUNCH_FIXED_DIST
	elif hand_mode:
		# 让回旋镖的精灵对准光标：节点原点 = 光标 - 精灵偏移
		# （手丢失但还在宽限内时光标不动，回旋镖就停在最后的目标点等待）
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


# ---------- 自动攻击（旋转斩） ----------

func _update_auto_attack() -> void:
	if _attack_cd > 0.0:
		return
	var state := _player.state_machine.current_state
	if not (state is State_Idle or state is State_Walk):
		return
	var in_range := false
	var target := _nearest_enemy()
	if target != null and ( target.global_position - _player.global_position ).length() < attack_range:
		in_range = true
	# Boss 只在破绽阶段（护盾碎了）才当目标；按离身体边缘的距离算，和普通敌人同一量纲
	if not in_range:
		for b in get_tree().get_nodes_in_group( "wizard_boss" ):
			if b is WizardBoss and b.vulnerable and b.melee_distance( _player.global_position ) < attack_range:
				in_range = true
				break
	if not in_range:
		return
	_attack_cd = ATTACK_COOLDOWN
	_swing()


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


## 注入 attack 按下，下一帧松开：状态机里就是一次旋转斩（State_ChargeAttack.instant）
func _swing() -> void:
	_send_attack( true )
	await get_tree().process_frame
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
