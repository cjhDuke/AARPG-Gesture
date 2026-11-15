class_name LootDropper extends Node
## 掉落规则：回旋镖致命一击必掉宝石；苹果按敌人的 apple_drop_chance 掉，带保底。
## 掉落物加到本节点的父节点（关卡根）下，和主角、敌人一起按 y 排序。
## 关卡重开 / 释放时调用 clear()。

## 回旋镖击杀掉宝石的概率
const GEM_CHANCE_BOOMERANG : float = 1.0
## 连续这么多次击杀没掉苹果，则这一次必掉
const APPLE_PITY_KILLS : int = 10
## 同时掉宝石和苹果时，两者的水平错开距离（像素）
const SPLIT_OFFSET : float = 8.0

## 背包里任一消耗品变化时发出（HUD 用）
signal bag_changed( count : int, capacity : int )

## 苹果与药水各自的库存上限
const BAG_CAPACITY : int = 3
## 仅用于兼容旧检查点的自动食用计时
const EAT_DELAY : float = 0.6

## 为 false 时不掉苹果（回旋镖练习场只掉宝石）
var apples_enabled : bool = true
## 念力来源（宝石 / 药水用）
var controller : HandController

## 苹果与药水分别存放，拾取后由玩家决定使用时机
var bag_apples : int = 0
var bag_potions : int = 0

## 本局各类掉落物的拾取次数（下标是 Pickup.Kind），暂停菜单的背包面板用
var picked : Array[int] = [ 0, 0, 0 ]

var _kills_since_apple : int = 0


func bag_has_room( kind : int = Pickup.Kind.APPLE ) -> bool:
	return ( bag_potions if kind == Pickup.Kind.POTION else bag_apples ) < BAG_CAPACITY


func get_checkpoint_state() -> Dictionary:
	return {"bag_apples": bag_apples, "bag_potions": bag_potions, "picked": picked.duplicate(), "kills_since_apple": _kills_since_apple, "eat_timer": 0.0}


func restore_checkpoint_state(data: Dictionary) -> void:
	bag_apples = int(data["bag_apples"])
	bag_potions = int(data.get("bag_potions", 0))
	picked.assign(data["picked"])
	_kills_since_apple = int(data["kills_since_apple"])
	bag_changed.emit(bag_apples, BAG_CAPACITY)


## 往背包里放一个苹果，满了返回 false
func store_apple() -> bool:
	if not bag_has_room():
		return false
	bag_apples += 1
	bag_changed.emit( bag_apples, BAG_CAPACITY )
	return true


func store_potion() -> bool:
	if not bag_has_room( Pickup.Kind.POTION ):
		return false
	bag_potions += 1
	bag_changed.emit( bag_apples, BAG_CAPACITY )
	return true


func can_use_item( kind : int ) -> bool:
	var player : Player = PlayerManager.player
	if player == null or player.is_dead:
		return false
	if kind == Pickup.Kind.APPLE:
		return bag_apples > 0 and player.hp < player.max_hp
	if kind == Pickup.Kind.POTION:
		return bag_potions > 0 and ( player.hp < player.max_hp or ( is_instance_valid( controller ) and controller.psi < 1.0 ) )
	return false


func use_item( kind : int ) -> bool:
	if not can_use_item( kind ):
		return false
	var player : Player = PlayerManager.player
	var old_hp : int = player.hp
	if kind == Pickup.Kind.APPLE:
		bag_apples -= 1
		player.update_hp( 1 )
	else:
		bag_potions -= 1
		player.update_hp( 2 )
		if is_instance_valid( controller ):
			controller.add_psi( 1.0 )
	if player.hp > old_hp:
		PlayerHud.flash_heal()
	PlayerManager.play_audio( Pickup.HP_UP_SOUND )
	bag_changed.emit( bag_apples, BAG_CAPACITY )
	Pickup.show_float_text( get_parent(), player.global_position + Vector2( 0, -48 ), "+%d HP%s" % [ player.hp - old_hp, "  PSI MAX" if kind == Pickup.Kind.POTION else "" ] )
	return true


## 敌人被消灭：hit_box 是致命一击的判定框（属于 Boomerang 或 PsiBlast 节点则算回旋镖击杀）
func handle_enemy_destroyed( enemy : Enemy, hit_box : HitBox ) -> void:
	var by_boomerang := is_instance_valid( hit_box ) and ( hit_box.get_parent() is Boomerang or hit_box.get_parent() is PsiBlast )
	var gem := by_boomerang and randf() < GEM_CHANCE_BOOMERANG
	var apple := false
	if apples_enabled:
		_kills_since_apple += 1
		if randf() < enemy.apple_drop_chance or _kills_since_apple >= APPLE_PITY_KILLS:
			apple = true
			_kills_since_apple = 0
	var pos := enemy.global_position
	if gem and apple:
		spawn_pickup( Pickup.Kind.GEM, pos, pos + Vector2( -SPLIT_OFFSET, 0 ) )
		spawn_pickup( Pickup.Kind.APPLE, pos, pos + Vector2( SPLIT_OFFSET, 0 ) )
	elif gem:
		spawn_pickup( Pickup.Kind.GEM, pos, pos )
	elif apple:
		spawn_pickup( Pickup.Kind.APPLE, pos, pos )


## 生成一个掉落物，从 from 弹到 dest（都会夹进 ARENA_RECT 内）
func spawn_pickup( kind : int, from : Vector2, dest : Vector2, lifetime : float = Pickup.DEFAULT_LIFETIME ) -> Pickup:
	var parent := get_parent()
	if parent == null:
		return null
	var p := Pickup.new()
	p.kind = kind
	p.lifetime = lifetime
	p.controller = controller
	p.loot = self
	p.collected.connect( func( k : int ) -> void: picked[k] += 1 )
	parent.add_child( p )
	p.global_position = _clamp_to_arena( from )
	p.pop_to( _clamp_to_arena( dest ) )
	return p


## 清掉场上所有掉落物、飘字、保底计数和背包
func clear() -> void:
	_kills_since_apple = 0
	bag_apples = 0
	bag_potions = 0
	picked = [ 0, 0, 0 ]
	bag_changed.emit( bag_apples, BAG_CAPACITY )
	clear_world_drops()


func clear_world_drops() -> void:
	if not is_inside_tree():
		return
	for n in get_tree().get_nodes_in_group( "loot_fx" ):
		n.queue_free()


func _clamp_to_arena( p : Vector2 ) -> Vector2:
	var r := HandController.ARENA_RECT
	return Vector2( clampf( p.x, r.position.x, r.end.x ), clampf( p.y, r.position.y, r.end.y ) )
