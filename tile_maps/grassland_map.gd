class_name GrasslandMap extends LevelTileMap
## 关卡 2 草地场景：图块在 _ready 里按数组铺（图块集是 Grass-01，32×32）。
## 场地 16×9 格（512×288），镜头固定在中心，只看得到约 16..496 × 9..279。
## 边界：上沿是悬崖正面、左右是悬崖侧壁、下沿是悬崖顶缘，碰撞用矩形（和地牢墙体同层 Walls），
## 放在 HandController.ARENA_RECT 外面，主角和敌人走不出去。
## 高台：两块贴着上边界的凸起（3×3 格），碰撞在单独的 Ledge 层（32）：挡主角和敌人，
## 不挡箭（箭只查 Walls 层）、回旋镖、掉落物。弓手站位见 StageData 的 archer_spots。

const WALLS_LAYER : int = 16
const LEDGE_LAYER : int = 32
const COLS : int = 16
const ROWS : int = 9

## 高台（图块格：x, y, 宽, 高），都贴着上边界（y = 0）
const LEDGE_TILES : Array[Rect2i] = [ Rect2i( 4, 0, 3, 3 ), Rect2i( 9, 0, 3, 3 ) ]
## 高台碰撞比图块少一点：悬崖正面图块的下沿留出约 4 像素的草边
const LEDGE_BOTTOM_TRIM : float = 4.0
## 土路（图块格：x, y, 宽, 高；宽高至少 2）
const ROAD_TILES : Array[Rect2i] = [
	Rect2i( 2, 4, 6, 2 ), Rect2i( 10, 6, 5, 2 ), Rect2i( 1, 1, 2, 3 ), Rect2i( 13, 2, 2, 2 ),
]
## 纯草地图块（图集坐标）
const PLAIN_GRASS : Array[Vector2i] = [
	Vector2i( 0, 0 ), Vector2i( 1, 0 ), Vector2i( 2, 0 ), Vector2i( 3, 0 ),
	Vector2i( 0, 2 ), Vector2i( 1, 2 ), Vector2i( 2, 2 ), Vector2i( 3, 2 ),
	Vector2i( 0, 3 ), Vector2i( 1, 3 ), Vector2i( 2, 3 ), Vector2i( 3, 3 ),
]


func _ready() -> void:
	_paint()
	_build_colliders()
	super._ready()


## 高台在世界坐标里的矩形（敌人生成要避开；已含被地图遮住的上半部分）
func get_ledge_rects() -> Array[Rect2]:
	var result : Array[Rect2] = []
	for r in _ledge_regions():
		result.append( Rect2( r.position * 32, r.size * 32 ) )
	return result


func _ledge_regions() -> Array[Rect2i]:
	return LEDGE_TILES


func _paint() -> void:
	clear()
	for y in ROWS:
		for x in COLS:
			set_cell( 0, Vector2i( x, y ), 0, _grass_tile( x, y ) )
	_paint_roads()
	_paint_border()
	for r in _ledge_regions():
		_paint_ledge( r )


func _grass_tile( x : int, y : int ) -> Vector2i:
	var h : int = ( x * 73856093 ^ y * 19349663 ) & 0xff
	if h < 10:
		return Vector2i( 1, 1 )
	if h < 18:
		return Vector2i( 2, 1 )
	return PLAIN_GRASS[ h % PLAIN_GRASS.size() ]


func _paint_roads() -> void:
	for region in ROAD_TILES:
		_paint_road( region )


func _paint_road( r : Rect2i ) -> void:
	for j in r.size.y:
		for i in r.size.x:
			var ax : int = 12 if i == 0 else ( 15 if i == r.size.x - 1 else 13 )
			var ay : int = 0 if j == 0 else ( 3 if j == r.size.y - 1 else 1 + ( i + j ) % 2 )
			set_cell( 0, r.position + Vector2i( i, j ), 0, Vector2i( ax, ay ) )


## 上沿：悬崖正面；左 / 右：侧壁；下沿：顶缘
func _paint_border() -> void:
	for x in COLS:
		set_cell( 0, Vector2i( x, 0 ), 0, Vector2i( 11 + x % 3, 7 ) )
		set_cell( 0, Vector2i( x, ROWS - 1 ), 0, Vector2i( 11 + x % 3, 4 ) )
	for y in range( 1, ROWS - 1 ):
		set_cell( 0, Vector2i( 0, y ), 0, Vector2i( 14, 5 + y % 2 ) )
		set_cell( 0, Vector2i( COLS - 1, y ), 0, Vector2i( 10, 5 + y % 2 ) )


## 高台：左右是侧壁，最下一行是悬崖正面，中间是草
func _paint_ledge( r : Rect2i ) -> void:
	for j in r.size.y:
		for i in r.size.x:
			var cell := r.position + Vector2i( i, j )
			var last_row : bool = j == r.size.y - 1
			var tile : Vector2i
			if i == 0:
				tile = Vector2i( 10, 7 ) if last_row else Vector2i( 10, 5 + j % 2 )
			elif i == r.size.x - 1:
				tile = Vector2i( 14, 7 ) if last_row else Vector2i( 14, 5 + j % 2 )
			elif last_row:
				tile = Vector2i( 12, 7 )
			else:
				tile = Vector2i( 0, 0 )
			set_cell( 0, cell, 0, tile )


func _build_colliders() -> void:
	# 边界：ARENA_RECT 外面一圈（主角半径 10、敌人最大约 10 的余量），贴着场地往外延伸
	var walls := StaticBody2D.new()
	walls.name = "Bounds"
	walls.collision_layer = WALLS_LAYER
	walls.collision_mask = 0
	add_child( walls )
	var a : Rect2 = HandController.ARENA_RECT
	# 上沿的碰撞在 y < 28：站在高台上的弓手出箭点（约 y 33）不会落在里面
	_add_rect( walls, Rect2( -200.0, -200.0, 912.0, 228.0 ) )
	_add_rect( walls, Rect2( -200.0, a.end.y + 12.0, 912.0, 200.0 ) )
	_add_rect( walls, Rect2( -200.0, -200.0, 200.0 + a.position.x - 12.0, 700.0 ) )
	_add_rect( walls, Rect2( a.end.x + 12.0, -200.0, 200.0, 700.0 ) )

	var ledge := StaticBody2D.new()
	ledge.name = "Ledges"
	ledge.collision_layer = LEDGE_LAYER
	ledge.collision_mask = 0
	add_child( ledge )
	for r in get_ledge_rects():
		var top := -64.0 if is_zero_approx( r.position.y ) else r.position.y
		_add_rect( ledge, Rect2( r.position.x, top, r.size.x, r.end.y - top - LEDGE_BOTTOM_TRIM ) )


func _add_rect( body : StaticBody2D, rect : Rect2 ) -> void:
	var shape := CollisionShape2D.new()
	var rs := RectangleShape2D.new()
	rs.size = rect.size
	shape.shape = rs
	shape.position = rect.get_center()
	body.add_child( shape )
