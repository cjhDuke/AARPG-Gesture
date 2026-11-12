class_name WaveSpawner extends Node2D
## 波次表 + 生成位置。一波的敌人按间隔陆续生成，全部被消灭后发 wave_cleared。

signal enemy_killed
## 敌人被消灭（带上是哪个敌人、致命一击的判定框），先于 enemy_killed / wave_cleared 发出，给掉落用
signal enemy_destroyed_at( enemy : Enemy, hit_box : HitBox )
signal wave_cleared

## 怪物类型名 -> 场景。波次表里的 "enemies" 用这里的名字计数。
const REGISTRY : Dictionary = {
	"slime": preload("res://enemies/slime/slime.tscn"),
	"goblin": preload("res://enemies/goblin/goblin.tscn"),
	"bomb_slime": preload("res://enemies/bomb_slime/bomb_slime.tscn"),
	"shield_goblin": preload("res://enemies/shield_goblin/shield_goblin.tscn"),
	"archer_goblin": preload("res://enemies/archer_goblin/archer_goblin.tscn"),
	"big_slime": preload("res://enemies/big_slime/big_slime.tscn"),
}
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
## 每次 start_wave +1；敌人生成时记下当时的值，只有属于当前波的敌人死亡才扣存活数
## （练习场在两波之间手动生成的怪不会干扰下一波的清波判定）
var _wave_id : int = 0


func _process( delta : float ) -> void:
	if not _running or _queue.is_empty():
		return
	_timer -= delta
	if _timer <= 0.0:
		_timer = _interval
		_spawn( _queue.pop_back() )


## 开始一波。wave 是关卡表里的一项：{ "enemies": { 类型名: 数量 }, "interval": 秒 }
func start_wave( wave : Dictionary ) -> void:
	_queue.clear()
	var enemies : Dictionary = wave["enemies"]
	for type_name : String in enemies:
		for i in int( enemies[type_name] ):
			_queue.append( _resolve_scene( type_name ) )
	_queue.shuffle()
	_interval = float( wave["interval"] )
	_timer = 0.0
	_alive = 0
	_wave_id += 1
	_running = true


## 额外生成一只怪（比如大史莱姆死后分裂）。scene_or_type 可以是 PackedScene 或注册表里的类型名。
## 它计入存活数，没死之前这一波不算清完。要在 enemy_destroyed_at 的处理函数里调用，
## 这样新怪会在波次清空判定之前计入。
func spawn_extra( scene_or_type : Variant, pos : Vector2 ) -> Enemy:
	var enemy : Enemy = _spawn( _resolve_scene( scene_or_type ), pos )
	return enemy


func _resolve_scene( scene_or_type : Variant ) -> PackedScene:
	if scene_or_type is PackedScene:
		return scene_or_type
	assert( REGISTRY.has( scene_or_type ), "未注册的怪物类型：%s" % scene_or_type )
	return REGISTRY[scene_or_type]


## 终止当前波并清掉场上所有敌人
func clear() -> void:
	_running = false
	_queue.clear()
	_alive = 0
	for c in enemy_parent.get_children():
		if c is Enemy:
			c.queue_free()
	_clear_projectiles()


## 清掉场上所有敌方投射物（节点组 enemy_projectile，见 enemy_projectile.gd）
func _clear_projectiles() -> void:
	for n in get_tree().get_nodes_in_group( "enemy_projectile" ):
		n.queue_free()


## 生成一只怪并计入存活数；默认放在边缘随机位置
func _spawn( scene : PackedScene, pos : Variant = null ) -> Enemy:
	var enemy : Enemy = scene.instantiate()
	enemy.set_meta( "wave_id", _wave_id )
	enemy.enemy_destroyed.connect( _on_enemy_destroyed.bind( enemy ) )
	_alive += 1
	# 敌人被打死的回调里（物理查询刷新期间）直接 add_child 会报错，所以统一延后到本帧末加入场景
	_add_enemy.call_deferred( enemy, pos if pos != null else pick_spawn_position() )
	return enemy


func _add_enemy( enemy : Enemy, pos : Vector2 ) -> void:
	if not is_instance_valid( enemy_parent ) or not enemy_parent.is_inside_tree():
		enemy.queue_free()
		return
	enemy_parent.add_child( enemy )
	enemy.global_position = pos


## 练习场调试：这一波正在进行时，立刻清掉场上所有敌人和待生成队列，并按正常路径发 wave_cleared
func debug_clear_wave() -> void:
	if not _running:
		return
	clear()
	_running = false
	wave_cleared.emit()


## 一波是否正在进行（已开始且还没清完）
func is_running() -> bool:
	return _running


## ARENA_RECT 四条边内侧的随机位置，且离主角不少于 MIN_SPAWN_DIST
func pick_spawn_position() -> Vector2:
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
	if enemy.get_meta( "wave_id", -1 ) == _wave_id:
		_alive -= 1
	enemy.on_defeated( self )
	enemy_destroyed_at.emit( enemy, hit_box )
	enemy_killed.emit()
	if _running and _queue.is_empty() and _alive <= 0:
		_running = false
		_clear_projectiles()
		wave_cleared.emit()
