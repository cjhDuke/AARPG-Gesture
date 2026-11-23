extends Node2D
## Exercise the real enemies and the combat-to-art transition points.

var _checks := 0
var _failures := 0
var _spawner: WaveSpawner
var _hit: HitBox


func _ready() -> void:
	AudioServer.set_bus_mute(0, true)
	_run.call_deferred()


func _check(ok: bool, text: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("ENEMY ART: " + text)


func _spawn(variant: String, at: Vector2) -> Enemy:
	var enemy := _spawner.spawn_extra(variant, at)
	enemy.fade_in_time = 0.0
	await get_tree().process_frame
	enemy.state_machine.set_process(false)
	return enemy


func _run() -> void:
	_spawner = WaveSpawner.new()
	add_child(_spawner)
	_hit = HitBox.new()
	_hit.monitoring = false
	_hit.monitorable = false
	_hit.damage = 99
	add_child(_hit)
	for type: String in WaveSpawner.REGISTRY:
		var enemy := await _spawn(type, Vector2(215, 155))
		_check(enemy.sprite_2d.texture.resource_path == "res://enemies/art_v2/" + type + ".png",
			type + " uses its own new atlas")
		_check(enemy.sprite_2d.vframes == 3, type + " has three authored directions")
		enemy.set_direction(Vector2.LEFT)
		_check(enemy.sprite_2d.scale.x == -1.0, type + " mirrors the left side")
		enemy.queue_free()
		await get_tree().process_frame
	await _check_archer()
	await _check_shield()
	await _check_split()
	await _check_bomb()
	_check_wizard()
	await get_tree().create_timer(0.5).timeout
	_spawner.clear()
	await get_tree().process_frame
	await get_tree().process_frame
	print("Enemy art: ", _checks, " checks, ", _failures, " failures")
	get_tree().quit(1 if _failures else 0)


func _check_archer() -> void:
	var archer := await _spawn("archer_goblin", Vector2(135, 155)) as ArcherGoblin
	archer.player.global_position = Vector2(250, 162)
	var state := archer.state_machine.current_state as EnemyStateArcher
	state._cooldown = 0.0
	state.process(0.0)
	archer.animation_player.advance(0)
	_check(archer.aiming and archer.sprite_2d.frame_coords.x == 11, "aim starts with bow raise")
	state.process(0.25)
	archer.animation_player.advance(0)
	_check(archer.sprite_2d.frame_coords == Vector2i(12, 1), "side aim uses drawn bow")
	_check(get_tree().get_nodes_in_group("enemy_projectile").is_empty(), "aim has no arrow yet")
	state.process(0.25)
	archer.animation_player.advance(0)
	var arrows := get_tree().get_nodes_in_group("enemy_projectile")
	_check(not archer.aiming and archer.sprite_2d.frame_coords == Vector2i(13, 1), "arrow and release frame coincide")
	_check(arrows.size() == 1, "exactly one arrow flies at release")
	if not arrows.is_empty():
		var matching := false
		for child in arrows[0].get_children():
			if child is Sprite2D and child.texture != null:
				matching = child.texture.resource_path.ends_with("/art_v2/archer_arrow.png")
		_check(matching, "projectile uses the matching arrow")
		arrows[0].queue_free()
	archer.queue_free()
	await get_tree().process_frame


func _check_shield() -> void:
	var guard := await _spawn("shield_goblin", Vector2(215, 155)) as ShieldGoblin
	guard.player.global_position = guard.global_position + Vector2.RIGHT * 100.0
	guard._process(1.0)
	var facing := Vector2.from_angle(guard.shield_angle)
	var plate := guard.get_node_or_null("ShieldPlate") as Sprite2D
	_check(plate != null and plate.position.x > 0.0 and plate.frame_coords.y == 1,
		"shield plate follows actual right-facing block arc")
	var hp_before := guard.hp
	_hit.global_position = guard.global_position + facing * 24.0
	guard._take_damage(_hit)
	_check(guard.hp == hp_before and guard.can_block(_hit), "front hit still blocks")
	_check(plate != null and plate.frame_coords.x == 2, "blocking flashes the shield plate immediately")
	_hit.global_position = guard.global_position - facing * 24.0
	_check(not guard.can_block(_hit), "the back remains vulnerable")
	guard.queue_free()
	await get_tree().process_frame


func _check_split() -> void:
	_spawner.start_wave({"enemies": {}, "interval": 1.0})
	var big := await _spawn("big_slime", Vector2(240, 170)) as BigSlime
	var center := big.global_position
	var starts: Array[Vector2] = []
	var remember := func(node: Node) -> void:
		if node is Enemy and node.get_parent() == self:
			(func() -> void: starts.append(node.global_position)).call_deferred()
	get_tree().node_added.connect(remember)
	_hit.global_position = center + Vector2.DOWN
	big._take_damage(_hit)
	_check(big.sprite_2d.frame_coords.x == 9, "split starts on the open seam frame at the killing hit")
	await get_tree().process_frame
	get_tree().node_added.disconnect(remember)
	_check(starts.size() == 2 and _spawner.is_running(), "offspring are counted before wave clear")
	if starts.size() == 2:
		_check(starts[0].is_equal_approx(center - Vector2(big.split_offset, 0.0))
			and starts[1].is_equal_approx(center + Vector2(big.split_offset, 0.0)),
			"offspring flank the split point before their first movement step")
	await get_tree().create_timer(0.45).timeout
	_spawner.clear()
	await get_tree().process_frame


func _check_bomb() -> void:
	var bomb := await _spawn("bomb_slime", Vector2(145, 175)) as BombSlime
	_hit.global_position = bomb.global_position + Vector2.DOWN
	bomb._take_damage(_hit)
	var items := get_tree().get_nodes_in_group("loot_fx")
	var armed: BombExplosion
	for item in items:
		if item is BombExplosion:
			armed = item
	_check(is_instance_valid(armed) and armed._icon.texture.resource_path.ends_with("/art_v2/bomb_fuse.png"),
		"kill drops a new bomb icon immediately")
	if is_instance_valid(armed):
		armed.set_process(false)
		armed._process(0.13)
		_check(not armed._exploded and armed._icon.frame != 0, "fuse animates before the explosion")
		armed.queue_free()


func _check_wizard() -> void:
	var boss := WizardBoss.spawn(self, _spawner, null)
	boss.set_process(false)
	boss._update_visuals()
	_check(boss._cloak.texture.resource_path.ends_with("/art_v2/boss_cloak_actions.png")
		and boss._hand_l.texture.resource_path.ends_with("/art_v2/boss_hand.png"), "wizard uses separate authored layers")
	_check(boss._cloak.frame == 0, "wizard enters on the entrance pose")
	boss.phase = WizardBoss.Phase.SHIELD
	boss._charging = true
	boss._charge_left = boss.charge_time * 0.4
	boss._update_visuals()
	_check(boss._cloak.frame == 4 and boss._hand_l.frame == 2, "charging raises the authored casting hands")
	boss._charging = false
	boss.phase = WizardBoss.Phase.STUN
	boss._fall_t = 1.0
	boss._update_visuals()
	_check(boss._cloak.frame == 6 and boss._hand_l.frame == 0, "shield break exposes the collapsed cloak and limp hands")
	boss.cleanup()
	boss.queue_free()
