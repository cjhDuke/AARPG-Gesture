class_name WaveSpawner extends Node2D
## 波次表 + 生成位置。一波的敌人按间隔陆续生成，全部被消灭后发 wave_cleared。

signal enemy_killed
## 敌人被消灭（带上是哪个敌人、致命一击的判定框），先于 enemy_killed / wave_cleared 发出，给掉落用
signal enemy_destroyed_at( enemy : Enemy, hit_box : HitBox )
signal wave_cleared

const SLIME : PackedScene = preload("res://enemies/slime/slime.tscn")
const GOBLIN : PackedScene = preload("res://enemies/goblin/goblin.tscn")

## 波次表（想调难度只改这里）：史莱姆数、哥布林数、生成间隔（秒）
const WAVES : Array[Dictionary] = [
	{ "slimes": 5, "goblins": 0, "interval": 1.3 },
	{ "slimes": 7, "goblins": 1, "interval": 1.1 },
	{ "slimes": 7, "goblins": 3, "interval": 1.0 },
	{ "slimes": 8, "goblins": 5, "interval": 0.9 },
	{ "slimes": 10, "goblins": 7, "interval": 0.8 },
]
## 生成位置离主角至少这么远（像素），最多重试 SPAWN_TRIES 次
const MIN_SPAWN_DIST : float = 110.0
const SPAWN_TRIES : int = 8

## 敌人加到父节点（关卡根）下，和主角同层才能一起按 y 排序。本节点需放在原点。
@onready var enemy_parent : Node = get_parent()

var _queue : Array[PackedScene] = []
var _interval : float = 1.0
var _timer : float = 0.0
var _alive : int = 0
var _running : bool = false


func _process( delta : float ) -> void:
	if not _running or _queue.is_empty():
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = _interval
		_spawn( _queue.pop_back() )


## index 从 0 开始
func start_wave( index : int ) -> void:
	var wave : Dictionary = WAVES[index]
	_queue.clear()
	for i in int( wave["slimes"] ):
		_queue.append( SLIME )
	for i in int( wave["goblins"] ):
		_queue.append( GOBLIN )
	_queue.shuffle()
	_interval = float( wave["interval"] )
	_timer = 0.0
	_alive = 0
	_running = true


## 终止当前波并清掉场上所有敌人
func clear() -> void:
	_running = false
	_queue.clear()
	_alive = 0
	for c in enemy_parent.get_children():
		if c is Enemy:
			c.queue_free()


func _spawn( scene : PackedScene ) -> void:
	var enemy : Enemy = scene.instantiate()
	enemy.enemy_destroyed.connect( _on_enemy_destroyed.bind( enemy ) )
	enemy_parent.add_child( enemy )
	enemy.global_position = _pick_spawn_position()
	_alive += 1


## ARENA_RECT 四条边内侧的随机位置，且离主角不少于 MIN_SPAWN_DIST
func _pick_spawn_position() -> Vector2:
	var rect : Rect2 = HandController.ARENA_RECT
	var player_pos : Vector2 = PlayerManager.player.global_position
	var pos := rect.position
	for i in SPAWN_TRIES:
		match randi() % 4:
			0: pos = Vector2( randf_range( rect.position.x, rect.end.x ), rect.position.y )
			1: pos = Vector2( randf_range( rect.position.x, rect.end.x ), rect.end.y )
			2: pos = Vector2( rect.position.x, randf_range( rect.position.y, rect.end.y ) )
			_: pos = Vector2( rect.end.x, randf_range( rect.position.y, rect.end.y ) )
		if pos.distance_to( player_pos ) >= MIN_SPAWN_DIST:
			break
	return pos


func _on_enemy_destroyed( hit_box : HitBox, enemy : Enemy ) -> void:
	_alive -= 1
	enemy_destroyed_at.emit( enemy, hit_box )
	enemy_killed.emit()
	if _queue.is_empty() and _alive <= 0:
		_running = false
		wave_cleared.emit()
