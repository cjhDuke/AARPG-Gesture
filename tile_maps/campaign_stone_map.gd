extends LevelTileMap

const EXTRA_DUNGEON_WALL := Rect2i( 19, 11, 4, 1 )
const FLOOR_ATLAS := preload( "res://tile_maps/dungeon.png" )
const PAVING := Vector2( 16, 16 )

@export_enum("Dungeon", "Ruins", "Wizard Hall") var layout: int
var _terrain: StoneWallLayout


func _ready() -> void:
	super._ready()
	if layout == 2:
		var inlay := Node2D.new()
		inlay.z_index = 1
		inlay.draw.connect( _draw_hall_inlay.bind( inlay ) )
		add_child( inlay )
		return
	_terrain = StoneWallLayout.new()
	_terrain.z_index = 1
	var runs := StoneWallLayout.RUINS_WALL_RUNS.duplicate() if layout == 1 else StoneWallLayout.DUNGEON_WALL_RUNS.duplicate()
	if layout == 0:
		runs.append( EXTRA_DUNGEON_WALL )
	_terrain.configure( runs, layout == 1 )
	add_child( _terrain )


func get_ledge_rects() -> Array[Rect2]:
	return _terrain.get_ledge_rects() if is_instance_valid( _terrain ) else ( [] as Array[Rect2] )


func attach_wall_depth( arena: Node2D, actor_z: int ) -> bool:
	return is_instance_valid( _terrain ) and _terrain.attach_wall_depth( arena, actor_z )


func route_target( start: Vector2, target: Vector2 ) -> Vector2:
	return _terrain.route_target( start, target ) if is_instance_valid( _terrain ) else target


func _draw_hall_inlay( canvas: Node2D ) -> void:
	# 只用现有原尺寸地砖铺出低对比的环和四角底座，火把和攻击反馈由 Boss 驱动。
	for y in range( 3, 16 ):
		for x in range( 4, 28 ):
			var pos := Vector2( x, y ) * PAVING
			var delta := pos + PAVING * 0.5 - HandController.CENTER
			var radius := ( delta * Vector2( 1.0, 1.45 ) ).length()
			var in_ring := radius >= 53.0 and radius <= 68.0
			var in_center := radius <= 48.0
			var under_brazier := x in [ 6, 7, 24, 25 ] and y in [ 6, 7, 13, 14 ]
			if not ( in_ring or in_center or under_brazier ):
				continue
			var tone := Color( 0.79, 0.69, 0.57 ) if in_ring or under_brazier else Color( 0.67, 0.64, 0.62 )
			var tile := Vector2( float( ( x + y * 3 ) % 8 ) * 16.0, 0 )
			canvas.draw_texture_rect_region( FLOOR_ATLAS, Rect2( pos, PAVING ), Rect2( tile, PAVING ), tone )
