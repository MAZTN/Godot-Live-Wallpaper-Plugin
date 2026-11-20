@tool
extends Node

## Static image wallpaper: one TextureRect stretched to cover the editor.
##
## Providers are duck-typed controllers owned by WallpaperRoot:
##   build(parent: Control, source: Dictionary) -> bool
##   advance(delta: float) -> void      (only called while animated)
##   is_animated() -> bool

const WallpaperUtil = preload("wallpaper_util.gd")

var _rect: TextureRect


func build(parent: Control, source: Dictionary) -> bool:
	var texture := WallpaperUtil.load_texture(str(source.get("path", "")))

	if texture == null:
		return false

	_rect = TextureRect.new()
	_rect.name = "StillLayer"
	_rect.texture = texture
	_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.focus_mode = Control.FOCUS_NONE
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	parent.add_child(_rect)

	return true


func advance(_delta: float) -> void:
	pass


func is_animated() -> bool:
	return false
