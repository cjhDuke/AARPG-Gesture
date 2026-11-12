extends Node
## 关卡加载：淡出 -> 通知旧关卡释放 -> 换场景 -> 淡入

signal level_load_started
signal level_loaded
signal TileMapBoundsChanged(bounds: Array[Vector2])

var current_tilemap_bounds: Array[Vector2]
var is_loading_level: bool = false
## 命令行用户参数 `-- --practice`：直接进练习场（正式关卡 + 调试面板，跳过 splash 和标题），暂停菜单不显示 TITLE
var practice_mode: bool = OS.get_cmdline_user_args().has("--practice")
## 本次运行已经看过开场 splash：从游戏里回标题时跳过它，直接显示标题菜单
var title_seen: bool = false


func _ready() -> void:
	await get_tree().process_frame
	level_loaded.emit()


func change_tilemap_bounds(bounds: Array[Vector2]) -> void:
	current_tilemap_bounds = bounds
	TileMapBoundsChanged.emit(bounds)


func load_new_level(level_path: String) -> void:
	if is_loading_level:
		return
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
