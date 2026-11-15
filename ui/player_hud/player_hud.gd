extends CanvasLayer


var hearts : Array[ HeartGUI ] = []

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	$Control.theme = DungeonTheme.THEME
	var frame := Panel.new()
	frame.position = Vector2( 352, 4 )
	frame.size = Vector2( 96, 46 )
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = DungeonTheme.BACKGROUND
	style.border_color = DungeonTheme.GOLD
	style.set_border_width_all( 1 )
	frame.add_theme_stylebox_override( "panel", style )
	$Control.add_child( frame )
	$Control.move_child( frame, 0 )
	for child in $Control/HFlowContainer.get_children():
		if child is HeartGUI:
			hearts.append( child )
			child.visible = false
	pass # Replace with function body.

func update_hp( _hp : int , _max_hp : int ) -> void:
	update_max_hp( _max_hp )
	for i in _max_hp:
		update_heart( i, _hp)
		pass
	pass

## 回血时让可见的心形闪一下（亮一下再恢复）
func flash_heal() -> void:
	for h in hearts:
		if h.visible:
			h.modulate = Color( 2.2, 2.2, 2.2 )
			var tween := h.create_tween()
			tween.tween_property( h, "modulate", Color.WHITE, 0.45 )


func update_heart( _index : int, _hp : int ) -> void:
	var _value : int = clampi( _hp - _index * 2, 0, 2)
	hearts[ _index ].value = _value
	pass
	
func update_max_hp( _max_hp : int ) -> void:
	var _heart_count : int = roundi( _max_hp * 0.5)
	for i in hearts.size():
		if i < _heart_count:
			hearts[i].visible = true
		else:
			hearts[i].visible = false
	pass
