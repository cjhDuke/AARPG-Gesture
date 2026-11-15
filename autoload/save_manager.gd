extends Node

const SAVE_PATH := "user://checkpoint.json"
const SAVE_DIR := "user://saves"
const LEGACY_ID := "legacy_checkpoint"
const LEGACY_ARCHIVE := "user://checkpoint.imported.json"
const VERSION := 2
const ARENA_PATH := "res://levels/survival/survival_arena.tscn"
const MAX_FILE_SIZE := 65536

var last_error: String = ""
var _pending: Dictionary = {}


func list_saves() -> Array[Dictionary]:
	last_error = ""
	_migrate_legacy()
	var result: Array[Dictionary] = []
	var directory := DirAccess.open(SAVE_DIR)
	if directory == null:
		if DirAccess.dir_exists_absolute(SAVE_DIR):
			_fail("Cannot read the save folder.")
	else:
		for filename in directory.get_files():
			if filename.ends_with(".json") and _safe_id(filename.get_basename()):
				var id := filename.get_basename()
				result.append(_entry(id, _read_save(id)))
	if FileAccess.file_exists(SAVE_PATH) and not FileAccess.file_exists(_path(LEGACY_ID)):
		if LevelManager.practice_mode:
			var legacy := _read_file(SAVE_PATH)
			if not legacy.has("error") and _integer(legacy.get("version"), 1, 1):
				legacy["name"] = "Old checkpoint"
				legacy["saved_unix"] = 0.0
				result.append(_entry(LEGACY_ID, legacy))
			else:
				result.append(_entry(LEGACY_ID, {"error": "Old save is damaged or incompatible."}))
		else:
			result.append(_entry(LEGACY_ID, {"error": last_error if not last_error.is_empty() else "Could not import the old save."}))
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		if left["order"] == right["order"]:
			return left["id"] < right["id"]
		return left["order"] > right["order"])
	return result


func create_save(checkpoint: Dictionary, name: String) -> String:
	last_error = ""
	if not _can_write_checkpoint(checkpoint):
		return ""
	var id := Crypto.new().generate_random_bytes(16).hex_encode()
	if id.is_empty() or FileAccess.file_exists(_path(id)):
		_fail("Cannot create a new save. Please try again.")
		return ""
	var now := Time.get_datetime_string_from_system(false, true)
	var record := {
		"version": VERSION,
		"id": id,
		"name": _save_name(checkpoint, name),
		"created_at": now,
		"saved_at": now,
		"saved_unix": Time.get_unix_time_from_system(),
		"checkpoint": checkpoint,
	}
	return id if _write_record(id, record) else ""


func overwrite_save(id: String, checkpoint: Dictionary) -> bool:
	last_error = ""
	if not _can_write_checkpoint(checkpoint):
		return false
	var record := _read_save(id)
	if record.has("error"):
		return _fail(record["error"])
	record["checkpoint"] = checkpoint
	record["saved_at"] = Time.get_datetime_string_from_system(false, true)
	record["saved_unix"] = Time.get_unix_time_from_system()
	return _write_record(id, record)


func rename_save(id: String, name: String) -> bool:
	last_error = ""
	if not _can_manage():
		return false
	var record := _read_save(id)
	if record.has("error"):
		return _fail(record["error"])
	record["name"] = _save_name(record["checkpoint"], name)
	return _write_record(id, record)


func delete_save(id: String) -> bool:
	last_error = ""
	if not _can_manage() or not _safe_id(id):
		return false
	if id == LEGACY_ID and FileAccess.file_exists(SAVE_PATH):
		if FileAccess.file_exists(_path(id)):
			_migrate_legacy()
			if FileAccess.file_exists(SAVE_PATH):
				return _fail("Cannot finish importing the old save. Please retry.")
		else:
			if DirAccess.remove_absolute(SAVE_PATH) != OK:
				return _fail("Cannot delete the old save.")
			return true
	if not FileAccess.file_exists(_path(id)):
		return _fail("This save no longer exists.")
	if DirAccess.remove_absolute(_path(id)) != OK:
		return _fail("Cannot delete this save. Please retry.")
	return true


func _write_record(id: String, record: Dictionary) -> bool:
	if DirAccess.make_dir_recursive_absolute(SAVE_DIR) != OK:
		return _fail("Cannot create the save folder.")
	var temporary := _path(id) + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _fail("Cannot write save. Previous save is safe.")
	file.store_string(JSON.stringify(record))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		DirAccess.remove_absolute(temporary)
		return _fail("Cannot write save. Previous save is safe.")
	if DirAccess.rename_absolute(temporary, _path(id)) != OK:
		DirAccess.remove_absolute(temporary)
		return _fail("Cannot replace save. Previous save is safe.")
	return true


func load_game(id: String) -> bool:
	last_error = ""
	if not _can_manage():
		return false
	var record := _read_save(id)
	if not record.has("checkpoint"):
		return _fail(record["error"])
	if not ResourceLoader.exists(ARENA_PATH):
		return _fail("Cannot open the saved level.")
	_pending = record["checkpoint"].duplicate(true)
	LevelManager.load_new_level(ARENA_PATH)
	return true


func take_pending_checkpoint() -> Dictionary:
	var result := _pending
	_pending = {}
	return result


func _read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "This save no longer exists."}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "Cannot read saved game."}
	if file.get_length() > MAX_FILE_SIZE:
		return {"error": "Saved game is damaged."}
	var contents := file.get_as_text()
	var error := file.get_error()
	file.close()
	if error != OK:
		return {"error": "Cannot read saved game."}
	var parser := JSON.new()
	if parser.parse(contents) != OK:
		return {"error": "Saved game is damaged."}
	var record: Variant = parser.data
	if not record is Dictionary:
		return {"error": "Saved game is damaged."}
	if not record.get("saved_at") is String or record["saved_at"].length() > 32 or not _valid_checkpoint(record.get("checkpoint")):
		return {"error": "Saved game is damaged or incompatible."}
	return record


func _read_save(id: String) -> Dictionary:
	if not _safe_id(id):
		return {"error": "Invalid save selection."}
	var record := _read_file(_path(id))
	if record.has("error"):
		return record
	if not _integer(record.get("version"), VERSION, VERSION):
		return {"error": "Save version is incompatible."}
	if record.get("id") != id or not record.get("name") is String:
		return {"error": "Saved game is damaged."}
	if record["name"].is_empty() or record["name"].length() > 24 or not record.get("created_at") is String or record["created_at"].length() > 32 or not _number(record.get("saved_unix"), 0.0, 100000000000.0):
		return {"error": "Save details are damaged."}
	return record


func _migrate_legacy() -> void:
	if LevelManager.practice_mode or not FileAccess.file_exists(SAVE_PATH):
		return
	if not FileAccess.file_exists(_path(LEGACY_ID)):
		var record := _read_file(SAVE_PATH)
		if record.has("error"):
			_fail(record["error"])
			return
		if not _integer(record.get("version"), 1, 1):
			_fail("Old save version is incompatible.")
			return
		record["version"] = VERSION
		record["id"] = LEGACY_ID
		record["name"] = "Imported checkpoint"
		record["created_at"] = record["saved_at"]
		record["saved_unix"] = 0.0
		if not _write_record(LEGACY_ID, record):
			return
	if DirAccess.rename_absolute(SAVE_PATH, LEGACY_ARCHIVE) != OK:
		_fail("Old save imported; could not archive the original.")


func _entry(id: String, record: Dictionary) -> Dictionary:
	if record.has("error"):
		return {"id": id, "name": "Old checkpoint" if id == LEGACY_ID else id.left(24), "progress": "UNAVAILABLE", "time": "", "valid": false, "message": record["error"], "order": 0.0}
	var data: Dictionary = record["checkpoint"]
	var levels: Dictionary = data["upgrades"]
	var upgrades: Array[String] = []
	for upgrade in Upgrades.all_ids():
		if levels.has(upgrade):
			upgrades.append("%s LV %d" % [Upgrades.display_name(upgrade), int(levels[upgrade])])
	var max_hp := Player.BASE_MAX_HP + int(Upgrades.param("heart", int(levels.get("heart", 0)), "hp", 0))
	return {
		"id": id, "name": record["name"], "progress": _progress(data), "time": record["saved_at"],
		"valid": true, "message": "", "order": record["saved_unix"],
		"hp": "%d / %d" % [int(data["hp"]), max_hp], "psi": "%d%%" % roundi(float(data["psi"]) * 100.0),
		"apples": int(data["loot"]["bag_apples"]), "kills": int(data["kills"]),
		"upgrades": "\n".join(upgrades) if not upgrades.is_empty() else "NONE YET",
	}


func _can_manage() -> bool:
	if LevelManager.practice_mode:
		return _fail("Save changes and loading are disabled in practice mode.")
	if LevelManager.is_loading_level:
		return _fail("Please wait for the level to finish loading.")
	return true


func _can_write_checkpoint(checkpoint: Dictionary) -> bool:
	if not _can_manage():
		return false
	var scene := get_tree().current_scene
	if scene == null or not scene.has_method("can_save_checkpoint") or not scene.can_save_checkpoint():
		return _fail("Save is available during a wave or Boss battle.")
	if not _valid_checkpoint(checkpoint):
		return _fail("Checkpoint is invalid. Nothing was saved.")
	return true


func _safe_id(id: String) -> bool:
	if id.is_empty() or id.length() > 64:
		return false
	for character in id:
		if not "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".contains(character):
			return false
	return true


func _path(id: String) -> String:
	return SAVE_DIR.path_join(id + ".json")


func _save_name(checkpoint: Dictionary, name: String) -> String:
	var cleaned := name.replace("\n", " ").replace("\r", " ").replace("\t", " ").strip_edges().left(24)
	if not cleaned.is_empty():
		return cleaned
	return "Stage %d %s %s" % [int(checkpoint["stage"]) + 1, "Boss" if checkpoint["kind"] == "boss" else "Wave %d" % int(checkpoint["wave"]), Time.get_time_string_from_system().left(5)]


func _valid_checkpoint(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var data: Dictionary = value
	if not _integer(data.get("stage"), 0, StageData.stage_count() - 1):
		return false
	var stage_data := StageData.get_stage(int(data["stage"]))
	var kind: String = stage_data.get("type", "waves")
	if data.get("stage_name") != stage_data["name"] or data.get("kind") != kind:
		return false
	var waves: int = 1 if kind == "boss" else stage_data["waves"].size()
	if not _integer(data.get("wave"), 1, waves) or not _integer(data.get("kills"), 0, 1000000000):
		return false
	if not data.get("upgrades") is Dictionary:
		return false
	var levels: Dictionary = data["upgrades"]
	for id in levels:
		if not id is String or not Upgrades.pool_ids().has(id) or not _integer(levels[id], 1, Upgrades.max_level(id)):
			return false
	var max_hp := Player.BASE_MAX_HP + int(Upgrades.param("heart", int(levels.get("heart", 0)), "hp", 0))
	if not _integer(data.get("hp"), 1, max_hp) or not _number(data.get("psi"), 0.0, 1.0):
		return false
	var loot: Variant = data.get("loot")
	if not loot is Dictionary or not _integer(loot.get("bag_apples"), 0, LootDropper.BAG_CAPACITY) or not _integer(loot.get("kills_since_apple"), 0, LootDropper.APPLE_PITY_KILLS - 1):
		return false
	# 旧版本 1/2 检查点没有药水库存，按 0 恢复。
	if not _integer(loot.get("bag_potions", 0), 0, LootDropper.BAG_CAPACITY):
		return false
	if not _number(loot.get("eat_timer"), 0.0, LootDropper.EAT_DELAY):
		return false
	var picked: Variant = loot.get("picked")
	if not picked is Array or picked.size() != 3:
		return false
	for count in picked:
		if not _integer(count, 0, 1000000000):
			return false
	return true


func _number(value: Variant, minimum: float, maximum: float) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= minimum and float(value) <= maximum


func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return _number(value, minimum, maximum) and float(value) == floorf(float(value))


func _progress(data: Dictionary) -> String:
	return "STAGE %d / BOSS" % (int(data["stage"]) + 1) if data["kind"] == "boss" else "STAGE %d / WAVE %d" % [int(data["stage"]) + 1, int(data["wave"])]


func _fail(message: String) -> bool:
	last_error = message
	return false
