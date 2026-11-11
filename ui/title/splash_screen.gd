extends Control

signal finished

@onready var animation_player: AnimationPlayer = $MyLogo/AnimationPlayer

func _ready() -> void:
	# 练习模式：标题场景会立刻换走，不播 splash（免得漏出一帧音效）
	if LevelManager.practice_mode:
		return
	animation_player.animation_finished.connect(_on_animation_finished)
	if animation_player.has_animation("splash"):
		animation_player.play("splash")
	else:
		finished.emit()
	
func _on_animation_finished(_name: String) -> void:
	finished.emit()
