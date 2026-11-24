class_name StoneWallLayout extends Node2D
## 墙脚图格驱动贴图、挡箭和近战绕路。

const CELL := 8.0
const CLEARANCE := 16.0
const STONE_ATLAS := preload( "res://tile_maps/dungeon.png" )
const WALL_ATLAS := preload( "res://tile_maps/connected_wall_tiles.png" )
const WALL_CELL := 16
const WALL_RISE := 12
const ATLAS_COLUMNS := 64
const FACE_ROW := 512
const EAST := 1 << 1
const SOUTH := 1 << 2
const WEST := 1 << 3
const WALL_NEIGHBORS: Array[Vector2i] = [
	Vector2i.UP, Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT,
	Vector2i( -1, -1 ), Vector2i( 1, -1 ), Vector2i( 1, 1 ), Vector2i( -1, 1 ),
]
const DUNGEON_WALL_RUNS: Array[Rect2i] = [
	Rect2i( 8, 5, 1, 2 ), Rect2i( 8, 7, 4, 1 ),
]
const RUINS_WALL_RUNS: Array[Rect2i] = [
	Rect2i( 8, 6, 4, 1 ), Rect2i( 11, 7, 1, 1 ),
	Rect2i( 19, 9, 1, 1 ), Rect2i( 19, 10, 4, 1 ),
]
const FLOOR_SIZE := Vector2( 16, 16 )
const FLOOR_CRACKS := [ Vector2( 32, 48 ), Vector2( 16, 64 ), Vector2( 48, 64 ), Vector2( 64, 80 ) ]

var _walls: Array[Rect2] = []
var _wall_masks: Dictionary = {}
var _depth_rows: Array[Node2D] = []
var _archer_cover := false
var _grid := AStarGrid2D.new()


func configure( runs: Array[Rect2i], blocks_arrows: bool = false ) -> void:
	_archer_cover = blocks_arrows
	_set_wall_runs( runs )


## 墙脚按图格定义。连续矩形生成碰撞，格子邻接关系决定压顶、内角和外角。
func _set_wall_runs( runs: Array[Rect2i] ) -> void:
	var occupied: Dictionary = {}
	for run in runs:
		_walls.append( Rect2( Vector2( run.position ) * WALL_CELL, Vector2( run.size ) * WALL_CELL ) )
		for y in range( run.position.y, run.end.y ):
			for x in range( run.position.x, run.end.x ):
				occupied[Vector2i( x, y )] = true
	for cell: Vector2i in occupied:
		var mask := 0
		for i in WALL_NEIGHBORS.size():
			if occupied.has( cell + WALL_NEIGHBORS[i] ):
				mask |= 1 << i
		_wall_masks[cell] = mask


func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if _walls.is_empty():
		return
	var body := StaticBody2D.new()
	body.collision_layer = Enemy.LEDGE_LAYER
	if _archer_cover:
		body.collision_layer |= EnemyProjectile.ARROW_COVER_LAYER
	body.collision_mask = 0
	for rect in _walls:
		var hit_shape := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		shape.size = rect.size
		hit_shape.shape = shape
		hit_shape.position = rect.get_center()
		body.add_child( hit_shape )
	add_child( body )
	_build_routes()


func get_ledge_rects() -> Array[Rect2]:
	return _walls.duplicate()


## 每一排的墙面以墙脚南边为绘制深度，挂在关卡的 Y 排序根下。
func attach_wall_depth( arena: Node2D, actor_z: int ) -> bool:
	if not _depth_rows.is_empty():
		return true
	var cells_by_row: Dictionary = {}
	for cell: Vector2i in _wall_masks:
		if not cells_by_row.has( cell.y ):
			cells_by_row[cell.y] = []
		cells_by_row[cell.y].append( cell )
	for y: int in cells_by_row:
		var row := Node2D.new()
		var foot_y := float( ( y + 1 ) * WALL_CELL )
		row.z_index = actor_z
		row.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		row.add_to_group( "stone_wall_depth" )
		row.draw.connect( _draw_wall_row.bind( row, cells_by_row[y], foot_y ) )
		arena.add_child( row )
		row.global_position = to_global( Vector2( 0, foot_y ) )
		_depth_rows.append( row )
	return not _depth_rows.is_empty()


func _exit_tree() -> void:
	for row in _depth_rows:
		if is_instance_valid( row ):
			row.hide()
			row.queue_free()
	_depth_rows.clear()


func _draw() -> void:
	if _archer_cover:
		_draw_ruins_floor()
	_draw_contact_shadows()


func _draw_ruins_floor() -> void:
	for row in 18:
		for column in 32:
			var coord := Vector2( column, row )
			var seed := ( column * 53 ^ row * 109 ) & 63
			var distance := absf( column - ( 9.0 + row * 0.62 ) )
			var edge := clampf( ( distance - 2.0 ) / 3.0, 0.0, 1.0 )
			var tint := Color( 0.82, 0.88, 0.85 ).lerp( Color( 0.68, 0.75, 0.76 ), edge )
			var tile := Vector2( ( seed % 8 ) * 16, 0 )
			if seed < 2.0 + 14.0 * edge:
				tile = FLOOR_CRACKS[seed % FLOOR_CRACKS.size()]
			elif edge > 0.45 and seed >= 57:
				tile = Vector2( 64, 32 )
				tint = Color( 0.68, 0.82, 0.74 )
			draw_texture_rect_region( STONE_ATLAS, Rect2( coord * FLOOR_SIZE, FLOOR_SIZE ), Rect2( tile, FLOOR_SIZE ), tint )


func _draw_contact_shadows() -> void:
	for cell: Vector2i in _wall_masks:
		var pos := Vector2( cell ) * WALL_CELL
		var mask: int = _wall_masks[cell]
		if ( mask & SOUTH ) == 0:
			draw_rect( Rect2( pos + Vector2( 0, 16 ), Vector2( 16, 1 ) ), Color8( 25, 29, 28, 148 ) )
			draw_rect( Rect2( pos + Vector2( 1, 17 ), Vector2( 14, 1 ) ), Color8( 25, 29, 28, 87 ) )
			draw_rect( Rect2( pos + Vector2( 3, 18 ), Vector2( 10, 1 ) ), Color8( 25, 29, 28, 41 ) )
		if ( mask & EAST ) == 0:
			draw_rect( Rect2( pos + Vector2( 16, 6 ), Vector2( 1, 10 ) ), Color8( 25, 29, 28, 76 ) )


func _draw_wall_row( row: Node2D, cells: Array, foot_y: float ) -> void:
	var material := 4 if _archer_cover else 0
	for cell: Vector2i in cells:
		var pos := Vector2( cell ) * WALL_CELL - Vector2( 0, foot_y )
		var mask: int = _wall_masks[cell]
		if ( mask & SOUTH ) == 0:
			var ends := int( ( mask & WEST ) == 0 ) + 2 * int( ( mask & EAST ) == 0 )
			var face_index := ends + 4 * ( material + posmod( cell.x + cell.y, 4 ) )
			var face_size := Vector2( WALL_CELL, WALL_RISE )
			row.draw_texture_rect_region( WALL_ATLAS, Rect2( pos + Vector2( 0, WALL_CELL - WALL_RISE ), face_size ),
				Rect2( Vector2( face_index * WALL_CELL, FACE_ROW ), face_size ) )
		var cap_index := mask + 256 * ( material + posmod( cell.x * 3 + cell.y * 5, 4 ) )
		var cap_region := Vector2( cap_index % ATLAS_COLUMNS, floori( float( cap_index ) / ATLAS_COLUMNS ) ) * WALL_CELL
		row.draw_texture_rect_region( WALL_ATLAS, Rect2( pos - Vector2( 0, WALL_RISE ), FLOOR_SIZE ),
			Rect2( cap_region, FLOOR_SIZE ) )


func _build_routes() -> void:
	var arena := HandController.ARENA_RECT.grow( -6.0 )
	_grid.region = Rect2i( Vector2i.ZERO, Vector2i( arena.size / CELL ) )
	_grid.offset = arena.position + Vector2.ONE * CELL * 0.5
	_grid.cell_size = Vector2.ONE * CELL
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_grid.update()
	for y in _grid.region.size.y:
		for x in _grid.region.size.x:
			var id := Vector2i( x, y )
			for rect in _walls:
				if rect.grow( CLEARANCE ).has_point( _grid.get_point_position( id ) ):
					_grid.set_point_solid( id )
					break


func route_target( start: Vector2, target: Vector2 ) -> Vector2:
	if _walls.is_empty() or not _segment_blocked( start, target ):
		return target
	var start_id := _open_cell_near( start )
	var target_id := _open_cell_near( target )
	var path := _grid.get_point_path( start_id, target_id )
	if path.is_empty():
		return target
	if path.size() > 1 and start.distance_to( path[0] ) <= CELL:
		return path[1]
	return path[0] if start.distance_to( path[0] ) > 2.0 else target


func _open_cell_near( point: Vector2 ) -> Vector2i:
	var id := Vector2i( ( ( point - _grid.offset ) / CELL ).round() )
	id = id.clamp( Vector2i.ZERO, _grid.region.size - Vector2i.ONE )
	if not _grid.is_point_solid( id ):
		return id
	var best := id
	var distance := INF
	for y in range( id.y - 3, id.y + 4 ):
		for x in range( id.x - 3, id.x + 4 ):
			var candidate := Vector2i( x, y )
			if not _grid.is_in_boundsv( candidate ) or _grid.is_point_solid( candidate ):
				continue
			var squared := point.distance_squared_to( _grid.get_point_position( candidate ) )
			if squared < distance:
				best = candidate
				distance = squared
	return best


func _segment_blocked( start: Vector2, target: Vector2 ) -> bool:
	for wall in _walls:
		var rect := wall.grow( CLEARANCE - 2.0 )
		if rect.has_point( start ) or rect.has_point( target ):
			return true
		var corners := [ rect.position, Vector2( rect.end.x, rect.position.y ), rect.end, Vector2( rect.position.x, rect.end.y ) ]
		for i in corners.size():
			if Geometry2D.segment_intersects_segment( start, target, corners[i], corners[(i + 1) % corners.size()] ) != null:
				return true
	return false
