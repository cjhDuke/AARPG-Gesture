class_name WaveSpawner extends Node2D
## 波次表 + 四个生成点。一波的敌人按间隔陆续生成，全部被消灭后发 wave_cleared。

signal enemy_killed
signal wave_cleared

const SLIME : PackedScene = preload("res://Enemies/Slime/slime.tscn")
const GOBLIN : PackedScene = preload("res://Enemies/Goblin/goblin.tscn")

## 波次表（想调难度只改这里）：史莱姆数、哥布林数、生成间隔（秒）
const WAVES : Array[Dictionary] = [
	{ "slimes": 4, "goblins": 0, "interval": 1.5 },
	{ "slimes": 6, "goblins": 0, "interval": 1.2 },
	{ "slimes": 5, "goblins": 2, "interval": 1.2 },
	{ "slimes": 6, "goblins": 4, "interval": 1.0 },
	{ "slimes": 8, "goblins": 6, "interval": 0.9 },
]

## 敌人加到父节点（关卡根）下，和主角同层才能一起按 y 排序。
## 生成点是本节点下的 Marker2D 子节点，本节点需放在原点。
@onready var enemy_parent : Node = get_parent()
@onready var spawn_points : Array[Node] = get_children().filter( func( n ): return n is Marker2D )

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
	enemy.enemy_destroyed.connect( _on_enemy_destroyed )
	enemy_parent.add_child( enemy )
	enemy.global_position = spawn_points.pick_random().global_position
	_alive += 1


func _on_enemy_destroyed( _hit_box : HitBox ) -> void:
	_alive -= 1
	enemy_killed.emit()
	if _queue.is_empty() and _alive <= 0:
		_running = false
		wave_cleared.emit()
