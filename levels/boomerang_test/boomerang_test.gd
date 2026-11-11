class_name BoomerangTest extends Level
## 回旋镖练习场（调试工具，长期保留）：和生存关卡同一个房间，主角站在房间中心不能走位、不自动挥剑，
## 只练"握拳放回旋镖、移动、张开收回"。场上 3 只不动的史莱姆当靶子，被打死后约 2 秒在原位重新生成。
## 调试面板（boomerang_test_panel.gd）显示识别状态和事件日志，并可在运行时调参。
## 入口：和正式游戏分开，命令行 `AARPG-Gesture.exe -- --practice`（根目录 run_practice.bat），
## 或在编辑器里直接运行本场景；Esc 暂停菜单只有 RESUME / QUIT。
## G 键切换"手影"（hand_ghost.gd）：OFF / HAND / CAMERA。

const SLIME : PackedScene = preload( "res://enemies/slime/slime.tscn" )
## 靶子的固定位置（世界坐标）：避开左右两侧的调试面板，离主角都有一段距离
const TARGET_HOMES : Array[Vector2] = [
	Vector2( 170, 100 ), Vector2( 342, 100 ), Vector2( 256, 215 ),
]
## 靶子被打死后多久在原位重新生成（秒）
const RESPAWN_DELAY : float = 2.0
## 靶子被击退后回到原位的速度（像素/秒）
const HOME_SPEED : float = 90.0

@onready var controller : HandController = $HandController

var _player : Player
## 每个位置当前的靶子（被打死、等待重生时为 null）
var _targets : Array[Enemy] = []


func _ready() -> void:
	super._ready()
	_player = PlayerManager.player
	# 镜头固定在房间中心，和生存关卡一致
	var camera : Camera2D = _player.get_node( "Camera2D" )
	camera.top_level = true
	camera.global_position = HandController.CENTER

	PlayerManager.reset_player()
	_player.can_move = true
	_player.global_position = HandController.CENTER
	# 主角站桩，只练回旋镖
	controller.walk_enabled = false
	controller.auto_attack_enabled = false
	controller.enabled = true
	controller.reset()

	# 手影：画在地板之上、角色之下
	var ghost := HandGhost.new()
	ghost.name = "HandGhost"
	add_child( ghost )

	_targets.resize( TARGET_HOMES.size() )
	for i in TARGET_HOMES.size():
		_spawn_target( i )


func _free_level() -> void:
	controller.release_player()
	var camera : Camera2D = _player.get_node( "Camera2D" )
	camera.top_level = false
	camera.position = Vector2.ZERO
	super._free_level()


func _process( delta : float ) -> void:
	# 被击退的靶子（回到逼近状态后）慢慢走回原位
	for i in _targets.size():
		var t := _targets[i]
		if is_instance_valid( t ) and t.state_machine.current_state is EnemyStateApproach:
			t.global_position = t.global_position.move_toward( TARGET_HOMES[i], HOME_SPEED * delta )


func _spawn_target( index : int ) -> void:
	var enemy : Enemy = SLIME.instantiate()
	# 逼近速度设成 0：靶子站着不动，被击退后由 _process 拉回原位
	( enemy.get_node( "EnemyStateMachine/Approach" ) as EnemyStateApproach ).speed = 0.0
	enemy.enemy_destroyed.connect( _on_target_destroyed.bind( index ) )
	add_child( enemy )
	enemy.global_position = TARGET_HOMES[index]
	_targets[index] = enemy


func _on_target_destroyed( _hit_box : HitBox, index : int ) -> void:
	_targets[index] = null
	get_tree().create_timer( RESPAWN_DELAY ).timeout.connect( _spawn_target.bind( index ) )
