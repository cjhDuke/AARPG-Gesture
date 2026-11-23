extends Level

enum Step { MOVE, MELEE, RANG, RECALL, GEM, CHEST, PICKUPS, APPLE, POTION, CHOOSE, TRY_UPGRADE }

const TITLE_SCENE := "res://ui/title/title_scene.tscn"
const SLIME := preload("res://enemies/slime/slime.tscn")
const TARGET_SCRIPT := preload("res://levels/tutorial/tutorial_target.gd")
const MOVE_GOAL := Vector2(190, 144)
const MELEE_POS := Vector2(240, 144)
const RANG_POS := Vector2(310, 144)
const CHEST_POS := Vector2(250, 179)
const MOVE_RADIUS := 14.0
const POOL_TRIAL_TIME := 3.2
const UPGRADES: Array[String] = ["pierce", "pool", "blast"]
const PROMPTS := {
	Step.MOVE: ["1 / 6   MOVE", "Open hand or WASD / arrows. Reach the ring."],
	Step.MELEE: ["2 / 6   MELEE", "Move close for auto-slash, or press J / Z."],
	Step.RANG: ["3 / 6   BOOMERANG", "Hold a fist or L. Aim at the slime with hand or arrows."],
	Step.RECALL: ["3 / 6   RECALL", "Open your hand or release L to bring the rang back."],
	Step.GEM: ["3 / 6   PSI GEM", "Walk over the gem or sweep it up with your rang."],
	Step.CHEST: ["4 / 6   CHEST", "Walk up to the chest to open it."],
	Step.PICKUPS: ["4 / 6   COLLECT", "Pick up both the apple and the potion."],
	Step.APPLE: ["5 / 6   HEALING PRACTICE", "HP reduced for practice. Press Q to eat the apple."],
}

@onready var controller: HandController = $HandController
@onready var hud := $SurvivalHud
@onready var actions := $TutorialActions

var step := Step.MOVE
var loot: LootDropper
var _player: Player
var _abilities: PlayerAbilities
var _move_ring: Line2D
var _target: Enemy
var _hit_rang: Boomerang
var _active_recall := false
var _menu: UpgradeMenu
var _trial_upgrade := ""
var _guided_time := 0.0
var _pooled_hold := false
var _manual_blast := false
var _leaving := false
var _paused_before_confirm := false
var _psi_regen_before_potion: float


func _ready() -> void:
	super._ready()
	$WaveSpawner.process_mode = Node.PROCESS_MODE_DISABLED
	_player = PlayerManager.player
	_abilities = _player.get_node("Abilities")
	controller.reset()
	controller.auto_attack_enabled = false
	PlayerManager.reset_player()
	PlayerHud.show()
	_player.global_position = HandController.CENTER
	var camera: Camera2D = _player.get_node("Camera2D")
	camera.top_level = true
	camera.global_position = HandController.CENTER

	loot = LootDropper.new()
	loot.name = "LootDropper"
	loot.controller = controller
	add_child(loot)
	hud.bag_provider = func() -> int: return loot.bag_potions
	loot.bag_changed.connect(hud.set_bag)
	hud.set_bag(0, LootDropper.BAG_CAPACITY)
	hud.item_used.connect(_use_item)
	controller.upgrades_changed.connect(hud.set_upgrades)
	controller.control_event.connect(_on_control_event)
	actions.confirmation_opened.connect(_pause_for_confirmation)
	actions.confirmation_cancelled.connect(_cancel_confirmation)
	actions.confirmed.connect(_leave)
	_show_move_ring()
	_set_step(Step.MOVE)


func _free_level() -> void:
	controller.release_player()
	var camera: Camera2D = _player.get_node("Camera2D")
	camera.top_level = false
	camera.position = Vector2.ZERO
	super._free_level()


func _process(delta: float) -> void:
	if _leaving or LevelManager.is_loading_level:
		return
	match step:
		Step.MOVE:
			if _player.global_position.distance_to(MOVE_GOAL) <= MOVE_RADIUS:
				_move_ring.queue_free()
				_set_step(Step.MELEE)
				controller.auto_attack_enabled = true
				_spawn_target(MELEE_POS, TARGET_SCRIPT.Weapon.SWORD)
		Step.RECALL:
			if not is_instance_valid(_hit_rang) or _hit_rang.is_queued_for_deletion():
				if _active_recall:
					_set_step(Step.GEM)
					loot.spawn_pickup(Pickup.Kind.GEM, RANG_POS, RANG_POS, INF)
				else:
					_start_rang_lesson()
		Step.GEM:
			if loot.picked[Pickup.Kind.GEM] > 0:
				_spawn_chest()
		Step.PICKUPS:
			if loot.bag_apples > 0 and loot.bag_potions > 0:
				_player.update_hp(-3)
				_set_step(Step.APPLE)
		Step.POTION:
			_show_potion_prompt()
		Step.TRY_UPGRADE:
			if _trial_upgrade == "pool" and controller.guided:
				_guided_time += delta
				if _guided_time >= POOL_TRIAL_TIME and not _pooled_hold:
					_pooled_hold = true
					hud.set_lesson("6 / 6   PSI POOL", "Now open your hand or release L to recall.")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key: Key = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if key == KEY_Q:
			_use_item(Pickup.Kind.APPLE)
		elif key == KEY_E:
			_use_item(Pickup.Kind.POTION)


func _set_step(next: Step) -> void:
	step = next
	if PROMPTS.has(step):
		var lines: Array = PROMPTS[step]
		hud.set_lesson(lines[0], lines[1])


func _show_move_ring() -> void:
	_move_ring = Line2D.new()
	_move_ring.name = "MoveGoal"
	_move_ring.position = MOVE_GOAL
	_move_ring.z_index = 1
	_move_ring.width = 2
	_move_ring.default_color = DungeonTheme.GOLD_BRIGHT
	_move_ring.closed = true
	for i in 24:
		_move_ring.add_point(Vector2.from_angle(TAU * i / 24.0) * MOVE_RADIUS)
	add_child(_move_ring)


func _spawn_target(at: Vector2, weapon: int) -> void:
	_target = SLIME.instantiate()
	_target.set_script(TARGET_SCRIPT)
	_target.set("weapon", weapon)
	_target.position = at
	_target.enemy_destroyed.connect(_on_target_destroyed)
	add_child(_target)


func _on_target_destroyed(box: HitBox) -> void:
	match step:
		Step.MELEE:
			_start_rang_lesson.call_deferred()
		Step.RANG:
			_hit_rang = box.get_parent() as Boomerang
			_set_step(Step.RECALL)
		Step.TRY_UPGRADE:
			_leave.call_deferred("completed")


func _start_rang_lesson() -> void:
	_active_recall = false
	controller.auto_attack_enabled = false
	_set_step(Step.RANG)
	_spawn_target(RANG_POS, TARGET_SCRIPT.Weapon.RANG)


func _on_control_event(event: String) -> void:
	var manual_release := event in ["RELEASE: OPEN", "RELEASE: KEY UP"]
	if step == Step.RECALL:
		if event == "REGRAB":
			_active_recall = false
		elif manual_release and _abilities.boomerang_instance == _hit_rang:
			_active_recall = true
	elif step == Step.TRY_UPGRADE:
		match _trial_upgrade:
			"pool":
				if event in ["LAUNCH", "REGRAB"]:
					_guided_time = 0.0
					_pooled_hold = false
					hud.set_lesson("6 / 6   PSI POOL", "Hold a fist or L until the recall prompt.")
				elif manual_release and _pooled_hold:
					_leave.call_deferred("completed")
			"blast":
				if event.begins_with("RELEASE:"):
					_manual_blast = manual_release
				elif event == "BLAST" and _manual_blast:
					_leave.call_deferred("completed")


func _spawn_chest() -> void:
	_set_step(Step.CHEST)
	var chest := RewardChest.new()
	chest.name = "RewardChest"
	chest.position = CHEST_POS
	chest.loot = loot
	chest.flawless = true
	chest.opened.connect(_on_chest_opened)
	add_child(chest)


func _on_chest_opened() -> void:
	for child in get_children():
		if child is Pickup:
			child.lifetime = INF
	_set_step(Step.PICKUPS)


func _use_item(kind: int) -> void:
	if _leaving or LevelManager.is_loading_level or get_tree().paused:
		return
	if step == Step.APPLE and kind == Pickup.Kind.APPLE and loot.use_item(kind):
		_psi_regen_before_potion = controller.psi_regen
		controller.psi_regen = 0.0
		controller.add_psi(0.5 - controller.psi)
		_set_step(Step.POTION)
		_show_potion_prompt()
	elif step == Step.POTION and kind == Pickup.Kind.POTION and loot.use_item(kind):
		controller.psi_regen = _psi_regen_before_potion
		_offer_upgrade()


func _show_potion_prompt() -> void:
	hud.set_lesson("5 / 6   POTION", "%d%% PSI. Press E to heal and refill." % roundi(controller.psi * 100.0))


func _offer_upgrade() -> void:
	_set_step(Step.CHOOSE)
	hud.hide_lesson()
	_menu = UpgradeMenu.new()
	_menu.name = "UpgradeMenu"
	_menu.setup(UPGRADES, controller.owned_levels())
	_menu.chosen.connect(_on_upgrade_chosen)
	_menu.dismiss_requested.connect(actions.request_skip)
	add_child(_menu)


func _on_upgrade_chosen(id: String) -> void:
	_menu = null
	_trial_upgrade = id
	controller.add_upgrade(id)
	controller.add_psi(1.0)
	_set_step(Step.TRY_UPGRADE)
	match id:
		"pierce":
			hud.set_lesson("6 / 6   HEAVY RANG", "Guide your larger rang into the slime.")
			_spawn_target(RANG_POS, TARGET_SCRIPT.Weapon.HEAVY_RANG)
		"pool":
			hud.set_lesson("6 / 6   PSI POOL", "Hold a fist or L until the recall prompt.")
		"blast":
			hud.set_lesson("6 / 6   PSI BLAST", "Guide briefly, then open your hand or release L.")


func _pause_for_confirmation() -> void:
	_paused_before_confirm = get_tree().paused
	get_tree().paused = true
	if is_instance_valid(_menu):
		_menu.selection_enabled = false


func _cancel_confirmation() -> void:
	if is_instance_valid(_menu):
		_menu.selection_enabled = true
	get_tree().paused = _paused_before_confirm


func _leave(action: String) -> void:
	if _leaving or LevelManager.is_loading_level:
		return
	_leaving = true
	if is_instance_valid(_menu):
		_menu.abort()
	if action == "title":
		LevelManager.load_new_level(TITLE_SCENE)
	else:
		LevelManager.finish_tutorial(action)
