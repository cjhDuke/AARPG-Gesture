class_name Level extends Node2D
## 关卡基类：接管全局主角，关卡卸载时交还

@export var music : AudioStream


func _ready() -> void:
	y_sort_enabled = true
	PlayerManager.set_as_parent( self )
	LevelManager.level_load_started.connect( _free_level )
	AudioManager.play_music( music )


func _free_level() -> void:
	PlayerManager.unparent_player( self )
	queue_free()
