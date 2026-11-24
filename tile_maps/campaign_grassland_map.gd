extends GrasslandMap

const PLATFORMS: Array[Rect2i] = [ Rect2i( 4, 0, 3, 3 ), Rect2i( 11, 4, 5, 5 ) ]
const ROADS: Array[Rect2i] = [ Rect2i( 1, 3, 11, 2 ), Rect2i( 1, 4, 2, 4 ), Rect2i( 2, 6, 9, 2 ) ]


func _ledge_regions() -> Array[Rect2i]:
	return PLATFORMS


func _paint_roads() -> void:
	var cells: Dictionary = {}
	for region in ROADS:
		for y in range( region.position.y, region.end.y ):
			for x in range( region.position.x, region.end.x ):
				cells[Vector2i( x, y )] = true
	for cell: Vector2i in cells:
		var atlas_x := 13
		var atlas_y := 1 + posmod( cell.x + cell.y, 2 )
		if not cells.has( cell + Vector2i.LEFT ):
			atlas_x = 12
		elif not cells.has( cell + Vector2i.RIGHT ):
			atlas_x = 15
		if not cells.has( cell + Vector2i.UP ):
			atlas_y = 0
		elif not cells.has( cell + Vector2i.DOWN ):
			atlas_y = 3
		set_cell( 0, cell, 0, Vector2i( atlas_x, atlas_y ) )


func _paint_ledge( region: Rect2i ) -> void:
	if region.position.y == 0:
		super._paint_ledge( region )
		return
	for y in region.size.y:
		for x in region.size.x:
			var coord := Vector2i( x, y )
			var tile := _grass_tile( x + region.position.x, y + region.position.y )
			var left := x == 0
			var right := x == region.size.x - 1
			if y == 0:
				tile = Vector2i( 10 if left else ( 14 if right else 12 ), 4 )
			elif y == region.size.y - 1:
				tile = Vector2i( 10 if left else ( 14 if right else 12 ), 7 )
			elif left or right:
				tile = Vector2i( 10 if left else 14, 5 + y % 2 )
			set_cell( 0, region.position + coord, 0, tile )
