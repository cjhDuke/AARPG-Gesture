class_name TitleStage extends Node2D
## 标题背景小剧场（纯装饰）：史莱姆跳着横穿房间、哥布林来回巡逻、
## 主角走过去砍死一只史莱姆再走回来。只用 Sprite2D 按帧号播精灵表，
## 不实例化 Enemy / Player 场景，不跑任何战斗逻辑。
## 坐标是屏幕坐标（480×270），本节点放在标题 UI 的 Control 下，上面再盖一层压暗遮罩。
## 帧号全部抄自 slime.tscn / goblin.tscn / player.tscn 里的动画轨道。

const SLIME_TEX: Texture2D = preload("res://enemies/art_v2/slime_legacy.png")
const GOBLIN_TEX: Texture2D = preload("res://enemies/art_v2/goblin_legacy.png")
const PLAYER_TEX: Texture2D = preload("res://player/sprites/player_sprite.png")
const ATTACK_TEX: Texture2D = preload("res://player/sprites/attack_sprite01.png")
const SMOKE_TEX: Texture2D = preload("res://enemies/slime/destroy_smoke.png")
const SHADOW_TEX: Texture2D = preload("res://player/sprites/shadow.png")

const SCREEN_W := 480.0
const WRAP_MARGIN := 40.0

## 史莱姆 walk_side：帧 15/16/17，时间点 0/0.2/0.4，总长 0.7 秒；后 0.5 秒是起跳阶段
const SLIME_CYCLE := 0.7
const SLIME_HOP_START := 0.2
const SLIME_HOP_SPEED := 52.0
const SLIME_HOP_HEIGHT := 5.0
## 哥布林 chase_side：帧 20–23，每帧 0.15 秒
const GOBLIN_SPEED := 26.0
const GOBLIN_PATROL := Vector2( 330.0, 440.0 )
const GOBLIN_LANE_Y := 214.0

## 主角决斗的几个阶段
enum Duel { WALK_IN, SWING, WAIT, WALK_BACK, REST }
const DUEL_LANE_Y := 212.0
const DUEL_X_HOME := 42.0
const DUEL_X_FIGHT := 108.0
const DUEL_SLIME_X := 146.0
const DUEL_WALK_SPEED := 36.0
const SWING_HIT_TIME := 0.5
const SLIME_DEATH_LEN := 0.36

## 横穿房间的史莱姆：y 是车道，x 起点，dir 方向（1 向右、-1 向左）
const HOPPERS: Array[Dictionary] = [
	{ "y": 134.0, "x": 90.0, "dir": 1.0, "phase": 0.0 },
	{ "y": 166.0, "x": 400.0, "dir": -1.0, "phase": 0.3 },
	{ "y": 194.0, "x": 250.0, "dir": 1.0, "phase": 0.5 },
]

var _time := 0.0
var _hoppers: Array[Dictionary] = []

var _goblin_root: Node2D
var _goblin_sprite: Sprite2D
var _goblin_dir := 1.0

var _player_root: Node2D
var _player_sprite: Sprite2D
var _attack_fx: Sprite2D
var _slime_root: Node2D
var _slime_sprite: Sprite2D
var _smoke: Sprite2D
var _duel_state: int = Duel.WALK_IN
var _duel_t := 0.0
var _slime_t := -1.0   # 史莱姆死亡动画计时，-1 表示没在播
var _slime_alive := false


func _ready() -> void:
	# 让角色按 y 坐标前后遮挡
	y_sort_enabled = true
	for h in HOPPERS:
		_hoppers.append( _make_hopper( h ) )
	_make_goblin()
	_make_duel()


func _process( delta: float ) -> void:
	_time += delta
	for h in _hoppers:
		_update_hopper( h, delta )
	_update_goblin( delta )
	_update_duel( delta )


# ---------------------------------------------------------------- 搭建

func _make_actor( tex: Texture2D, hframes: int, vframes: int, sprite_y: float,
		shadow_color: Color, shadow_scale: float ) -> Dictionary:
	var root := Node2D.new()
	add_child( root )
	var shadow := Sprite2D.new()
	shadow.texture = SHADOW_TEX
	shadow.modulate = shadow_color
	shadow.scale = Vector2( shadow_scale, shadow_scale )
	root.add_child( shadow )
	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.hframes = hframes
	sprite.vframes = vframes
	sprite.position = Vector2( 0, sprite_y )
	root.add_child( sprite )
	return { "root": root, "sprite": sprite, "shadow": shadow }


func _make_hopper( cfg: Dictionary ) -> Dictionary:
	var a := _make_actor( SLIME_TEX, 16, 2, -20.0, Color( 0.76, 0.33, 0.0, 1.0 ), 1.0 )
	var root: Node2D = a["root"]
	root.position = Vector2( cfg["x"], cfg["y"] )
	a["dir"] = cfg["dir"]
	a["t"] = float( cfg["phase"] )
	( a["sprite"] as Sprite2D ).scale.x = -1.0 if cfg["dir"] < 0.0 else 1.0
	return a


func _make_goblin() -> void:
	var a := _make_actor( GOBLIN_TEX, 8, 3, -14.0, Color( 0, 0, 0, 0.59 ), 0.75 )
	_goblin_root = a["root"]
	_goblin_sprite = a["sprite"]
	_goblin_root.position = Vector2( GOBLIN_PATROL.x + 20.0, GOBLIN_LANE_Y )


func _make_duel() -> void:
	# 被砍的史莱姆
	var s := _make_actor( SLIME_TEX, 16, 2, -20.0, Color( 0.76, 0.33, 0.0, 1.0 ), 1.0 )
	_slime_root = s["root"]
	_slime_sprite = s["sprite"]
	_slime_root.position = Vector2( DUEL_SLIME_X, DUEL_LANE_Y + 1.0 )
	_smoke = Sprite2D.new()
	_smoke.texture = SMOKE_TEX
	_smoke.hframes = 6
	_smoke.position = Vector2( 0, -9 )
	_smoke.visible = false
	_slime_root.add_child( _smoke )
	# 主角（脚底原点，精灵 (0,-21)，影子在精灵下方 (0,20)）
	_player_root = Node2D.new()
	add_child( _player_root )
	_player_root.position = Vector2( DUEL_X_HOME, DUEL_LANE_Y )
	_player_sprite = Sprite2D.new()
	_player_sprite.texture = PLAYER_TEX
	_player_sprite.hframes = 16
	_player_sprite.vframes = 8
	_player_sprite.position = Vector2( 0, -21 )
	_player_root.add_child( _player_sprite )
	var shadow := Sprite2D.new()
	shadow.texture = SHADOW_TEX
	shadow.modulate = Color( 0, 0, 0, 0.78 )
	shadow.show_behind_parent = true
	shadow.position = Vector2( 0, 20 )
	_player_sprite.add_child( shadow )
	# 挥剑特效：attack_side 动画里位置 (10,0)、帧 8–11、显示在主角后面
	_attack_fx = Sprite2D.new()
	_attack_fx.texture = ATTACK_TEX
	_attack_fx.hframes = 12
	_attack_fx.position = Vector2( 10, 0 )
	_attack_fx.show_behind_parent = true
	_attack_fx.visible = false
	_player_sprite.add_child( _attack_fx )
	_reset_duel()


# ---------------------------------------------------------------- 横穿的史莱姆

func _update_hopper( h: Dictionary, delta: float ) -> void:
	h["t"] += delta
	var phase := fmod( h["t"], SLIME_CYCLE )
	var sprite: Sprite2D = h["sprite"]
	var root: Node2D = h["root"]
	sprite.frame = 15 if phase < 0.2 else ( 16 if phase < 0.4 else 17 )
	var y_off := -20.0
	if phase >= SLIME_HOP_START:
		var k := ( phase - SLIME_HOP_START ) / ( SLIME_CYCLE - SLIME_HOP_START )
		root.position.x += h["dir"] * SLIME_HOP_SPEED * delta
		y_off -= roundf( sin( k * PI ) * SLIME_HOP_HEIGHT )
	sprite.position.y = y_off
	# 走出一侧后从另一侧重新进入
	if h["dir"] > 0.0 and root.position.x > SCREEN_W + WRAP_MARGIN:
		root.position.x = -WRAP_MARGIN
	elif h["dir"] < 0.0 and root.position.x < -WRAP_MARGIN:
		root.position.x = SCREEN_W + WRAP_MARGIN


# ---------------------------------------------------------------- 哥布林巡逻

func _update_goblin( delta: float ) -> void:
	_goblin_root.position.x += _goblin_dir * GOBLIN_SPEED * delta
	if _goblin_root.position.x > GOBLIN_PATROL.y:
		_goblin_dir = -1.0
	elif _goblin_root.position.x < GOBLIN_PATROL.x:
		_goblin_dir = 1.0
	_goblin_sprite.scale.x = -1.0 if _goblin_dir < 0.0 else 1.0
	_goblin_sprite.frame = 20 + int( _time / 0.15 ) % 4


# ---------------------------------------------------------------- 主角砍史莱姆

func _reset_duel() -> void:
	_duel_state = Duel.WALK_IN
	_duel_t = 0.0
	_slime_t = -1.0
	_slime_alive = true
	_player_root.position.x = DUEL_X_HOME
	_player_sprite.scale.x = 1.0
	_attack_fx.visible = false
	_smoke.visible = false
	_slime_root.visible = true
	_slime_sprite.modulate = Color( 1, 1, 1, 0 )   # 淡入出现
	_slime_sprite.position.y = -20.0
	_slime_sprite.scale.x = -1.0   # 面朝主角（左）


func _update_duel( delta: float ) -> void:
	_duel_t += delta
	match _duel_state:
		Duel.WALK_IN:
			_player_root.position.x = minf( _player_root.position.x + DUEL_WALK_SPEED * delta, DUEL_X_FIGHT )
			_walk_frame( _duel_t )
			if _player_root.position.x >= DUEL_X_FIGHT:
				_enter_duel( Duel.SWING )
		Duel.SWING:
			_swing_frame( _duel_t )
			if _slime_alive and _duel_t >= SWING_HIT_TIME:
				_slime_alive = false
				_slime_t = 0.0
			if _duel_t >= 0.8:
				_enter_duel( Duel.WAIT )
		Duel.WAIT:
			_player_sprite.frame = 17
			_attack_fx.visible = false
			if _duel_t >= 1.0:
				_player_sprite.scale.x = -1.0
				_enter_duel( Duel.WALK_BACK )
		Duel.WALK_BACK:
			_player_root.position.x = maxf( _player_root.position.x - DUEL_WALK_SPEED * delta, DUEL_X_HOME )
			_walk_frame( _duel_t )
			if _player_root.position.x <= DUEL_X_HOME:
				_player_sprite.scale.x = 1.0
				_enter_duel( Duel.REST )
		Duel.REST:
			_player_sprite.frame = 17
			if _duel_t >= 0.8:
				_reset_duel()
	_update_duel_slime( delta )


func _enter_duel( state: int ) -> void:
	_duel_state = state
	_duel_t = 0.0


## walk_side：帧 17→20 来回播（ping-pong），每步约 0.1 秒
func _walk_frame( t: float ) -> void:
	var seq: Array[int] = [ 17, 18, 19, 20, 19, 18 ]
	_player_sprite.frame = seq[ int( t / 0.1 ) % seq.size() ]


## attack_side：主角帧 27–29，特效帧 8–11；挥两下，中间停 0.1 秒
func _swing_frame( t: float ) -> void:
	var local := fmod( t, 0.4 )
	if local < 0.3:
		_player_sprite.frame = 27 + clampi( int( local / 0.1 ), 0, 2 )
		_attack_fx.frame = 8 + clampi( int( local / 0.075 ), 0, 3 )
		_attack_fx.visible = true
	else:
		_player_sprite.frame = 29
		_attack_fx.visible = false


func _update_duel_slime( delta: float ) -> void:
	if _slime_t >= 0.0:
		# destroy_side：帧 24,25,26,17,15,24 每 0.05 秒；颜色 红→白，0.25–0.35 淡出；高度小幅弹起
		_slime_t += delta
		var frames: Array[int] = [ 24, 25, 26, 17, 15, 24 ]
		_slime_sprite.frame = frames[ clampi( int( _slime_t / 0.05 ), 0, 5 ) ]
		if _slime_t < 0.2:
			_slime_sprite.modulate = Color( 0.76, 0.0, 0.11 ).lerp( Color.WHITE, _slime_t / 0.2 )
		elif _slime_t < 0.25:
			_slime_sprite.modulate = Color.WHITE
		else:
			_slime_sprite.modulate = Color( 1, 1, 1, clampf( 1.0 - ( _slime_t - 0.25 ) / 0.1, 0.0, 1.0 ) )
		_slime_sprite.position.y = -20.0 - ( 3.0 if _slime_t < 0.25 and _slime_t > 0.05 else 0.0 )
		# 冒烟：destroy_smoke 6 帧，从 0.05 秒起每帧 0.05 秒
		var smoke_t := _slime_t - 0.05
		_smoke.visible = smoke_t >= 0.0 and smoke_t < 0.3
		_smoke.frame = clampi( int( smoke_t / 0.05 ), 0, 5 )
		if _slime_t >= SLIME_DEATH_LEN + 0.04:
			_slime_t = -1.0
			_smoke.visible = false
			_slime_root.visible = false
	elif _slime_alive:
		# 站着晃：idle_side 帧 6–8
		_slime_sprite.frame = 6 + int( _time / 0.2 ) % 3
		var a := minf( _slime_sprite.modulate.a + delta * 2.0, 1.0 )
		_slime_sprite.modulate = Color( 1, 1, 1, a )
