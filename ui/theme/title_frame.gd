extends Control
## Thin copper rails leave the dungeon theatre visible through the centre.


func _ready() -> void:
	resized.connect(queue_redraw)


func _draw() -> void:
	var bounds := Rect2(Vector2(8, 8), size - Vector2(16, 16))
	draw_rect(bounds, DungeonTheme.GOLD, false, 1.0)
	draw_rect(bounds.grow(-3), Color("#765536"), false, 1.0)
	for x in [14.0, size.x - 17.0]:
		for y in [14.0, size.y - 17.0]:
			draw_rect(Rect2(Vector2(x, y), Vector2(3, 3)), DungeonTheme.GOLD)
	# Short broken rule links the title and subtitle without covering the arena.
	for x in range(int(size.x * 0.5) - 66, int(size.x * 0.5) + 66, 10):
		draw_rect(Rect2(x, 85, 5, 2), DungeonTheme.GOLD)
