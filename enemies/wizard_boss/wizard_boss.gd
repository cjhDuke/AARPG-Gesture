class_name WizardBoss extends Node2D
## 巫师 Boss（关卡 3 WIZARD HALL）。独立节点，不继承 Enemy：不参与波次计数、掉落、冰霜、盾牌钩子；
## 自动攻击通过节点组 wizard_boss 找到它（只在 vulnerable 时当目标）。
##
## 循环（共 3 轮 = 3 段血条，每段 segment_hp 点）：
##   SHIELD 护盾阶段：浮在场地上部缓慢漂移，护盾免疫一切伤害；四角火把默认点燃，镖 / 念力爆破碰到就熄灭
##     （回 15% 念力），熄灭的火把倒计时重燃；4 支同时熄灭 -> 护盾碎裂。期间放火球、光束，第 2 轮起召唤小怪。
##   STUN 破绽阶段：坠到地面眩晕 stun_time 秒，可受伤。这一段血打空 -> 下一轮（第 3 段打空则死亡）；
##     时间到没打空 -> 回到护盾阶段，剩余血量保留。两种情况都是护盾恢复、火把全部重燃。
##   DYING 死亡演出约 1.5 秒（连续小爆炸），清掉小怪和投射物，发 defeated。
## 火球被镖打到会反弹回来，命中巫师使其踉跄（打断蓄力，攻击计时推迟 stagger_delay 秒）。
## 巫师自己创建的所有场上节点（火把、光束、特效、阴影）都在节点组 boss_fx，cleanup() 统一释放。

signal hp_changed( round_no : int, seg_hp : int, seg_max : int )
signal defeated
## 每段血首次打空时立即发出（1..3）；不等待最后的死亡演出。
signal segment_cleared(segment: int)

enum Phase { ENTER, SHIELD, STUN, DYING, DEAD }

const CLOAK : Texture2D = preload( "res://enemies/art_v2/boss_cloak_actions.png" )
const HANDS : Texture2D = preload( "res://enemies/art_v2/boss_hand.png" )
const SND_HURT : AudioStream = preload( "res://enemies/wizard_boss/boss_hurt.wav" )
const SND_FIREBALL : AudioStream = preload( "res://enemies/wizard_boss/boss_fireball.wav" )
const SND_FIREBALL_HIT : AudioStream = preload( "res://enemies/wizard_boss/boss_fireball_hit.wav" )
const SND_DESTROY : AudioStream = preload( "res://enemies/wizard_boss/boss_destroy.wav" )
const SND_BLOCK : AudioStream = preload( "res://enemies/shield_goblin/clang.wav" )

## 飞行 / 落地时的身体中心（世界坐标）；节点原点就是身体中心
const FLY_POS := HandController.CENTER + Vector2( 0, -50 )
const GROUND_POS := HandController.CENTER + Vector2( 0, -20 )
## 四个火把的底座位置：在镖能到的范围（CURSOR_RECT）内，避开左上摄像头面板、右上血量 / 苹果、左下强化图标、底部状态行
const TORCH_BASES : Array[Vector2] = [ Vector2( 112, 108 ), Vector2( 400, 108 ), Vector2( 112, 222 ), Vector2( 400, 222 ) ]
## 身体受击圆半径（像素）
const BODY_RADIUS : float = 24.0
const ROUNDS : int = 3
## 主角受击框中心比脚底原点高多少
const PLAYER_BODY_OFFSET := Vector2( 0, -14 )

## 调试：火把重燃时间的倍率（练习场面板可调）
static var relight_scale : float = 1.0

@export_category( "Health" )
## 每段血条的血量
@export var segment_hp : int = 10
@export_category( "Shield phase" )
## 第 1 / 2 / 3 轮火把熄灭后的重燃时间（秒）
@export var relight_times : Array[float] = [ 8.0, 7.0, 6.0 ]
## 熄灭火把回的念力比例
@export var torch_psi : float = 0.15
@export var enter_time : float = 1.0
@export var drift_amplitude : float = 60.0
@export var drift_speed : float = 0.5
@export_category( "Stun phase" )
@export var stun_time : float = 5.0
@export_category( "Attacks" )
## 第 1 / 2 / 3 轮的火球间隔（秒）；第 2 轮连发 2 发（间隔 fireball_gap），第 3 轮 3 发扇形（±fan_angle 度）
@export var fireball_intervals : Array[float] = [ 2.4, 2.0, 1.6 ]
@export var fireball_gap : float = 0.25
@export var fan_angle : float = 18.0
@export var fireball_speed : float = 90.0
@export var charge_time : float = 0.4
## 第 1 / 2 / 3 轮的光束间隔（秒）；第 3 轮一横一纵同时两条
@export var beam_intervals : Array[float] = [ 10.0, 8.0, 6.0 ]
## 召唤（第 2 轮起）：间隔、场上小怪超过这个数不召、每轮召的怪（第 2 / 3 轮）
@export var summon_interval : float = 9.0
@export var summon_cap : int = 4
@export var summon_types : Array = [ [ "slime", "slime" ], [ "slime", "bomb_slime" ] ]
## 被反弹火球打中后所有攻击计时推迟多久（秒）
@export var stagger_delay : float = 2.0

var phase : Phase = Phase.ENTER
## 当前是第几轮（0-based，0..2）和这一段剩余血量
var round_idx : int = 0
var seg_hp : int = 10
## 为 false 时停止一切行动（主角死亡后冻结）
var active : bool = true
var spawner : WaveSpawner
var controller : HandController
var torches : Array[BossTorch] = []

## 攻击计时（秒）；公开给测试和调试面板看
var fire_timer : float = 0.0
var beam_timer : float = 0.0
var summon_timer : float = 0.0
## 被反弹火球打中的累计次数（测试 / 调试用）
var stagger_count : int = 0

var _player : Player
var _stun_left : float = 0.0
var _enter_left : float = 0.0
var _drift_t : float = 0.0
var _anim_t : float = 0.0
var _fall_t : float = 1.0
var _fall_from : Vector2
var _charging : bool = false
var _charge_left : float = 0.0
var _volley_left : int = 0
var _volley_timer : float = 0.0
var _stagger_left : float = 0.0
var _teleport_left : float = 0.0
var _flash_left : float = 0.0
var _shield_flash : float = 0.0
var _block_cd : float = 0.0
var _dying_t : float = 0.0
var _boomed : bool = false
var _small_boom_t : float = 0.0
var _beams : Array[BossBeam] = []

var _cloak : Sprite2D
var _hand_l : Sprite2D
var _hand_r : Sprite2D
var _over : Node2D
var _hurt : HurtBox
var _audio : AudioStreamPlayer
var _shadow : BossExplosion.BossShadow

## 是否处于破绽阶段（能受伤、自动攻击以它为目标）
var vulnerable : bool :
	get:
		return phase == Phase.STUN


## 护盾是否在（登场和护盾阶段）
var shielded : bool :
	get:
		return phase == Phase.ENTER or phase == Phase.SHIELD


## 创建并放到 parent 下，开始登场
static func spawn( parent : Node, spawner_node : WaveSpawner, ctrl : HandController ) -> WizardBoss:
	var b := WizardBoss.new()
	b.spawner = spawner_node
	b.controller = ctrl
	parent.add_child( b )
	return b


func _ready() -> void:
	add_to_group( "wizard_boss" )
	_player = PlayerManager.player
	seg_hp = segment_hp
	position = FLY_POS
	z_index = 4
	_build_nodes()
	_make_torches()
	_enter_left = enter_time
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property( self, "modulate:a", 1.0, enter_time )
	for t in torches:
		t.modulate.a = 0.0
		t.create_tween().tween_property( t, "modulate:a", 1.0, enter_time )
	hp_changed.emit( round_idx + 1, seg_hp, segment_hp )


func _build_nodes() -> void:
	_cloak = Sprite2D.new()
	_cloak.texture = CLOAK
	_cloak.hframes = 10
	_cloak.position = Vector2( 0, -7 )
	add_child( _cloak )
	_hand_l = _make_hand( false )
	_hand_r = _make_hand( true )
	_over = Node2D.new()
	_over.draw.connect( _draw_over )
	add_child( _over )
	_hurt = HurtBox.new()
	_hurt.collision_layer = 256
	_hurt.collision_mask = 0
	_hurt.monitoring = false
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = BODY_RADIUS
	shape.shape = circle
	_hurt.add_child( shape )
	add_child( _hurt )
	_hurt.Damaged.connect( _on_damaged )
	_audio = AudioStreamPlayer.new()
	_audio.bus = &"SFX"
	add_child( _audio )
	# 阴影放在关卡根下（和主角同层级，z 低于主角）
	_shadow = BossExplosion.BossShadow.new()
	_shadow.boss = self
	_shadow.ground_y = GROUND_POS.y
	get_parent().add_child( _shadow )


func _make_hand( flip : bool ) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = HANDS
	s.hframes = 16
	s.frame = 1
	s.flip_h = flip
	add_child( s )
	return s


func _make_torches() -> void:
	for base in TORCH_BASES:
		var t := BossTorch.new()
		t.boss = self
		get_parent().add_child( t )
		t.global_position = base
		torches.append( t )


# ---------- 公开接口 ----------

func body_center() -> Vector2:
	return global_position


## 主角（原点）离巫师身体边缘的距离，自动攻击用：和普通敌人"原点到原点"的距离同一量纲
func melee_distance( from : Vector2 ) -> float:
	return maxf( from.distance_to( global_position ) - BODY_RADIUS, 0.0 )


func torches_out() -> int:
	var n := 0
	for t in torches:
		if not t.lit:
			n += 1
	return n


func relight_time() -> float:
	return relight_times[clampi( round_idx, 0, ROUNDS - 1 )] * relight_scale


func vulnerable_seconds_left() -> float:
	return maxf( _stun_left, 0.0 ) if vulnerable else 0.0


## 剩余总血量（所有段）
func total_hp() -> int:
	return ( ROUNDS - 1 - round_idx ) * segment_hp + seg_hp


## 面板 / 调试用的阶段名
func phase_name() -> String:
	return Phase.keys()[phase]


## 主角死亡等情况：停止一切行动，保留当前画面
func freeze() -> void:
	active = false


## 释放自己创建的所有场上节点（火把、光束、特效、阴影）和自身。可重复调用
func cleanup() -> void:
	active = false
	phase = Phase.DEAD
	if is_inside_tree():
		for n in get_tree().get_nodes_in_group( "boss_fx" ):
			n.queue_free()
		queue_free()
	torches.clear()
	_beams.clear()


# ---------- 受击 ----------

func _on_damaged( hit_box : HitBox ) -> void:
	if phase == Phase.DYING or phase == Phase.DEAD:
		return
	if phase != Phase.STUN:
		_block_feedback()
		return
	seg_hp = maxi( seg_hp - hit_box.damage, 0 )
	_flash_left = 0.12
	_play( SND_HURT )
	hp_changed.emit( round_idx + 1, seg_hp, segment_hp )
	if seg_hp <= 0:
		_segment_cleared()


## 护盾挡住：护盾闪一下 + 格挡音（0.25 秒内不重复响）
func _block_feedback() -> void:
	_shield_flash = 0.15
	if _block_cd <= 0.0:
		_block_cd = 0.25
		_play( SND_BLOCK, -6.0 )


func _segment_cleared() -> void:
	segment_cleared.emit(round_idx + 1)
	if round_idx >= ROUNDS - 1:
		_die()
		return
	round_idx += 1
	seg_hp = segment_hp
	hp_changed.emit( round_idx + 1, seg_hp, segment_hp )
	_enter_shield()


# ---------- 火把 / 护盾 ----------

## 熄灭一支火把（回念力、特效、音效），4 支全灭则碎盾。只在护盾阶段有效
func douse( torch : BossTorch ) -> void:
	if phase != Phase.SHIELD or not torch.lit:
		return
	torch.extinguish( relight_time() )
	if controller != null:
		controller.add_psi( torch_psi )
	torch.play_absorb( _player )
	Pickup.show_float_text( get_parent(), torch.global_position + Vector2( 0, -56 ), "+PSI" )
	if torches_out() >= torches.size():
		_break_shield()


## 调试用：立刻熄灭全部火把并碎盾
func debug_break_shield() -> void:
	if phase != Phase.SHIELD:
		return
	for t in torches:
		t.extinguish( relight_time() )
	_break_shield()


func _break_shield() -> void:
	phase = Phase.STUN
	_stun_left = stun_time
	_fall_from = position
	_fall_t = 0.0
	_charging = false
	_volley_left = 0
	BossExplosion.spawn( get_parent(), global_position, 1.5, 0.55, Color( 0.7, 0.9, 1.0 ) )
	_play( SND_DESTROY, -4.0, 1.5, 0.7 )


## 回到护盾阶段（轮数已由调用方处理）：瞬移回空中，火把全部重燃，攻击计时重置
func _enter_shield() -> void:
	var old := global_position
	phase = Phase.SHIELD
	position = FLY_POS
	z_index = 4
	_fall_t = 1.0
	_teleport_left = 0.5
	_charging = false
	_volley_left = 0
	_beams.clear()
	for t in torches:
		t.relight()
	var r := clampi( round_idx, 0, ROUNDS - 1 )
	fire_timer = 1.6
	beam_timer = beam_intervals[r] * 0.6
	summon_timer = summon_interval * 0.6
	# 瞬移表现：旧位置一团爆炸，新位置淡入
	BossExplosion.spawn( get_parent(), old, 0.7, 0.4, Color( 0.8, 0.7, 1.0 ) )
	modulate.a = 0.0
	create_tween().tween_property( self, "modulate:a", 1.0, 0.35 )


# ---------- 火球反弹 ----------

## 反弹的火球命中：踉跄，打断蓄力，所有攻击计时推迟 stagger_delay 秒
func on_fireball_hit() -> void:
	stagger_count += 1
	_stagger_left = 0.5
	_charging = false
	_volley_left = 0
	fire_timer += stagger_delay
	beam_timer += stagger_delay
	summon_timer += stagger_delay
	_play( SND_FIREBALL_HIT )
	BossExplosion.spawn( get_parent(), global_position + Vector2( 0, -4 ), 0.5, 0.3, Color( 1.0, 0.8, 0.5 ) )


# ---------- 每帧 ----------

func _process( delta : float ) -> void:
	_anim_t += delta
	_block_cd = maxf( _block_cd - delta, 0.0 )
	_shield_flash = maxf( _shield_flash - delta, 0.0 )
	_flash_left = maxf( _flash_left - delta, 0.0 )
	_stagger_left = maxf( _stagger_left - delta, 0.0 )
	_update_visuals()
	if active:
		match phase:
			Phase.ENTER:
				_update_enter( delta )
			Phase.SHIELD:
				_update_shield( delta )
			Phase.STUN:
				_update_stun( delta )
			Phase.DYING:
				_update_dying( delta )
	_over.queue_redraw()


func _hover_offset() -> Vector2:
	return Vector2( sin( _drift_t * drift_speed ) * drift_amplitude, sin( _drift_t * 2.2 ) * 3.0 )


func _update_enter( delta : float ) -> void:
	_drift_t += delta
	position = FLY_POS + _hover_offset()
	_enter_left -= delta
	if _enter_left <= 0.0:
		_enter_shield_first()


## 登场结束：和 _enter_shield 相同的设置，但不做瞬移表现
func _enter_shield_first() -> void:
	phase = Phase.SHIELD
	var r := 0
	fire_timer = 1.6
	beam_timer = beam_intervals[r] * 0.6
	summon_timer = summon_interval * 0.6


func _update_shield( delta : float ) -> void:
	_drift_t += delta
	position = FLY_POS + _hover_offset()
	if _teleport_left > 0.0:
		_teleport_left -= delta
		return
	if _stagger_left > 0.0:
		return
	var r := clampi( round_idx, 0, ROUNDS - 1 )
	# 火球：蓄力 -> 出手（第 2 轮连发，第 3 轮扇形）
	if _charging:
		_charge_left -= delta
		if _charge_left <= 0.0:
			_charging = false
			_start_volley()
	elif _volley_left > 0:
		_volley_timer -= delta
		if _volley_timer <= 0.0:
			_shoot( 0.0 )
			_volley_left -= 1
			_volley_timer = fireball_gap
	else:
		fire_timer -= delta
		if fire_timer <= 0.0:
			if _beam_firing():
				fire_timer = 0.4
			else:
				_charging = true
				_charge_left = charge_time
				fire_timer = fireball_intervals[r]
	# 光束：不和火球蓄力 / 连发在同一瞬间出手
	beam_timer -= delta
	if beam_timer <= 0.0:
		if _charging or _volley_left > 0:
			beam_timer = 0.4
		else:
			_start_beams()
			beam_timer = beam_intervals[r]
	# 召唤（第 2 轮起）
	if round_idx >= 1:
		summon_timer -= delta
		if summon_timer <= 0.0:
			summon_timer = summon_interval
			_summon()


func _update_stun( delta : float ) -> void:
	if _fall_t < 1.0:
		_fall_t = minf( _fall_t + delta / 0.3, 1.0 )
		position = _fall_from.lerp( GROUND_POS, ease( _fall_t, 2.0 ) )
		if _fall_t >= 1.0:
			z_index = 2
			BossExplosion.spawn( get_parent(), GROUND_POS + Vector2( 0, 26 ), 0.45, 0.35, Color( 0.9, 0.85, 0.8 ) )
	else:
		position = GROUND_POS
	_stun_left -= delta
	if _stun_left <= 0.0:
		_enter_shield()


# ---------- 攻击 ----------

func _muzzle() -> Vector2:
	return global_position + Vector2( 0, 12 )


func _player_center() -> Vector2:
	return _player.global_position + PLAYER_BODY_OFFSET


func _start_volley() -> void:
	if round_idx >= 2:
		_shoot( -fan_angle )
		_shoot( 0.0 )
		_shoot( fan_angle )
	else:
		_volley_left = 2 if round_idx == 1 else 1
		_volley_timer = 0.0


func _shoot( angle_deg : float ) -> void:
	var dir := ( _player_center() - _muzzle() ).normalized().rotated( deg_to_rad( angle_deg ) )
	var f := EnemyProjectile.fire( BossFireball, get_parent(), _muzzle() + dir * 12.0, dir ) as BossFireball
	f.boss = self
	f.speed = fireball_speed
	f.z_index = 3
	_play( SND_FIREBALL, -6.0 )


func _beam_firing() -> bool:
	for b in _beams:
		if is_instance_valid( b ) and b.is_firing():
			return true
	return false


## 光束：线穿过主角当前位置；第 3 轮一横一纵两条，其余轮随机横或纵
func _start_beams() -> void:
	_beams.assign( _beams.filter( func( b ) -> bool: return is_instance_valid( b ) ) )
	var p := _player_center()
	if round_idx >= 2:
		_beams.append( BossBeam.spawn( get_parent(), true, p.y ) )
		_beams.append( BossBeam.spawn( get_parent(), false, p.x ) )
	else:
		var horizontal := randi() % 2 == 0
		_beams.append( BossBeam.spawn( get_parent(), horizontal, p.y if horizontal else p.x ) )


func _count_minions() -> int:
	var n := 0
	for c in get_parent().get_children():
		if c is Enemy and not c._is_defeated and not c.is_queued_for_deletion():
			n += 1
	return n


func _summon() -> void:
	if spawner == null or _count_minions() > summon_cap:
		return
	var types : Array = summon_types[clampi( round_idx - 1, 0, summon_types.size() - 1 )]
	for type_name in types:
		spawner.spawn_extra( type_name, spawner.pick_spawn_position() )


# ---------- 死亡 ----------

func _die() -> void:
	phase = Phase.DYING
	_dying_t = 0.0
	_small_boom_t = 0.0
	_boomed = false
	_charging = false
	_volley_left = 0
	_hurt.set_deferred( "monitorable", false )
	# 小怪、投射物、光束、火把全部清掉
	if spawner != null:
		spawner.clear()
	for t in torches:
		if is_instance_valid( t ):
			t.queue_free()
	torches.clear()
	for b in _beams:
		if is_instance_valid( b ):
			b.queue_free()
	_beams.clear()
	z_index = 4
	_play( SND_DESTROY )


const DEATH_TIME : float = 1.5
const DEATH_BIG_BOOM : float = 1.1


func _update_dying( delta : float ) -> void:
	_dying_t += delta
	_small_boom_t -= delta
	if _small_boom_t <= 0.0 and _dying_t < DEATH_BIG_BOOM:
		_small_boom_t = 0.12
		var off := Vector2( randf_range( -26, 26 ), randf_range( -30, 24 ) )
		BossExplosion.spawn( get_parent(), global_position + off, randf_range( 0.35, 0.7 ), 0.35 )
	if not _boomed and _dying_t >= DEATH_BIG_BOOM:
		_boomed = true
		BossExplosion.spawn( get_parent(), global_position, 2.0, 0.5, Color( 1.0, 0.9, 1.0 ) )
		_cloak.visible = false
		_hand_l.visible = false
		_hand_r.visible = false
	if _dying_t >= DEATH_TIME:
		phase = Phase.DEAD
		defeated.emit()


# ---------- 表现 ----------

func _play( stream : AudioStream, volume_db : float = 0.0, pitch : float = 1.0, stop_after : float = 0.0 ) -> void:
	_audio.stream = stream
	_audio.volume_db = volume_db
	_audio.pitch_scale = pitch
	_audio.play()
	if stop_after > 0.0:
		get_tree().create_timer( stop_after ).timeout.connect( func() -> void:
			if is_instance_valid( _audio ) and _audio.stream == stream:
				_audio.stop() )


func _update_visuals() -> void:
	var cloak_frame: int = [ 1, 2, 3, 2 ][ int( _anim_t * 5.0 ) % 4 ]
	if phase == Phase.ENTER and _anim_t < enter_time * 0.25:
		cloak_frame = 0
	elif phase == Phase.STUN:
		cloak_frame = 6 if _fall_t >= 1.0 else 5
	elif phase == Phase.DYING:
		cloak_frame = 8 if _dying_t < 0.55 else 9
	elif _charging:
		cloak_frame = 4
	if phase != Phase.DYING and ( _flash_left > 0.0 or _stagger_left > 0.0 ):
		cloak_frame = 7
	_cloak.frame = cloak_frame
	# 抖动：踉跄、死亡、眩晕
	var shake := Vector2.ZERO
	if _stagger_left > 0.0:
		shake = Vector2( sin( _anim_t * 80.0 ) * 2.0, 0 )
	elif phase == Phase.DYING:
		shake = Vector2( randf_range( -2, 2 ), randf_range( -1, 1 ) )
	elif phase == Phase.STUN:
		shake = Vector2( sin( _anim_t * 25.0 ) * 0.8, 0 )
	_cloak.position = Vector2( 0, -7 ) + shake
	_cloak.modulate = Color( 2.2, 2.2, 2.2 ) if _flash_left > 0.0 else ( Color( 0.8, 0.8, 0.9 ) if phase == Phase.STUN else Color.WHITE )
	# 双手：待机轻晃；蓄力举起并发光；眩晕垂下
	var bob := sin( _anim_t * 3.0 ) * 2.0
	var lp := Vector2( -40, 8 + bob )
	var rp := Vector2( 40, 8 - bob )
	var fr: int = [ 1, 3, 1, 4 ][ int( _anim_t * 5.0 ) % 4 ]
	if _charging:
		lp = Vector2( -22, -2 )
		rp = Vector2( 22, -2 )
		fr = 5 if _charge_left > charge_time * 0.6 else ( 2 if _charge_left > charge_time * 0.2 else 6 )
	elif phase == Phase.STUN:
		lp = Vector2( -36, 24 )
		rp = Vector2( 36, 24 )
		fr = 0 if _fall_t >= 1.0 else 9
	elif phase == Phase.DYING:
		lp = Vector2( -39, 19 )
		rp = Vector2( 39, 19 )
		fr = 11 if _dying_t < 0.55 else 14
	_hand_l.position = lp + shake
	_hand_r.position = rp + shake
	_hand_l.frame = fr
	_hand_r.frame = fr
	var hand_mod := Color( 1.4, 1.0, 0.7 ) if _charging else Color.WHITE
	_hand_l.modulate = hand_mod
	_hand_r.modulate = hand_mod


func _draw_over() -> void:
	# 火把到巫师的供能连线（点燃的火把才有）
	if phase == Phase.SHIELD or phase == Phase.ENTER:
		for t in torches:
			if is_instance_valid( t ) and t.lit:
				var from := _over.to_local( t.hit_center() )
				var a := 0.3 + 0.15 * sin( _anim_t * 6.0 + from.x )
				# 连到护盾边缘（不穿过披风）
				_over.draw_line( from, from.normalized() * 40.0, Color( 1.0, 0.65, 0.2, a ), 1.0 )
		_draw_shield()
	# 蓄力光球
	if _charging:
		var k := 1.0 - clampf( _charge_left / charge_time, 0.0, 1.0 )
		_over.draw_circle( Vector2( 0, 8 ), 3.0 + 7.0 * k, Color( 1.0, 0.5, 0.15, 0.35 + 0.3 * k ) )
		_over.draw_circle( Vector2( 0, 8 ), 2.0 + 3.0 * k, Color( 1.0, 0.95, 0.6 ) )
	# 眩晕：头顶转圈的星星 + 剩余时间条
	if phase == Phase.STUN:
		for i in 3:
			var ang := _anim_t * 4.0 + i * TAU / 3.0
			var p := Vector2( cos( ang ) * 16.0, -46.0 + sin( ang ) * 4.0 )
			_over.draw_circle( p, 2.0, Color( 1.0, 0.9, 0.3 ) )
		var k := clampf( _stun_left / stun_time, 0.0, 1.0 )
		_over.draw_rect( Rect2( -16, -56, 32, 3 ), Color( 0, 0, 0, 0.6 ) )
		_over.draw_rect( Rect2( -15, -55, 30.0 * k, 1 ), Color( 1.0, 0.85, 0.3 ) )


func _draw_shield() -> void:
	var r := 40.0
	var flash := clampf( _shield_flash / 0.15, 0.0, 1.0 )
	var fill := Color( 0.45, 0.65, 1.0, 0.14 + 0.35 * flash )
	_over.draw_circle( Vector2.ZERO, r, fill )
	var edge := Color( 0.6, 0.85, 1.0, 0.75 ).lerp( Color.WHITE, flash )
	_over.draw_arc( Vector2.ZERO, r, 0.0, TAU, 48, edge, 1.5 )
	# 绕行的亮弧，让护盾看起来在转
	for i in 3:
		var a0 := _anim_t * 1.5 + i * TAU / 3.0
		_over.draw_arc( Vector2.ZERO, r - 3.0, a0, a0 + 0.8, 10, Color( 0.85, 0.95, 1.0, 0.6 ), 1.0 )
