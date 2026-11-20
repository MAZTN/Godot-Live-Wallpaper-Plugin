@tool
extends RefCounted

## Shared helpers for wallpaper sources.
##
## Wallpapers may live anywhere on disk, so nothing here assumes the project
## filesystem. res:// resources still go through the resource loader so
## imported assets keep working.


static func normalize_path(path: String) -> String:
	return path.strip_edges().replace("\\", "/")


static func load_texture(path: String) -> Texture2D:
	var clean := normalize_path(path)

	if clean.is_empty():
		return null

	if clean.begins_with("res://"):
		return load(clean) as Texture2D

	if not FileAccess.file_exists(clean):
		return null

	var image := Image.load_from_file(clean)

	if image == null or image.is_empty():
		return null

	return ImageTexture.create_from_image(image)


static func load_shader_code(path: String) -> String:
	var clean := normalize_path(path)

	if clean.is_empty():
		return ""

	if clean.begins_with("res://"):
		var shader := load(clean) as Shader

		return "" if shader == null else shader.code

	if not FileAccess.file_exists(clean):
		return ""

	return FileAccess.get_file_as_string(clean)


static func detect_type(path: String, hframes: int, vframes: int) -> String:
	var clean := normalize_path(path).to_lower()

	if clean.ends_with(".gdshader"):
		return "shader"

	if clean.ends_with(".ogv"):
		return "video"

	if clean.ends_with(".tscn") or clean.ends_with(".scn"):
		return "scene"

	if hframes > 1 or vframes > 1:
		return "sheet"

	return "image"
