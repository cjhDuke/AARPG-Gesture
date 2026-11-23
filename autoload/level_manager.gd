extends Node
## 关卡加载：淡出 -> 通知旧关卡释放 -> 换场景 -> 淡入

signal level_load_started
signal level_loaded
signal TileMapBoundsChanged(bounds: Array[Vector2])

const START_LEVEL := "res://levels/survival/survival_arena.tscn"
const TUTORIAL_LEVEL := "res://levels/tutorial/tutorial_room.tscn"

var current_tilemap_bounds: Array[Vector2]
var is_loading_level: bool = false
var practice_mode: bool = false
## 本机试玩入口。正常 START 仍由账号状态决定。
var tutorial_preview := OS.get_cmdline_user_args().has("--tutorial-preview")
var _tutorial_owner_id := ""


func _ready() -> void:
	await get_tree().process_frame
	level_loaded.emit()


func change_tilemap_bounds(bounds: Array[Vector2]) -> void:
	current_tilemap_bounds = bounds
	TileMapBoundsChanged.emit(bounds)


func start_new_game() -> void:
	if is_loading_level:
		return
	if practice_mode or (not tutorial_preview and not AuthManager.should_start_tutorial()):
		load_new_level(START_LEVEL)
		return
	_tutorial_owner_id = "" if tutorial_preview else AuthManager.user_id
	load_new_level(TUTORIAL_LEVEL)


func finish_tutorial(state: String) -> void:
	var scene := get_tree().current_scene
	if is_loading_level or scene == null or scene.scene_file_path != TUTORIAL_LEVEL or state not in ["completed", "skipped"]:
		return
	if not _tutorial_owner_id.is_empty():
		AuthManager.finish_tutorial(_tutorial_owner_id, state)
	load_new_level(START_LEVEL)


func load_new_level(level_path: String) -> void:
	if is_loading_level:
		return
	if level_path != TUTORIAL_LEVEL:
		_tutorial_owner_id = ""
	is_loading_level = true
	get_tree().paused = true

	await SceneTransition.fade_out()
	level_load_started.emit()
	await get_tree().process_frame
	get_tree().change_scene_to_file(level_path)
	await SceneTransition.fade_in()

	get_tree().paused = false
	await get_tree().process_frame
	is_loading_level = false
	level_loaded.emit()
