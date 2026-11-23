extends SurvivalHud
## Keep the combat HUD without creating the survival results, settings or ranking UI.

var _lesson: Label
var _prompt: Panel


func _ready() -> void:
	$Root.theme = DungeonTheme.THEME
	result_panel.hide()
	banner_label.hide()
	status_label.text = "TRAINING ROOM"
	var status_frame := _make_frame(Rect2(0, 250, 480, 20))
	gameplay.add_child(status_frame)
	gameplay.move_child(status_frame, status_label.get_index())
	_upgrade_frame = _make_frame(Rect2(4, 216, 248, 33))
	_upgrade_frame.hide()
	gameplay.add_child(_upgrade_frame)

	_prompt = _make_frame(Rect2(48, 207, 384, 37))
	gameplay.add_child(_prompt)
	_lesson = Label.new()
	_lesson.name = "Lesson"
	_lesson.size = _prompt.size
	_lesson.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lesson.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_lesson.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt.add_child(_lesson)


func set_lesson(title: String, hint: String) -> void:
	_lesson.text = "%s\n%s" % [title, hint]
	_prompt.show()


func hide_lesson() -> void:
	_prompt.hide()
