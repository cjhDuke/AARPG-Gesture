extends CanvasLayer

@onready var animation_player: AnimationPlayer = $Control/AnimationPlayer


## 立刻停掉淡入淡出并让画面完全显示（遮罩全透明）。重开 / 切关被打断后调用，防止停在黑屏。
## 被打断的 fade_* 协程不会再收到 animation_finished，调用方应靠 _run_id 之类的标记作废它们
func reset() -> void:
	animation_player.stop()
	$Control/ColorRect.color = Color( 0, 0, 0, 0 )


func fade_out() -> bool:
	animation_player.play("fade_out")
	await animation_player.animation_finished
	return true

func fade_in() -> bool:
	animation_player.play("fade_in")
	await animation_player.animation_finished
	return true
