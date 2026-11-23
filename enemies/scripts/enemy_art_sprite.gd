class_name EnemyArtSprite extends Sprite2D
## 映射像素画帧，沿用场景里的动画时长、音效、受击反馈和攻击框轨道。

const DIRECTIONS := [&"down", &"side", &"up"]
const FRAME_TRACK := ^"Sprite2D:frame"
const POSITION_TRACK := ^"Sprite2D:position"

@export var idle_columns := PackedInt32Array([0, 1])
@export var defeat_columns := PackedInt32Array([8, 9, 10])
@export var extra_poses: Dictionary[StringName, int] = {}

static var _libraries: Dictionary[String, AnimationLibrary] = {}


func install(player: AnimationPlayer) -> void:
	var original := player.get_animation_library(&"")
	var key := texture.resource_path + ":" + str(original.get_instance_id())
	if not _libraries.has(key):
		_libraries[key] = _build_library(original)
	player.remove_animation_library(&"")
	player.add_animation_library(&"", _libraries[key])


func show_defeat_start(facing: String) -> void:
	frame_coords = Vector2i(defeat_columns[0], DIRECTIONS.find(StringName(facing)))


func _build_library(original: AnimationLibrary) -> AnimationLibrary:
	var library := AnimationLibrary.new()
	for name in original.get_animation_list():
		var clip := original.get_animation(name).duplicate() as Animation
		var action := String(name).get_slice("_", 0)
		var row := DIRECTIONS.find(StringName(String(name).get_slice("_", 1)))
		match action:
			"idle":
				_replace_frames(clip, row, idle_columns)
			"walk", "chase":
				_replace_frames(clip, row, PackedInt32Array([2, 3, 4, 5]))
			"stun":
				_replace_frames(clip, row, PackedInt32Array([6, 7, 7, 7]))
			"destroy":
				_replace_frames(clip, row, defeat_columns)
		library.add_animation(name, clip)

	for pose in extra_poses:
		for row in DIRECTIONS.size():
			var clip := Animation.new()
			_replace_frames(clip, row, PackedInt32Array([extra_poses[pose]]))
			library.add_animation(StringName("%s_%s" % [pose, DIRECTIONS[row]]), clip)
	return library


func _replace_frames(clip: Animation, row: int, columns: PackedInt32Array) -> void:
	var track := clip.find_track(FRAME_TRACK, Animation.TYPE_VALUE)
	if track < 0:
		track = clip.add_track(Animation.TYPE_VALUE)
		clip.track_set_path(track, FRAME_TRACK)
	for i in range(clip.track_get_key_count(track) - 1, -1, -1):
		clip.track_remove_key(track, i)
	clip.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
	for i in columns.size():
		clip.track_insert_key(track, clip.length * i / columns.size(), row * hframes + columns[i])

	# 史莱姆的新帧已包含跳跃位移，保留旧轨道的原点。
	var position_track := clip.find_track(POSITION_TRACK, Animation.TYPE_VALUE)
	if position_track >= 0:
		for i in range(clip.track_get_key_count(position_track) - 1, 0, -1):
			clip.track_remove_key(position_track, i)
