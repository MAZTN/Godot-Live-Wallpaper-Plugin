@tool
extends Node

## Sprite sheet wallpaper: a single Sprite2D drawing one quad, with the frame
## index stepped by WallpaperRoot.
##
## One texture and one quad for the whole animation, so the per-frame cost is an
## integer change plus a canvas redraw - no texture uploads, no CPU decode.

const WallpaperUtil = preload("wallpaper_util.gd")

var _sprite: Sprite2D
var _area: Control
var _frame_count := 1
var _current := 0


func build(parent: Control, source: Dictionary) -> bool:
	var texture := WallpaperUtil.load_texture(str(source.get("path", "")))

	if texture == null:
		return false

	var columns := maxi(1, int(source.get("hframes", 1)))
	var rows := maxi(1, int(source.get("vframes", 1)))

	_frame_count = maxi(1, columns * rows)
	_current = 0

	_sprite = Sprite2D.new()
	_sprite.name = "SheetLayer"
	_sprite.texture = texture
	_sprite.hframes = columns
	_sprite.vframes = rows
	_sprite.frame = 0
	_sprite.centered = true
	parent.add_child(_sprite)

	_area = parent
	_area.resized.connect(_fit)
	_fit()

	return true


func advance(_delta: float) -> void:
	if not is_instance_valid(_sprite) or _frame_count <= 1:
		return

	_current = (_current + 1) % _frame_count
	_sprite.frame = _current


func is_animated() -> bool:
	return _frame_count > 1


func _fit() -> void:
	if not is_instance_valid(_sprite) or not is_instance_valid(_area):
		return

	var texture := _sprite.texture

	if texture == null:
		return

	var frame_size := texture.get_size() / Vector2(
		float(maxi(1, _sprite.hframes)),
		float(maxi(1, _sprite.vframes))
	)

	if frame_size.x <= 0.0 or frame_size.y <= 0.0:
		return

	var area := _area.size

	if area.x <= 0.0 or area.y <= 0.0:
		return

	# Cover the editor: scale up until both axes are filled, then center.
	var factor := maxf(area.x / frame_size.x, area.y / frame_size.y)

	_sprite.scale = Vector2(factor, factor)
	_sprite.position = area * 0.5
