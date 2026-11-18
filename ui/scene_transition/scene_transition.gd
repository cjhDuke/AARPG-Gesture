extends CanvasLayer

## 一次淡入淡出结束（动画正常播完，或被 reset() 打断）时发出。fade_* 等的是它而不是 animation_finished，
## 这样被 reset() / 另一次 fade 打断时等待者也会醒来，不会永远挂起
signal settled

@onready var animation_player: AnimationPlayer = $Control/AnimationPlayer


func _ready() -> void:
	animation_player.animation_finished.connect( _on_animation_finished )


func _on_animation_finished( anim : StringName ) -> void:
	if anim == &"fade_in":
		$Control/ColorRect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	settled.emit()


## 立刻停掉淡入淡出并让画面完全显示（遮罩全透明）。重开 / 切关被打断后调用，防止停在黑屏。
## 正在等待的 fade_* 会因此提前醒来，调用方应靠 _run_id 之类的标记判断自己是否已被作废
func reset() -> void:
	animation_player.stop()
	$Control/ColorRect.color = Color( 0, 0, 0, 0 )
	$Control/ColorRect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	settled.emit()


func fade_out() -> bool:
	$Control/ColorRect.mouse_filter = Control.MOUSE_FILTER_STOP
	animation_player.play("fade_out")
	await settled
	return true

func fade_in() -> bool:
	$Control/ColorRect.mouse_filter = Control.MOUSE_FILTER_STOP
	animation_player.play("fade_in")
	await settled
	return true
