class_name PlayerAbilities extends Node

const BOOMERANG: PackedScene = preload("res://player/boomerang.tscn")

enum abilities {BOOMERANG, GRAPPLE}

var selected_ability = abilities.BOOMERANG
var player: Player
var boomerang_instance: Boomerang = null

func _ready() -> void:
	player = PlayerManager.player


## 是否已有回旋镖在场上（飞出或返回中）
func has_boomerang() -> bool:
	return is_instance_valid( boomerang_instance ) and not boomerang_instance.is_queued_for_deletion()


## 起飞一个受控回旋镖；已有实例时返回 null
func start_guided( dir: Vector2 ) -> Boomerang:
	if has_boomerang():
		return null
	var b := BOOMERANG.instantiate() as Boomerang
	player.add_sibling( b )
	b.global_position = player.global_position
	b.launch_guided( dir )
	boomerang_instance = b
	return b


## 松开受控回旋镖：转入返回状态，飞回主角后自行销毁
func release_guided() -> void:
	if has_boomerang():
		boomerang_instance.release()


## 重新抓住正在返回的回旋镖（场上有且处于返回状态才成功），成功返回该实例，否则 null
func regrab_guided() -> Boomerang:
	if has_boomerang() and boomerang_instance.regrab():
		return boomerang_instance
	return null
