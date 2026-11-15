extends RefCounted
## Small, shared skin for the settings panel and its HUD entrance.

const GOLD := Color("#d7ad56")
const INK := Color("#f0dfb2")

static func frame(texture: Texture2D, margin: int, tint := Color.WHITE) -> StyleBoxTexture:
	var skin := StyleBoxTexture.new()
	skin.texture = texture
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		skin.set_texture_margin(side, margin)
		skin.set_content_margin(side, 4)
	skin.modulate_color = tint
	return skin

static func flat(color: Color, border: Color, width := 1) -> StyleBoxFlat:
	var skin := StyleBoxFlat.new()
	skin.bg_color = color
	skin.border_color = border
	skin.set_border_width_all(width)
	return skin

static func make_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font = preload("res://ui/fonts/abaddon_light.ttf")
	theme.default_font_size = 12
	theme.set_color("font_color", "Label", INK)
	var texture := preload("res://ui/settings/assets/button_frame.png")
	for state in ["normal", "hover", "pressed", "disabled"]:
		var tint: Color = {"normal": Color("#bca584"), "hover": Color("#ffe1a2"),
			"pressed": Color("#9e805b"), "disabled": Color("#665d53")}[state]
		theme.set_stylebox(state, "Button", frame(texture, 6, tint))
	theme.set_stylebox("focus", "Button", flat(Color.TRANSPARENT, GOLD))
	theme.set_color("font_color", "Button", INK)
	theme.set_color("font_hover_color", "Button", Color.WHITE)
	theme.set_color("font_pressed_color", "Button", GOLD)
	theme.set_color("font_focus_color", "Button", INK)
	theme.set_color("font_disabled_color", "Button", Color("#827462"))
	theme.set_stylebox("slider", "HSlider", flat(Color("#291b17"), Color("#6f7270")))
	theme.set_stylebox("grabber_area", "HSlider", flat(Color("#65452c"), GOLD))
	theme.set_stylebox("grabber_area_highlight", "HSlider", flat(GOLD, INK))
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray([GOLD, INK])
	var grabber := GradientTexture2D.new()
	grabber.gradient = gradient
	grabber.width = 8
	grabber.height = 12
	theme.set_icon("grabber", "HSlider", grabber)
	theme.set_icon("grabber_highlight", "HSlider", grabber)
	theme.set_icon("grabber_disabled", "HSlider", grabber)
	theme.set_stylebox("focus", "HSlider", flat(Color.TRANSPARENT, GOLD))
	return theme
