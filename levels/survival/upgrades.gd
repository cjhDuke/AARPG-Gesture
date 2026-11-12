class_name Upgrades extends RefCounted
## 强化注册表：每项 id / 显示名（≤12 字符）/ 是否进强化池 / 图标色 / 各级效果表 levels。
## 强化有等级（0 = 没有，最高 max_level(id)，强化池里的都是 3 级）：三选一从未满级的强化里抽，选中则 +1 级。
## levels[n-1] 是 n 级的数值和一行说明（desc ≤26 字符），所有数值集中在这张表里，效果由 HandController
## 按等级推出（upgrade_level / set_upgrade_level / add_upgrade / reset_upgrades）。图标全部用代码画（draw_icon），
## 三选一弹窗、HUD 图标行共用，不依赖美术素材。
## shockwave 是实验项（pool=false，只有 1 级），不会出现在三选一里，只能在练习场用数字键 9 打开。
## 数值键说明（等级表里没写的键视为"没有该效果"）：
##   blast:     radius_bonus（在控制器基础半径上加）、damage_bonus（在基础伤害上加）、free（true = 不额外耗念力）
##   pierce:    damage（镖伤害加成）、scale（镖体和判定倍率）
##   magnet:    range（吸附距离）
##   frost:     slow（减速比例）、time（秒）
##   pool:      time_mult（操控时长倍率）、regen_mult（回充倍率）
##   wide_spin: scale（旋转斩范围倍率）、knockback（击退倍率）、range（自动攻击距离）、damage（伤害加成）
##   parry:     cooldown（自动攻击冷却，秒）
##   heart:     hp（血量上限加成，2 点 = 1 颗心）

const MAX_LEVEL : int = 3

const LIST : Array[Dictionary] = [
	{ "id": "blast", "name": "PSI BLAST", "pool": true, "color": Color( 0.4, 0.9, 1.0 ), "levels": [
		{ "desc": "BLAST ON RELEASE R36 D2", "radius_bonus": 0.0, "damage_bonus": 0, "free": false },
		{ "desc": "BLAST R46 D3", "radius_bonus": 10.0, "damage_bonus": 1, "free": false },
		{ "desc": "BLAST R56 D3, NO PSI COST", "radius_bonus": 20.0, "damage_bonus": 1, "free": true },
	] },
	{ "id": "pierce", "name": "HEAVY RANG", "pool": true, "color": Color( 1.0, 0.55, 0.3 ), "levels": [
		{ "desc": "DMG +1, SIZE X1.25", "damage": 1, "scale": 1.25 },
		{ "desc": "DMG +2, SIZE X1.45", "damage": 2, "scale": 1.45 },
		{ "desc": "DMG +3, SIZE X1.6", "damage": 3, "scale": 1.6 },
	] },
	{ "id": "magnet", "name": "MAGNET", "pool": true, "color": Color( 0.9, 0.3, 0.35 ), "levels": [
		{ "desc": "LOOT PULL RANGE 45", "range": 45.0 },
		{ "desc": "LOOT PULL RANGE 70", "range": 70.0 },
		{ "desc": "LOOT PULL RANGE 100", "range": 100.0 },
	] },
	{ "id": "frost", "name": "FROST TRAIL", "pool": true, "color": Color( 0.65, 0.85, 1.0 ), "levels": [
		{ "desc": "SLOW 50% FOR 2S", "slow": 0.5, "time": 2.0 },
		{ "desc": "SLOW 60% FOR 3S", "slow": 0.6, "time": 3.0 },
		{ "desc": "SLOW 70% FOR 4S", "slow": 0.7, "time": 4.0 },
	] },
	{ "id": "pool", "name": "PSI POOL", "pool": true, "color": Color( 0.55, 0.5, 1.0 ), "levels": [
		{ "desc": "CONTROL 4.5S, REFILL X1.3", "time_mult": 1.5, "regen_mult": 1.3 },
		{ "desc": "CONTROL 6S, REFILL X1.6", "time_mult": 2.0, "regen_mult": 1.6 },
		{ "desc": "CONTROL 7.5S, REFILL X1.9", "time_mult": 2.5, "regen_mult": 1.9 },
	] },
	{ "id": "wide_spin", "name": "WIDE SPIN", "pool": true, "color": Color( 1.0, 0.85, 0.3 ), "levels": [
		{ "desc": "SPIN R50, PUSH X1.6", "scale": 50.0 / 38.0, "knockback": 1.6, "range": 44.0, "damage": 0 },
		{ "desc": "SPIN R58, PUSH X1.9", "scale": 58.0 / 38.0, "knockback": 1.9, "range": 50.0, "damage": 0 },
		{ "desc": "R66, PUSH X2.2, DMG +1", "scale": 66.0 / 38.0, "knockback": 2.2, "range": 56.0, "damage": 1 },
	] },
	{ "id": "parry", "name": "PARRY", "pool": true, "color": Color( 0.75, 0.8, 0.85 ), "levels": [
		{ "desc": "SPIN BREAKS PROJECTILES", "cooldown": 0.7 },
		{ "desc": "PARRY + COOLDOWN 0.55S", "cooldown": 0.55 },
		{ "desc": "PARRY + COOLDOWN 0.45S", "cooldown": 0.45 },
	] },
	{ "id": "heart", "name": "HEART", "pool": true, "color": Color( 1.0, 0.35, 0.45 ), "levels": [
		{ "desc": "+1 HEART (MAX HP +2)", "hp": 2 },
		{ "desc": "+2 HEARTS (MAX HP +4)", "hp": 4 },
		{ "desc": "+3 HEARTS (MAX HP +6)", "hp": 6 },
	] },
	{ "id": "shockwave", "name": "SHOCKWAVE", "pool": false, "color": Color( 0.5, 1.0, 0.8 ), "levels": [
		{ "desc": "FIST ON SELF = PSI RING" },
	] },
]


## 该强化的最高等级（未知 id 返回 0）
static func max_level( id : String ) -> int:
	return get_def( id ).get( "levels", [] ).size()


## n 级的整张数值表（n 超出范围返回空字典；0 级 = 没有强化）
static func level_data( id : String, lv : int ) -> Dictionary:
	var levels : Array = get_def( id ).get( "levels", [] )
	if lv < 1 or lv > levels.size():
		return {}
	return levels[lv - 1]


## n 级的某个数值；0 级或表里没有该键时返回 default
static func param( id : String, lv : int, key : String, default : Variant ) -> Variant:
	return level_data( id, lv ).get( key, default )


## n 级的一行说明（0 级返回空串）
static func level_desc( id : String, lv : int ) -> String:
	return String( level_data( id, lv ).get( "desc", "" ) )


static func get_def( id : String ) -> Dictionary:
	for u in LIST:
		if u["id"] == id:
			return u
	return {}


static func display_name( id : String ) -> String:
	return String( get_def( id ).get( "name", id.to_upper() ) )


## 所有强化 id（含实验项），按表的顺序
static func all_ids() -> Array[String]:
	var r : Array[String] = []
	for u in LIST:
		r.append( u["id"] )
	return r


## 能出现在三选一里的强化 id
static func pool_ids() -> Array[String]:
	var r : Array[String] = []
	for u in LIST:
		if u["pool"]:
			r.append( u["id"] )
	return r


## 在 canvas 上以 center 为中心画一个 size x size 的图标（深色底 + 彩色边框 + 图案）
static func draw_icon( c : CanvasItem, id : String, center : Vector2, size : float = 16.0 ) -> void:
	var col : Color = get_def( id ).get( "color", Color.WHITE )
	var k := size / 16.0
	var o := center - Vector2( 8, 8 ) * k
	c.draw_rect( Rect2( o, Vector2( 16, 16 ) * k ), Color( 0.08, 0.09, 0.14, 0.9 ) )
	c.draw_rect( Rect2( o, Vector2( 16, 16 ) * k ), col, false, maxf( k, 1.0 ) )
	var w := maxf( 1.5 * k, 1.0 )
	match id:
		"blast":
			c.draw_circle( center, 3.0 * k, col )
			for i in 8:
				var d := Vector2.from_angle( i * TAU / 8.0 )
				c.draw_line( center + d * 4.5 * k, center + d * 6.5 * k, col, w )
		"pierce":
			# 粗大的回旋镖：一个钝 V
			c.draw_polyline( PackedVector2Array( [ center + Vector2( -5, -4 ) * k, center + Vector2( 3, 0 ) * k, center + Vector2( -5, 4 ) * k ] ), col, 3.0 * k )
		"magnet":
			c.draw_arc( center + Vector2( 0, -1 ) * k, 4.5 * k, PI, TAU, 12, col, 2.5 * k )
			c.draw_line( center + Vector2( -4.5, -1 ) * k, center + Vector2( -4.5, 4 ) * k, col, 2.5 * k )
			c.draw_line( center + Vector2( 4.5, -1 ) * k, center + Vector2( 4.5, 4 ) * k, col, 2.5 * k )
			c.draw_rect( Rect2( center + Vector2( -5.7, 3 ) * k, Vector2( 2.5, 2.5 ) * k ), Color.WHITE )
			c.draw_rect( Rect2( center + Vector2( 3.2, 3 ) * k, Vector2( 2.5, 2.5 ) * k ), Color.WHITE )
		"frost":
			for i in 3:
				var d := Vector2.from_angle( i * PI / 3.0 + PI / 6.0 )
				c.draw_line( center - d * 6.0 * k, center + d * 6.0 * k, col, w )
		"pool":
			c.draw_rect( Rect2( center + Vector2( -3.5, -6 ) * k, Vector2( 7, 12 ) * k ), col, false, w )
			c.draw_rect( Rect2( center + Vector2( -2, -1 ) * k, Vector2( 4, 6.5 ) * k ), col )
		"wide_spin":
			c.draw_arc( center, 5.5 * k, 0.3, TAU - 0.9, 16, col, 2.0 * k )
			c.draw_line( center + Vector2( 5.5, 0 ) * k, center + Vector2( 3, -3 ) * k, col, w )
			c.draw_line( center + Vector2( 5.5, 0 ) * k, center + Vector2( 8, -3 ) * k, col, w )
		"parry":
			c.draw_colored_polygon( PackedVector2Array( [
				center + Vector2( -5, -5 ) * k, center + Vector2( 5, -5 ) * k,
				center + Vector2( 5, 1 ) * k, center + Vector2( 0, 6 ) * k, center + Vector2( -5, 1 ) * k ] ), col )
			c.draw_line( center + Vector2( 0, -3 ) * k, center + Vector2( 0, 3 ) * k, Color( 0.08, 0.09, 0.14 ), w )
		"heart":
			c.draw_circle( center + Vector2( -2.5, -2 ) * k, 3.0 * k, col )
			c.draw_circle( center + Vector2( 2.5, -2 ) * k, 3.0 * k, col )
			c.draw_colored_polygon( PackedVector2Array( [
				center + Vector2( -5.4, -0.5 ) * k, center + Vector2( 5.4, -0.5 ) * k, center + Vector2( 0, 5.5 ) * k ] ), col )
		"shockwave":
			c.draw_arc( center, 2.5 * k, 0, TAU, 12, col, w )
			c.draw_arc( center, 5.5 * k, 0, TAU, 16, col, w )
		_:
			c.draw_circle( center, 3.0 * k, col )


## 画在 Control 上的图标，HUD 图标行用
class Icon extends Control:
	var upgrade_id : String = ""
	var icon_size : float = 14.0
	## 等级（>0 时在图标底部画等级小点；max_level 为 1 的实验项不画）
	var level : int = 0

	func _init( id : String = "", s : float = 14.0, lv : int = 0 ) -> void:
		upgrade_id = id
		icon_size = s
		level = lv
		custom_minimum_size = Vector2( s, s )
		size = Vector2( s, s )
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		Upgrades.draw_icon( self, upgrade_id, Vector2( icon_size, icon_size ) * 0.5, icon_size )
		if level > 0 and Upgrades.max_level( upgrade_id ) > 1:
			# 底部一排 2x2 的金色小点，每级一个，带黑边保证压在图标上也看得清
			for i in level:
				var p := Vector2( 1.0 + i * 3.0, icon_size - 3.0 )
				draw_rect( Rect2( p - Vector2.ONE, Vector2( 4, 4 ) ), Color( 0, 0, 0, 0.9 ) )
				draw_rect( Rect2( p, Vector2( 2, 2 ) ), Color( 1.0, 0.9, 0.3 ) )
