@tool
extends Node

## Shader wallpaper: a single full-rect ColorRect with a canvas_item shader.
##
## The shaders animate from TIME, so the provider only has to ask for a redraw
## at the wallpaper frame rate - all of the work stays on the GPU.

const WallpaperUtil = preload("wallpaper_util.gd")

const PRESET_AURORA := "aurora"
const PRESET_FLOW := "flow"
const PRESET_STARS := "stars"
const PRESET_SYNTH_WAVE := "synthwave"

# Bundled presets that live in their own file, so they can be edited directly.
const PRESET_FILES := {
	PRESET_SYNTH_WAVE: preload("presets/synthwave.gdshader")
}

const PRESETS := {
	PRESET_AURORA: """
shader_type canvas_item;

uniform vec3 color_deep : source_color = vec3(0.02, 0.04, 0.10);
uniform vec3 color_mid : source_color = vec3(0.08, 0.35, 0.45);
uniform vec3 color_high : source_color = vec3(0.45, 0.25, 0.75);

void fragment() {
	vec2 uv = UV;
	float t = TIME * 0.12;
	float band = sin(uv.x * 2.2 + t * 2.0 + sin(uv.y * 1.7 - t) * 1.6) * 0.5 + 0.5;
	float band2 = sin(uv.x * 3.7 - t * 1.4 + cos(uv.y * 2.3 + t * 0.8) * 2.2) * 0.5 + 0.5;
	vec3 color = mix(color_deep, color_mid, smoothstep(0.15, 0.85, uv.y + band * 0.25));
	color = mix(color, color_high, band2 * 0.45 * (1.0 - uv.y));
	float glow = pow(clamp(1.0 - abs(uv.y - 0.35) * 1.8, 0.0, 1.0), 3.0);
	color += color_mid * glow * 0.35;
	COLOR = vec4(color, 1.0);
}
""",
	PRESET_FLOW: """
shader_type canvas_item;

uniform vec3 color_a : source_color = vec3(0.05, 0.10, 0.25);
uniform vec3 color_b : source_color = vec3(0.20, 0.55, 0.75);
uniform vec3 color_c : source_color = vec3(0.65, 0.30, 0.55);

void fragment() {
	vec2 uv = UV;
	float t = TIME * 0.08;
	float mix1 = sin(uv.x * 1.6 + uv.y * 0.9 + t * 3.0) * 0.5 + 0.5;
	float mix2 = cos(uv.x * 2.4 - uv.y * 1.7 - t * 2.0) * 0.5 + 0.5;
	vec3 color = mix(color_a, color_b, mix1);
	color = mix(color, color_c, mix2 * 0.55);
	COLOR = vec4(color, 1.0);
}
""",
	PRESET_STARS: """
shader_type canvas_item;

uniform vec3 sky_low : source_color = vec3(0.01, 0.02, 0.06);
uniform vec3 sky_high : source_color = vec3(0.05, 0.07, 0.20);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec2 uv = UV;
	vec3 color = mix(sky_low, sky_high, uv.y);
	vec2 grid = vec2(140.0, 80.0);
	vec2 cell = floor(uv * grid);
	vec2 within = fract(uv * grid);
	float seed = hash(cell);
	float twinkle = sin(TIME * (0.8 + seed * 2.5) + seed * 30.0) * 0.5 + 0.5;
	float distance_to_center = length(within - vec2(0.5));
	float star = (1.0 - smoothstep(0.0, 0.10, distance_to_center)) * twinkle * step(0.86, seed);
	color += vec3(star);
	COLOR = vec4(color, 1.0);
}
"""
}

var _rect: ColorRect


func build(parent: Control, source: Dictionary) -> bool:
	var code := ""
	var path := str(source.get("path", ""))
	var preset := str(source.get("preset", PRESET_AURORA))

	if path.to_lower().ends_with(".gdshader"):
		code = WallpaperUtil.load_shader_code(path)

	if code.strip_edges().is_empty():
		code = _preset_code(preset)

	if code.strip_edges().is_empty():
		return false

	var shader := Shader.new()
	shader.code = code

	var material := ShaderMaterial.new()
	material.shader = shader

	_rect = ColorRect.new()
	_rect.name = "ShaderLayer"
	_rect.color = Color.WHITE
	_rect.material = material
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.focus_mode = Control.FOCUS_NONE
	_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	parent.add_child(_rect)

	return true


func _preset_code(preset: String) -> String:
	var shader_resource: Shader = PRESET_FILES.get(preset)

	if shader_resource != null:
		return shader_resource.code

	return str(PRESETS.get(preset, PRESETS[PRESET_AURORA]))


func advance(_delta: float) -> void:
	if is_instance_valid(_rect):
		# TIME is a built-in shader uniform, so a redraw is all that is needed.
		_rect.queue_redraw()


func is_animated() -> bool:
	return true
