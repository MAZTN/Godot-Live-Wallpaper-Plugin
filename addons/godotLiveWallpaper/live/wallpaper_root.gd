@tool
extends Control

## Root of the wallpaper layer.
##
## Owns exactly one provider at a time and drives it at a capped frame rate.
## Static wallpapers stop processing entirely, so a still image costs nothing
## beyond its own draw.

const ProviderStill = preload("provider_still.gd")
const ProviderSheet = preload("provider_sheet.gd")
const ProviderShader = preload("provider_shader.gd")

const PROVIDERS := {
	"image": ProviderStill,
	"sheet": ProviderSheet,
	"shader": ProviderShader
}

var _provider
var _content: Control
var _source: Dictionary = {}
var _fps := 24
var _animated := false
var _manual_paused := false
var _pause_on_blur := true
var _unfocused := false
var _accumulator := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	clip_contents = true
	set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_unfocused = true
		_refresh_pause_state()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_unfocused = false
		_refresh_pause_state()


func _process(delta: float) -> void:
	if not is_instance_valid(_provider):
		return

	var step := 1.0 / float(maxi(1, _fps))
	_accumulator += delta

	if _accumulator < step:
		return

	# Drop leftover time so a frame hitch does not fast-forward the animation.
	_accumulator = minf(_accumulator - step, step)
	_provider.advance(step)


func _exit_tree() -> void:
	_clear_provider()


func set_source(source: Dictionary) -> bool:
	var type := str(source.get("type", "image"))
	var provider_script: Script = PROVIDERS.get(type)

	if provider_script == null:
		push_error("[Live Wallpaper] Unknown wallpaper type: " + type)
		return false

	_clear_provider()

	var provider = provider_script.new()
	provider.name = "Provider"
	add_child(provider)

	var content := _create_content()

	if not provider.build(content, source):
		content.queue_free()
		provider.queue_free()
		push_error("[Live Wallpaper] Could not build wallpaper type: " + type)
		return false

	_content = content
	_provider = provider
	_source = source
	_fps = maxi(1, int(source.get("fps", 24)))
	_animated = provider.is_animated()
	_accumulator = 0.0
	_refresh_pause_state()

	return true


func set_fps(fps: int) -> void:
	_fps = maxi(1, fps)


func set_pause_on_blur(enabled: bool) -> void:
	_pause_on_blur = enabled
	_refresh_pause_state()


func set_paused(paused: bool) -> void:
	_manual_paused = paused
	_refresh_pause_state()


func is_animated() -> bool:
	return _animated


func get_source() -> Dictionary:
	return _source


func _create_content() -> Control:
	var content := Control.new()
	content.name = "WallpaperContent"
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.focus_mode = Control.FOCUS_NONE
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(content)

	return content


func _clear_provider() -> void:
	if is_instance_valid(_content):
		_content.queue_free()

	_content = null

	if is_instance_valid(_provider):
		if _provider.has_method("teardown"):
			_provider.teardown()

		_provider.queue_free()

	_provider = null
	_animated = false
	set_process(false)


func _refresh_pause_state() -> void:
	var paused := _manual_paused or (_pause_on_blur and _unfocused)

	set_process(_animated and not paused)

	if is_instance_valid(_provider) and _provider.has_method("set_paused"):
		_provider.set_paused(paused)
