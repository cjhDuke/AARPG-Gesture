class_name Upgrades extends RefCounted
## 强化注册表：每项 id / 显示名（≤12 字符）/ 一行说明（≤26 字符）/ 是否进强化池 / 图标色。
## 强化的"已拥有"状态和效果在 HandController（has_upgrade / set_upgrade / reset_upgrades）；
## 图标全部用代码画（draw_icon），台座、HUD 图标行共用，不依赖美术素材。
## shockwave 是实验项（pool=false），不会出现在台座上，只能在练习场用数字键 9 打开。

const LIST : Array[Dictionary] = [
	{ "id": "blast", "name": "PSI BLAST", "desc": "RELEASE = EXPLOSION", "pool": true, "color": Color( 0.4, 0.9, 1.0 ) },
	{ "id": "pierce", "name": "HEAVY RANG", "desc": "BOOMERANG DMG +1, BIGGER", "pool": true, "color": Color( 1.0, 0.55, 0.3 ) },
	{ "id": "magnet", "name": "MAGNET", "desc": "BOOMERANG PULLS LOOT", "pool": true, "color": Color( 0.9, 0.3, 0.35 ) },
	{ "id": "frost", "name": "FROST TRAIL", "desc": "SLOWS ENEMIES 2S", "pool": true, "color": Color( 0.65, 0.85, 1.0 ) },
	{ "id": "pool", "name": "PSI POOL", "desc": "1.5X PSI TIME, FAST REFILL", "pool": true, "color": Color( 0.55, 0.5, 1.0 ) },
	{ "id": "wide_spin", "name": "WIDE SPIN", "desc": "SPIN RANGE + KNOCKBACK", "pool": true, "color": Color( 1.0, 0.85, 0.3 ) },
	{ "id": "parry", "name": "PARRY", "desc": "SPIN BREAKS PROJECTILES", "pool": true, "color": Color( 0.75, 0.8, 0.85 ) },
	{ "id": "heart", "name": "HEART", "desc": "MAX HP +1 HEART, HEAL", "pool": true, "color": Color( 1.0, 0.35, 0.45 ) },
	{ "id": "shockwave", "name": "SHOCKWAVE", "desc": "FIST ON SELF = PSI RING", "pool": false, "color": Color( 0.5, 1.0, 0.8 ) },
]


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


## 能出现在台座上的强化 id
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

	func _init( id : String = "", s : float = 14.0 ) -> void:
		upgrade_id = id
		icon_size = s
		custom_minimum_size = Vector2( s, s )
		size = Vector2( s, s )
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		Upgrades.draw_icon( self, upgrade_id, Vector2( icon_size, icon_size ) * 0.5, icon_size )
