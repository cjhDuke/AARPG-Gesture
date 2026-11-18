class_name Upgrades extends RefCounted
## 强化注册表：每项 id / 显示名（≤12 字符）/ 是否进强化池 / 图标色 / 各级效果表 levels。
## 强化有等级（0 = 没有，最高 max_level(id)，强化池里的都是 3 级）：三选一从未满级的强化里抽，选中则 +1 级。
## levels[n-1] 是 n 级的数值和说明，所有数值集中在这张表里，效果由 HandController
## 按等级推出（upgrade_level / set_upgrade_level / add_upgrade / reset_upgrades）。draw_icon 使用 24px 原生纹理，
## 三选一弹窗、HUD 图标行共用；来源与映射见 ui/skill_icons/asset_sources.md。
## desc 用 \n 明确分行：每行只写一个独立效果，最多三行；由三选一卡片 112×46 的说明区完整显示，
## 不依赖截断或省略。
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

const ICON_TEXTURES : Dictionary = {
	"blast": preload( "res://ui/skill_icons/blast.png" ),
	"pierce": preload( "res://ui/skill_icons/pierce.png" ),
	"magnet": preload( "res://ui/skill_icons/magnet.png" ),
	"frost": preload( "res://ui/skill_icons/frost.png" ),
	"pool": preload( "res://ui/skill_icons/pool.png" ),
	"wide_spin": preload( "res://ui/skill_icons/wide_spin.png" ),
	"parry": preload( "res://ui/skill_icons/parry.png" ),
	"heart": preload( "res://ui/skill_icons/heart.png" ),
	"shockwave": preload( "res://ui/skill_icons/shockwave.png" ),
}


const LIST : Array[Dictionary] = [
	{ "id": "blast", "name": "PSI BLAST", "pool": true, "color": Color( 0.4, 0.9, 1.0 ), "levels": [
		{ "desc": "RELEASE: BLAST\nRADIUS 36\nDAMAGE 2", "radius_bonus": 0.0, "damage_bonus": 0, "free": false },
		{ "desc": "RELEASE: BLAST\nRADIUS 46\nDAMAGE 3", "radius_bonus": 10.0, "damage_bonus": 1, "free": false },
		{ "desc": "BLAST RADIUS 56\nDAMAGE 3\nNO PSI COST", "radius_bonus": 20.0, "damage_bonus": 1, "free": true },
	] },
	{ "id": "pierce", "name": "HEAVY RANG", "pool": true, "color": Color( 1.0, 0.55, 0.3 ), "levels": [
		{ "desc": "DAMAGE +1\nSIZE X1.25", "damage": 1, "scale": 1.25 },
		{ "desc": "DAMAGE +2\nSIZE X1.45", "damage": 2, "scale": 1.45 },
		{ "desc": "DAMAGE +3\nSIZE X1.6", "damage": 3, "scale": 1.6 },
	] },
	{ "id": "magnet", "name": "MAGNET", "pool": true, "color": Color( 0.9, 0.3, 0.35 ), "levels": [
		{ "desc": "LOOT PULL\nRANGE 45", "range": 45.0 },
		{ "desc": "LOOT PULL\nRANGE 70", "range": 70.0 },
		{ "desc": "LOOT PULL\nRANGE 100", "range": 100.0 },
	] },
	{ "id": "frost", "name": "FROST TRAIL", "pool": true, "color": Color( 0.65, 0.85, 1.0 ), "levels": [
		{ "desc": "SLOW 50%\nFOR 2S", "slow": 0.5, "time": 2.0 },
		{ "desc": "SLOW 60%\nFOR 3S", "slow": 0.6, "time": 3.0 },
		{ "desc": "SLOW 70%\nFOR 4S", "slow": 0.7, "time": 4.0 },
	] },
	{ "id": "pool", "name": "PSI POOL", "pool": true, "color": Color( 0.55, 0.5, 1.0 ), "levels": [
		{ "desc": "CONTROL 4.5S\nPSI REFILL X1.3", "time_mult": 1.5, "regen_mult": 1.3 },
		{ "desc": "CONTROL 6S\nPSI REFILL X1.6", "time_mult": 2.0, "regen_mult": 1.6 },
		{ "desc": "CONTROL 7.5S\nPSI REFILL X1.9", "time_mult": 2.5, "regen_mult": 1.9 },
	] },
	{ "id": "wide_spin", "name": "WIDE SPIN", "pool": true, "color": Color( 1.0, 0.85, 0.3 ), "levels": [
		{ "desc": "SPIN RADIUS 50\nPUSH X1.6", "scale": 50.0 / 38.0, "knockback": 1.6, "range": 44.0, "damage": 0 },
		{ "desc": "SPIN RADIUS 58\nPUSH X1.9", "scale": 58.0 / 38.0, "knockback": 1.9, "range": 50.0, "damage": 0 },
		{ "desc": "SPIN RADIUS 66\nPUSH X2.2\nDAMAGE +1", "scale": 66.0 / 38.0, "knockback": 2.2, "range": 56.0, "damage": 1 },
	] },
	{ "id": "parry", "name": "PARRY", "pool": true, "color": Color( 0.75, 0.8, 0.85 ), "levels": [
		{ "desc": "SPIN BREAKS\nPROJECTILES", "cooldown": 0.7 },
		{ "desc": "SPIN BREAKS\nPROJECTILES\nCOOLDOWN 0.55S", "cooldown": 0.55 },
		{ "desc": "SPIN BREAKS\nPROJECTILES\nCOOLDOWN 0.45S", "cooldown": 0.45 },
	] },
	{ "id": "heart", "name": "HEART", "pool": true, "color": Color( 1.0, 0.35, 0.45 ), "levels": [
		{ "desc": "+1 HEART\nMAX HP +2", "hp": 2 },
		{ "desc": "+2 HEARTS\nMAX HP +4", "hp": 4 },
		{ "desc": "+3 HEARTS\nMAX HP +6", "hp": 6 },
	] },
	{ "id": "shockwave", "name": "SHOCKWAVE", "pool": false, "color": Color( 0.5, 1.0, 0.8 ), "levels": [
		{ "desc": "FIST ON SELF\nPSI RING BLAST" },
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


## n 级的说明（显式换行，0 级返回空串）
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


## 保留共用 API；已知 id 绘制原生纹理，不额外叠加边框。
static func draw_icon( c : CanvasItem, id : String, center : Vector2, size : float = 24.0 ) -> void:
	var rect := Rect2( center - Vector2.ONE * size * 0.5, Vector2.ONE * size )
	var texture : Texture2D = ICON_TEXTURES.get( id )
	if texture != null:
		c.draw_texture_rect( texture, rect, false )
	else:
		# 未注册图标只用低调的占位菱形，避免伪装为某项强化。
		var r := size * 0.18
		c.draw_colored_polygon( PackedVector2Array( [
			center + Vector2( 0, -r ), center + Vector2( r, 0 ),
			center + Vector2( 0, r ), center + Vector2( -r, 0 ) ] ), Color( "bf8b45" ) )


## 画在 Control 上的图标，HUD 图标行用
class Icon extends Control:
	var upgrade_id : String = ""
	var icon_size : float = 24.0
	## 等级（>0 时在图标下方画等级小点；max_level 为 1 的实验项不画）
	var level : int = 0

	func _init( id : String = "", s : float = 24.0, lv : int = 0 ) -> void:
		upgrade_id = id
		icon_size = s
		level = lv
		theme = DungeonTheme.THEME
		var dot_space := 5.0 if lv > 0 and Upgrades.max_level( id ) > 1 else 0.0
		custom_minimum_size = Vector2( s, s + dot_space )
		size = custom_minimum_size
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		Upgrades.draw_icon( self, upgrade_id, Vector2( icon_size, icon_size ) * 0.5, icon_size )
		if level > 0 and Upgrades.max_level( upgrade_id ) > 1:
			# 独立的下方点列；不覆盖纹理主体。
			var count := mini( level, Upgrades.max_level( upgrade_id ) )
			var x0 := floorf( ( icon_size - ( count * 4.0 - 2.0 ) ) * 0.5 )
			for i in count:
				var p := Vector2( x0 + i * 4.0, icon_size + 2.0 )
				draw_rect( Rect2( p - Vector2.ONE, Vector2( 4, 4 ) ), Color( "211a20" ) )
				draw_rect( Rect2( p, Vector2( 2, 2 ) ), Color( "f3dfae" ) )
