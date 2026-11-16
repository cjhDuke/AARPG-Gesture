extends SceneTree
## Local safety regressions. Requires an isolated APPDATA path containing .stage1_checks.
var save: Node
var cloud: Node
var levels: Node
var checks := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if ok: print("PASS: ", label)
	else:
		failed += 1
		push_error("FAIL: " + label)

func fixture(id: String, name: String = "Storage check") -> Dictionary:
	return {"version":2,"id":id,"name":name,"created_at":"2026-11-16 22:00:00","saved_at":"2026-11-16 22:00:00","saved_unix":1794850000.1234567,
		"checkpoint":{"stage":0,"stage_name":"DUNGEON","kind":"waves","wave":1,"hp":6,"psi":0.75,"upgrades":{},"kills":0,
		"loot":{"bag_apples":1,"bag_potions":2,"kills_since_apple":0,"eat_timer":0,"picked":[1,2,3]}}}

func _run() -> void:
	if not OS.get_user_data_dir().contains(".stage1_checks"):
		push_error("Unsafe test data directory")
		quit(1)
		return
	save = root.get_node("SaveManager")
	cloud = root.get_node("CloudSaveManager")
	levels = root.get_node("LevelManager")
	cloud.set_process(false)
	change_scene_to_file("res://ui/title/title_scene.tscn")
	await process_frame
	await process_frame
	var owner_a := "11111111-1111-4111-8111-111111111111"
	var owner_b := "22222222-2222-4222-8222-222222222222"
	var id := "a".repeat(32)
	var copy_id := "b".repeat(32)
	check(save.set_profile(owner_a), "account profile A selected at title")
	var record := fixture(id)
	check(save.apply_cloud_record(id, JSON.stringify(record), ""), "valid cloud payload applies to empty cache")
	var original: String = FileAccess.get_file_as_string(save.save_directory().path_join(id+".json"))
	var hash: String = save.record_hash(id)
	check(not save.apply_cloud_record(id, JSON.stringify(fixture(id,"Changed")), "stale-hash"), "stale local hash blocks overwrite")
	for field in ["checkpoint", "saved_at", "version"]:
		var bad := record.duplicate(true)
		bad[field] = null
		check(not save.apply_cloud_record(id, JSON.stringify(bad), hash), "bad " + field + " rejected before write")
	check(FileAccess.get_file_as_string(save.save_directory().path_join(id+".json")) == original, "invalid or stale downloads preserve original bytes")
	check(save.delete_save(id) and save.deleted_ids().has(id), "account deletion creates recoverable marker")
	check(save.read_record(id).has("error") and not save.read_deleted_record(id).has("error"), "deletion moves payload to backup atomically")
	check(save.copy_record(id,copy_id), "deleted branch can be copied under a fresh ID")
	check(save.clear_deleted_marker(id) and save.clear_deleted_marker(id), "delete acknowledgement is idempotent")
	check(save.set_profile(owner_b) and save.list_saves().is_empty(), "account B never sees account A cache")
	check(not save.set_profile("../../outside") and save.profile_id == owner_b, "invalid owner cannot escape profile root")
	check(save.apply_cloud_record(id, JSON.stringify(record), ""), "same save ID is scoped independently in account B")
	levels.practice_mode = true
	check(not save.apply_cloud_record(id, JSON.stringify(record), save.record_hash(id)) and not save.remove_cloud_record(id, save.record_hash(id)), "practice blocks cache downloads and deletions")
	check(not save.copy_record(id,copy_id), "practice blocks conflict copies")
	levels.practice_mode = false
	cloud.owner_id = owner_b
	cloud._state = {"version":1,"records":{},"imports":{},"last_sync":""}
	cloud._scan_local()
	var first: Dictionary = cloud._state.records[id].op.duplicate(true)
	check(save.rename_save(id,"Changed during upload"), "local edit can occur while earlier operation is pending")
	check(cloud._state.records[id].op.body.operation_id == first.body.operation_id and cloud._state.records[id].op.body.record.name == "Storage check", "in-flight retry keeps its immutable operation ID and payload")
	var context := {"epoch":cloud._epoch,"owner":owner_b,"nonce":"fake-ack","kind":"put","id":id,"op":first}
	cloud._current = context.duplicate()
	var metadata := {"save_id":id,"revision":1,"deleted":false,"content_hash":"f".repeat(64),"updated_at":1794850000,"device_id":"11111111-1111-4111-8111-111111111111","summary":{}}
	cloud._on_response(HTTPRequest.RESULT_SUCCESS,200,PackedStringArray(),JSON.stringify(metadata).to_utf8_buffer(),context)
	var next: Dictionary = cloud._state.records[id].op
	check(int(next.body.base_revision) == 1 and next.body.operation_id != first.body.operation_id and next.body.record.name == "Changed during upload", "acknowledgement queues later edit instead of clearing it")
	var state: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(cloud._state_path()))
	check(state.records[id].op.body.operation_id == next.body.operation_id, "next operation persists before any network transmission")
	var old_context := {"epoch":-1,"owner":owner_a,"nonce":"old-request","kind":"get","id":id}
	var before: String = save.record_hash(id)
	cloud._on_response(HTTPRequest.RESULT_SUCCESS,200,PackedStringArray(),JSON.stringify(metadata).to_utf8_buffer(),old_context)
	check(save.record_hash(id) == before and save.profile_id == owner_b, "stale callback from prior account cannot write current cache")
	print("CLOUD_STORAGE_CHECKS passed=%d total=%d" % [checks-failed,checks])
	quit(0 if failed == 0 else 1)
