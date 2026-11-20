@tool
extends EditorPlugin

const WallpaperUtil = preload("live/wallpaper_util.gd")
const WallpaperRoot = preload("live/wallpaper_root.gd")
const UpdateChecker = preload("updatecheck.gd")

const DEFAULT_WALLPAPER_PATH := "res://addons/godotLiveWallpaper/assets/wallpaper.png"

const WALLPAPER_IMAGE_FILTER := "*.png, *.jpg, *.jpeg, *.webp, *.bmp, *.tga, *.svg, *.exr, *.hdr"
const WALLPAPER_SHADER_FILTER := "*.gdshader"

# UI font families, tried in this order until the OS has one of them.
const FONT_FAMILIES := [
	"Segoe UI", "SF Pro Text", "Helvetica Neue", "Ubuntu", "Cantarell",
	"Noto Sans", "DejaVu Sans", "Liberation Sans", "Arial", "sans-serif"
]

# Wallpaper types, in the order of the "Wallpaper type" option button.
const LIVE_TYPES := ["auto", "image", "sheet", "shader"]
const SHADER_PRESETS := ["aurora", "flow", "stars", "hollow_knight"]

const SETTINGS_PREFIX := "godotLiveWallpaper/"

# Settings target -> class of the editor dock that implements it. Docks are
# movable, so a dock is located by its content class, never by a slot name.
const DOCK_CLASS_BY_TARGET := {
	"scene_tree": "SceneTreeDock",
	"filesystem": "FileSystemDock",
	"inspector": "InspectorDock",
	"output": "EditorLog"
}

# Script editor background modes.
const SCRIPT_BG_WALLPAPER := 0
const SCRIPT_BG_CUSTOM := 1
const SCRIPT_BG_DEFAULT := 2

# How often the plugin makes sure the editor did not overwrite our styleboxes.
const REFRESH_INTERVAL := 0.4

# Full rebuild cadence (in refresh ticks) for changed dock layouts.
const REBUILD_EVERY := 25

var wallpaper_layer

var live_type_button: OptionButton
var live_sheet_box: HBoxContainer
var live_columns_spin: SpinBox
var live_rows_spin: SpinBox
var live_shader_box: HBoxContainer
var live_shader_preset: OptionButton
var live_fps_slider: HSlider
var live_fps_label: Label
var live_pause_check: CheckBox
var live_pause_button: Button

var wallpaper_manual_paused := false
var wallpaper_installed := false

# Root shown by the main screen tab ("📃 Wallpaper").
var settings_screen: Control
var settings_panel: VBoxContainer
var settings_dock: Node
var settings_in_dock := false

var enable_check: CheckBox
var opacity_slider: HSlider
var opacity_label: Label

var script_mode_button: OptionButton
var script_color_button: ColorPickerButton
var script_list_box: VBoxContainer
var script_list_slider: HSlider
var script_list_label: Label
var script_control_count := 0

var script_color_box: VBoxContainer
var transparency_box: VBoxContainer
var advanced_box: VBoxContainer
var developer_check: CheckBox
var ui_font_bold: Font

var update_checker
var update_check_timer: Timer
var update_status_label: Label
var update_button: Button
var update_installing := false

var wallpaper_path_edit: LineEdit
var wallpaper_preview: TextureRect
var wallpaper_dialog: EditorFileDialog

var target_checks: Dictionary = {}

# Every stylebox we have overridden.
# { "control": Control, "name": StringName, "original": StyleBox,
#   "had_override": bool, "applied": StyleBox }
var applied_styles: Array[Dictionary] = []

# Controls whose own drawing we fade through self_modulate (game view backdrop).
# { "control": Control, "original": Color }
var applied_modulates: Array[Dictionary] = []

var editor_settings: EditorSettings
var refresh_timer: Timer
var refresh_ticks := 0
var startup_ticks := 0
var apply_queued := false
var last_applied_total := -1
var toolbar_chain_logged := false
var top_strips_logged := false


func _enter_tree() -> void:
	editor_settings = EditorInterface.get_editor_settings()

	_install_settings_screen()
	_install_refresh_timer()
	_install_update_checker()

	call_deferred("_install_wallpaper")
	call_deferred("_queue_transparency_apply")


func _exit_tree() -> void:
	_clear_transparency()

	if refresh_timer != null:
		refresh_timer.stop()
		refresh_timer.queue_free()
		refresh_timer = null

	_remove_wallpaper()

	if is_instance_valid(update_check_timer):
		update_check_timer.stop()
		update_check_timer.queue_free()
		update_check_timer = null

	if is_instance_valid(update_checker):
		update_checker.queue_free()
		update_checker = null

	if is_instance_valid(wallpaper_dialog):
		wallpaper_dialog.queue_free()
		wallpaper_dialog = null

	if is_instance_valid(settings_dock):
		if has_method("remove_dock"):
			remove_dock(settings_dock)

		settings_dock.queue_free()
		settings_dock = null

	elif is_instance_valid(settings_screen):
		if settings_in_dock:
			remove_control_from_docks(settings_screen)

		settings_screen.queue_free()

	settings_screen = null
	settings_panel = null


# ---------------------------------------------------------
# MAIN SCREEN TAB
# ---------------------------------------------------------

func _has_main_screen() -> bool:
	# With EditorDock (Godot 4.6+) the workspace tab comes from the dock itself,
	# so only older editors need the legacy main screen registration.
	return not (ClassDB.class_exists("EditorDock") and has_method("add_dock"))


func _get_plugin_name() -> String:
	return "📃 Wallpaper"


func _make_visible(p_visible: bool) -> void:
	if not is_instance_valid(settings_screen):
		return

	if p_visible:
		settings_screen.show()
		return

	# Godot 4.6+ reparents main screen content into an EditorDock, which takes
	# care of hiding it. Older editors rely on this call.
	var parent := settings_screen.get_parent()

	if parent == null or parent.get_class() != "EditorDock":
		settings_screen.hide()


# ---------------------------------------------------------
# WALLPAPER
# ---------------------------------------------------------

func _install_wallpaper() -> void:
	var editor_root := EditorInterface.get_base_control()

	if editor_root == null:
		push_error("[Live Wallpaper] Editor root unavailable.")
		return

	if is_instance_valid(wallpaper_layer):
		return

	wallpaper_layer = WallpaperRoot.new()
	wallpaper_layer.name = "LiveWallpaperBackground"

	editor_root.add_child(wallpaper_layer)
	editor_root.move_child(wallpaper_layer, 0)

	wallpaper_installed = true

	if not _apply_wallpaper_source():
		push_error("[Live Wallpaper] No wallpaper could be loaded.")
		return

	if _developer_mode():
		print("[Live Wallpaper] Wallpaper installed: ", _get_wallpaper_path())


func _remove_wallpaper() -> void:
	if is_instance_valid(wallpaper_layer):
		wallpaper_layer.queue_free()

	wallpaper_layer = null
	wallpaper_installed = false


func _ensure_wallpaper_layer() -> void:
	# The dock manager rebuilds the editor UI on layout changes; make sure the
	# wallpaper node survived instead of silently losing it.
	if not wallpaper_installed:
		return

	if is_instance_valid(wallpaper_layer) and wallpaper_layer.is_inside_tree():
		return

	if is_instance_valid(wallpaper_layer):
		wallpaper_layer.queue_free()

	wallpaper_layer = null
	_install_wallpaper()


func _get_wallpaper_path() -> String:
	var path := str(_get_setting("wallpaper", DEFAULT_WALLPAPER_PATH))

	return DEFAULT_WALLPAPER_PATH if path.is_empty() else path


func _load_wallpaper_texture(path: String) -> Texture2D:
	return WallpaperUtil.load_texture(path)


func _apply_wallpaper_path(path: String) -> void:
	path = WallpaperUtil.normalize_path(path)

	if path.is_empty():
		return

	var is_shader := path.to_lower().ends_with(".gdshader")
	var texture := _load_wallpaper_texture(path)

	if texture == null and not is_shader:
		push_error("[Live Wallpaper] Failed to load wallpaper: " + path)
		return

	_save_setting("wallpaper", path)

	if is_instance_valid(wallpaper_path_edit):
		wallpaper_path_edit.text = path

	# A shader path is unambiguous, so switch the type instead of trying to
	# read it as an image.
	if is_shader:
		_save_setting("live_type", "shader")
		_sync_live_type_button()

	if is_instance_valid(wallpaper_layer):
		_apply_wallpaper_source()
	else:
		_install_wallpaper()

	if _developer_mode():
		print("[Live Wallpaper] Wallpaper changed: ", path)


# ---------------------------------------------------------
# LIVE WALLPAPER SOURCES
# ---------------------------------------------------------

func _resolve_live_type() -> String:
	var type := str(_get_setting("live_type", "auto"))

	if type != "auto":
		return type

	return WallpaperUtil.detect_type(
		_get_wallpaper_path(),
		maxi(1, int(_get_setting("live_hframes", 1))),
		maxi(1, int(_get_setting("live_vframes", 1)))
	)


func _live_type_index(type: String) -> int:
	var index := LIVE_TYPES.find(type)

	return 0 if index < 0 else index


func _build_wallpaper_source() -> Dictionary:
	return {
		"type": _resolve_live_type(),
		"path": _get_wallpaper_path(),
		"hframes": maxi(1, int(_get_setting("live_hframes", 1))),
		"vframes": maxi(1, int(_get_setting("live_vframes", 1))),
		"fps": maxi(1, int(_get_setting("live_fps", 24))),
		"preset": str(_get_setting("live_shader_preset", "aurora"))
	}


func _apply_wallpaper_source() -> bool:
	_update_live_control_visibility()

	if not is_instance_valid(wallpaper_layer):
		return false

	if wallpaper_layer.set_source(_build_wallpaper_source()):
		_push_wallpaper_state()
		return true

	# Never leave the editor without a background: fall back to the bundled one.
	var fallback := {
		"type": "image",
		"path": DEFAULT_WALLPAPER_PATH,
		"fps": 24
	}

	if wallpaper_layer.set_source(fallback):
		push_warning(
			"[Live Wallpaper] Could not use \""
			+ _get_wallpaper_path()
			+ "\", showing the bundled wallpaper."
		)
		_push_wallpaper_state()
		return true

	push_error("[Live Wallpaper] Could not load any wallpaper.")
	return false


func _push_wallpaper_state() -> void:
	if not is_instance_valid(wallpaper_layer):
		return

	wallpaper_layer.set_fps(maxi(1, int(_get_setting("live_fps", 24))))
	wallpaper_layer.set_pause_on_blur(
		bool(_get_setting("live_pause_on_blur", true))
	)
	wallpaper_layer.set_paused(wallpaper_manual_paused)

	var texture := _load_wallpaper_texture(_get_wallpaper_path())

	if texture != null:
		_update_wallpaper_preview(texture)


func _update_live_control_visibility() -> void:
	var type := _resolve_live_type()

	if is_instance_valid(live_sheet_box):
		live_sheet_box.visible = type == "sheet"

	if is_instance_valid(live_shader_box):
		live_shader_box.visible = type == "shader"


func _update_live_fps_label(value: float) -> void:
	if is_instance_valid(live_fps_label):
		live_fps_label.text = "%d fps" % int(round(value))


func _sync_live_type_button() -> void:
	if is_instance_valid(live_type_button):
		live_type_button.select(
			_live_type_index(str(_get_setting("live_type", "auto")))
		)


func _on_live_type_changed(index: int) -> void:
	_save_setting(
		"live_type",
		LIVE_TYPES[clampi(index, 0, LIVE_TYPES.size() - 1)]
	)
	_apply_wallpaper_source()


func _on_sheet_columns_changed(value: float) -> void:
	_save_setting("live_hframes", maxi(1, int(value)))
	_apply_wallpaper_source()


func _on_sheet_rows_changed(value: float) -> void:
	_save_setting("live_vframes", maxi(1, int(value)))
	_apply_wallpaper_source()


func _on_shader_preset_changed(index: int) -> void:
	_save_setting(
		"live_shader_preset",
		SHADER_PRESETS[clampi(index, 0, SHADER_PRESETS.size() - 1)]
	)
	_apply_wallpaper_source()


func _on_live_fps_changed(value: float) -> void:
	_save_setting("live_fps", maxi(1, int(value)))
	_update_live_fps_label(value)

	if is_instance_valid(wallpaper_layer):
		wallpaper_layer.set_fps(maxi(1, int(value)))


func _on_pause_on_blur_changed(pressed: bool) -> void:
	_save_setting("live_pause_on_blur", pressed)

	if is_instance_valid(wallpaper_layer):
		wallpaper_layer.set_pause_on_blur(pressed)


func _on_pause_toggled(pressed: bool) -> void:
	wallpaper_manual_paused = pressed

	if is_instance_valid(live_pause_button):
		live_pause_button.text = (
			"Resume wallpaper" if pressed else "Pause wallpaper"
		)

	if is_instance_valid(wallpaper_layer):
		wallpaper_layer.set_paused(pressed)


func _update_wallpaper_preview(texture: Texture2D) -> void:
	if is_instance_valid(wallpaper_preview):
		wallpaper_preview.texture = texture


func _on_wallpaper_path_submitted(path: String) -> void:
	_apply_wallpaper_path(path.strip_edges())


func _on_browse_wallpaper_pressed() -> void:
	if not is_instance_valid(wallpaper_dialog):
		wallpaper_dialog = EditorFileDialog.new()
		wallpaper_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		wallpaper_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		wallpaper_dialog.title = "Choose a wallpaper"
		wallpaper_dialog.add_filter(WALLPAPER_IMAGE_FILTER)
		wallpaper_dialog.file_selected.connect(_on_wallpaper_file_selected)
		add_child(wallpaper_dialog)

	wallpaper_dialog.clear_filters()
	wallpaper_dialog.add_filter(WALLPAPER_IMAGE_FILTER)

	if _resolve_live_type() == "shader":
		wallpaper_dialog.add_filter(WALLPAPER_SHADER_FILTER)

	wallpaper_dialog.popup_centered_ratio(0.6)


func _on_wallpaper_file_selected(path: String) -> void:
	_apply_wallpaper_path(path)


func _on_bundled_wallpaper_pressed() -> void:
	_save_setting("live_type", "image")
	_sync_live_type_button()
	_apply_wallpaper_path(DEFAULT_WALLPAPER_PATH)


# ---------------------------------------------------------
# SETTINGS SCREEN (main screen tab)
# ---------------------------------------------------------

func _install_settings_screen() -> void:
	settings_panel = VBoxContainer.new()
	settings_panel.name = "Live Wallpaper Settings"
	settings_panel.custom_minimum_size = Vector2(300, 0)
	settings_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings_panel.add_theme_constant_override("separation", 12)

	ui_font_bold = _make_ui_font(700)

	var intro := VBoxContainer.new()
	intro.add_theme_constant_override("separation", 2)
	settings_panel.add_child(intro)

	var title := Label.new()
	title.text = "Make it yours"
	title.add_theme_font_size_override("font_size", 26)

	if ui_font_bold != null:
		title.add_theme_font_override("font", ui_font_bold)

	intro.add_child(title)
	intro.add_child(
		_make_hint("A wallpaper behind your editor, with panels you can see through.")
	)

	_build_wallpaper_card()
	_build_motion_card()
	_build_panels_card()
	_build_code_card()
	_build_updates_card()
	_build_troubleshooting_card()

	var margin := MarginContainer.new()
	margin.name = "WallpaperContent"
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 18)
	margin.add_child(settings_panel)

	var scroll := ScrollContainer.new()
	scroll.name = "Wallpaper"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(margin)
	scroll.theme = _make_ui_theme(_make_ui_font(400))

	settings_screen = scroll

	_install_settings_tab()


func _build_wallpaper_card() -> void:
	var card := _add_card(
		"Wallpaper",
		"Pick any picture. A file anywhere on your computer works too."
	)

	wallpaper_preview = TextureRect.new()
	wallpaper_preview.custom_minimum_size = Vector2(300, 150)
	wallpaper_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wallpaper_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	wallpaper_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(wallpaper_preview)

	var path_row := HBoxContainer.new()
	path_row.add_theme_constant_override("separation", 6)
	card.add_child(path_row)

	wallpaper_path_edit = LineEdit.new()
	wallpaper_path_edit.text = _get_wallpaper_path()
	wallpaper_path_edit.placeholder_text = "res:// or a path on your computer"
	wallpaper_path_edit.tooltip_text = "Type a path and press Enter to use it."
	wallpaper_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wallpaper_path_edit.text_submitted.connect(_on_wallpaper_path_submitted)
	path_row.add_child(wallpaper_path_edit)

	var browse_button := Button.new()
	browse_button.text = "Browse..."
	browse_button.tooltip_text = "Choose a picture from your computer."
	browse_button.pressed.connect(_on_browse_wallpaper_pressed)
	path_row.add_child(browse_button)

	var bundled_button := Button.new()
	bundled_button.text = "Use the bundled wallpaper"
	bundled_button.tooltip_text = "Go back to the picture that ships with the plugin."
	bundled_button.pressed.connect(_on_bundled_wallpaper_pressed)
	card.add_child(bundled_button)

	_update_wallpaper_preview(_load_wallpaper_texture(_get_wallpaper_path()))


func _build_motion_card() -> void:
	var card := _add_card(
		"Movement",
		"A still picture is fine. Animated ones simply move."
	)

	var type_row := _add_row(card, "Wallpaper type")

	live_type_button = OptionButton.new()
	live_type_button.add_item("Auto detect")
	live_type_button.add_item("Still image")
	live_type_button.add_item("Sprite sheet")
	live_type_button.add_item("Shader")
	live_type_button.select(
		_live_type_index(str(_get_setting("live_type", "auto")))
	)
	live_type_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	live_type_button.item_selected.connect(_on_live_type_changed)
	type_row.add_child(live_type_button)

	live_sheet_box = HBoxContainer.new()
	live_sheet_box.add_theme_constant_override("separation", 6)
	card.add_child(live_sheet_box)

	live_sheet_box.add_child(_make_label("Columns"))

	live_columns_spin = SpinBox.new()
	live_columns_spin.min_value = 1
	live_columns_spin.max_value = 64
	live_columns_spin.step = 1
	live_columns_spin.value = maxi(1, int(_get_setting("live_hframes", 1)))
	live_columns_spin.tooltip_text = "How many frames across the sprite sheet."
	live_columns_spin.value_changed.connect(_on_sheet_columns_changed)
	live_sheet_box.add_child(live_columns_spin)

	live_sheet_box.add_child(_make_label("Rows"))

	live_rows_spin = SpinBox.new()
	live_rows_spin.min_value = 1
	live_rows_spin.max_value = 64
	live_rows_spin.step = 1
	live_rows_spin.value = maxi(1, int(_get_setting("live_vframes", 1)))
	live_rows_spin.tooltip_text = "How many frames down the sprite sheet."
	live_rows_spin.value_changed.connect(_on_sheet_rows_changed)
	live_sheet_box.add_child(live_rows_spin)

	live_shader_box = HBoxContainer.new()
	live_shader_box.add_theme_constant_override("separation", 6)
	card.add_child(live_shader_box)

	live_shader_box.add_child(_make_label("Effect"))

	live_shader_preset = OptionButton.new()
	live_shader_preset.add_item("Aurora")
	live_shader_preset.add_item("Flowing gradient")
	live_shader_preset.add_item("Starfield")
	live_shader_preset.select(
		maxi(
			0,
			SHADER_PRESETS.find(str(_get_setting("live_shader_preset", "aurora")))
		)
	)
	live_shader_preset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	live_shader_preset.item_selected.connect(_on_shader_preset_changed)
	live_shader_box.add_child(live_shader_preset)

	var speed_row := _add_row(card, "Speed")

	live_fps_slider = HSlider.new()
	live_fps_slider.min_value = 6
	live_fps_slider.max_value = 60
	live_fps_slider.step = 1
	live_fps_slider.value = maxi(1, int(_get_setting("live_fps", 24)))
	live_fps_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	live_fps_slider.tooltip_text = "Lower is calmer and lighter on your graphics card."
	live_fps_slider.value_changed.connect(_on_live_fps_changed)
	speed_row.add_child(live_fps_slider)

	live_fps_label = Label.new()
	live_fps_label.custom_minimum_size = Vector2(60, 0)
	live_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	speed_row.add_child(live_fps_label)
	_update_live_fps_label(live_fps_slider.value)

	live_pause_check = CheckBox.new()
	live_pause_check.text = "Pause while I am not using the editor"
	live_pause_check.button_pressed = bool(_get_setting("live_pause_on_blur", true))
	live_pause_check.tooltip_text = "Saves power when the editor is in the background."
	live_pause_check.toggled.connect(_on_pause_on_blur_changed)
	card.add_child(live_pause_check)

	live_pause_button = Button.new()
	live_pause_button.text = "Pause wallpaper"
	live_pause_button.toggle_mode = true
	live_pause_button.toggled.connect(_on_pause_toggled)
	card.add_child(live_pause_button)

	card.add_child(
		_make_hint(
			"Auto detect looks at the file itself: sprites and shaders move, "
			+ "everything else stays still."
		)
	)

	_update_live_control_visibility()


func _build_panels_card() -> void:
	var card := _add_card(
		"See-through panels",
		"Choose how much of the wallpaper shows through the editor."
	)

	enable_check = CheckBox.new()
	enable_check.text = "Make editor panels see-through"
	enable_check.button_pressed = _get_setting("enabled", true)
	enable_check.toggled.connect(_on_enabled_changed)
	card.add_child(enable_check)

	transparency_box = VBoxContainer.new()
	transparency_box.add_theme_constant_override("separation", 6)
	card.add_child(transparency_box)

	var opacity_row := _add_row(transparency_box, "Solidity")

	opacity_slider = HSlider.new()
	opacity_slider.min_value = 0
	opacity_slider.max_value = 100
	opacity_slider.step = 1
	opacity_slider.value = _get_setting("opacity", 65)
	opacity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opacity_slider.tooltip_text = "0% shows the wallpaper fully, 100% hides it."
	opacity_slider.value_changed.connect(_on_opacity_changed)
	opacity_row.add_child(opacity_slider)

	opacity_label = Label.new()
	opacity_label.custom_minimum_size = Vector2(60, 0)
	opacity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	opacity_row.add_child(opacity_label)
	_update_opacity_label(opacity_slider.value)

	transparency_box.add_child(_make_section_title("Parts of the editor"))
	_add_target_checkbox(transparency_box, "Scene Tree", "scene_tree")
	_add_target_checkbox(transparency_box, "FileSystem", "filesystem")
	_add_target_checkbox(transparency_box, "Inspector", "inspector")
	_add_target_checkbox(transparency_box, "Output", "output")
	_add_target_checkbox(transparency_box, "Top bar and Game view", "main_editor")

	transparency_box.add_child(
		_make_hint("Untick anything you would rather keep solid.")
	)

	_update_transparency_controls_visibility()


func _build_code_card() -> void:
	var card := _add_card("Code editor", "What sits behind your scripts.")

	var mode_row := _add_row(card, "Background")

	script_mode_button = OptionButton.new()
	script_mode_button.add_item("Use the wallpaper", SCRIPT_BG_WALLPAPER)
	script_mode_button.add_item("Solid color", SCRIPT_BG_CUSTOM)
	script_mode_button.add_item("Editor default", SCRIPT_BG_DEFAULT)
	script_mode_button.select(
		int(_get_setting("script_background", SCRIPT_BG_WALLPAPER))
	)
	script_mode_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	script_mode_button.item_selected.connect(_on_script_mode_changed)
	mode_row.add_child(script_mode_button)

	script_color_box = VBoxContainer.new()
	script_color_box.add_theme_constant_override("separation", 4)
	card.add_child(script_color_box)

	script_color_box.add_child(_make_section_title("Solid color"))

	script_color_button = ColorPickerButton.new()
	script_color_button.color = _get_setting(
		"script_color",
		Color(0.11, 0.11, 0.13, 1.0)
	)
	script_color_button.edit_alpha = true
	script_color_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	script_color_button.color_changed.connect(_on_script_color_changed)
	script_color_box.add_child(script_color_button)

	script_list_box = VBoxContainer.new()
	script_list_box.add_theme_constant_override("separation", 4)
	card.add_child(script_list_box)

	var list_row := _add_row(script_list_box, "Script list")

	script_list_slider = HSlider.new()
	script_list_slider.min_value = 0
	script_list_slider.max_value = 100
	script_list_slider.step = 1
	script_list_slider.value = float(_get_setting("script_list_opacity", 65))
	script_list_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	script_list_slider.tooltip_text = "How solid the script list and its filter box look."
	script_list_slider.value_changed.connect(_on_script_list_opacity_changed)
	list_row.add_child(script_list_slider)

	script_list_label = Label.new()
	script_list_label.custom_minimum_size = Vector2(60, 0)
	script_list_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	list_row.add_child(script_list_label)
	_update_script_list_label(script_list_slider.value)

	_update_script_controls_visibility()


func _build_updates_card() -> void:
	var card := _add_card(
		"Updates",
		"Checks GitHub for a newer version of the plugin."
	)

	update_status_label = _make_hint(
		"You are on version %s." % _get_plugin_version()
	)
	card.add_child(update_status_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	card.add_child(row)

	var check_button := Button.new()
	check_button.text = "Check now"
	check_button.tooltip_text = "Ask GitHub for the newest version."
	check_button.pressed.connect(_on_check_updates_pressed)
	row.add_child(check_button)

	update_button = Button.new()
	update_button.text = "Install update"
	update_button.tooltip_text = "Download the newest version into this project."
	update_button.disabled = true
	update_button.pressed.connect(_on_install_update_pressed)
	row.add_child(update_button)


func _install_update_checker() -> void:
	update_checker = UpdateChecker.new()
	update_checker.name = "UpdateChecker"
	update_checker.status_changed.connect(_on_update_status_changed)
	update_checker.install_finished.connect(_on_update_install_finished)
	add_child(update_checker)

	# Ask once a few seconds after start, so a slow network never delays the
	# editor from opening.
	update_check_timer = Timer.new()
	update_check_timer.name = "UpdateCheckTimer"
	update_check_timer.one_shot = true
	update_check_timer.wait_time = 3.0
	update_check_timer.timeout.connect(_on_update_check_timeout)
	add_child(update_check_timer)
	update_check_timer.start()


func _developer_mode() -> bool:
	return bool(_get_setting("developer_mode", false))


func _on_developer_mode_changed(pressed: bool) -> void:
	_save_setting("developer_mode", pressed)

	if is_instance_valid(advanced_box):
		advanced_box.visible = pressed


func _on_update_check_timeout() -> void:
	if is_instance_valid(update_checker):
		update_checker.check(_get_plugin_version(), false)


func _get_plugin_version() -> String:
	var config := ConfigFile.new()

	if config.load("res://addons/godotLiveWallpaper/plugin.cfg") != OK:
		return "unknown"

	return str(config.get_value("plugin", "version", "unknown"))


func _on_check_updates_pressed() -> void:
	if not is_instance_valid(update_checker):
		return

	if is_instance_valid(update_status_label):
		update_status_label.text = "Checking for updates..."

	update_checker.check(_get_plugin_version(), true)


func _on_install_update_pressed() -> void:
	if not is_instance_valid(update_checker) or not update_checker.update_available:
		return

	var dialog := ConfirmationDialog.new()
	dialog.title = "Install update"
	dialog.dialog_text = (
		"Download version %s and replace the plugin files?\n\n"
		+ "Save your work first: the project has to be reloaded afterwards."
	) % update_checker.latest_version
	dialog.confirmed.connect(
		func() -> void:
			dialog.queue_free()
			_start_update_install()
	)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


func _start_update_install() -> void:
	update_installing = true

	if is_instance_valid(update_button):
		update_button.disabled = true

	if is_instance_valid(update_checker):
		update_checker.install()


func _on_update_status_changed(text: String, has_update: bool) -> void:
	if is_instance_valid(update_status_label):
		update_status_label.text = text
		update_status_label.modulate = (
			Color(1.0, 0.86, 0.35) if has_update else Color(1, 1, 1, 0.62)
		)

	if is_instance_valid(update_button):
		update_button.disabled = (
			update_installing
			or not is_instance_valid(update_checker)
			or not update_checker.update_available
		)


func _on_update_install_finished(success: bool, message: String) -> void:
	update_installing = false

	var color := "green" if success else "red"
	print_rich("[color=" + color + "][b][Live Wallpaper][/b] " + message + "[/color]")

	if is_instance_valid(update_status_label):
		update_status_label.text = message

	if not success:
		if is_instance_valid(update_button):
			update_button.disabled = false

		return

	EditorInterface.get_resource_filesystem().scan()
	print_rich(
		"[color=yellow][b][Live Wallpaper][/b] Reload the project "
		+ "(Project > Reload Current Project) to finish the update.[/color]"
	)


func _build_troubleshooting_card() -> void:
	var card := _add_card(
		"Something looks off?",
		"Only needed if a panel does not behave."
	)

	developer_check = CheckBox.new()
	developer_check.text = "Developer mode"
	developer_check.button_pressed = _developer_mode()
	developer_check.tooltip_text = (
		"Prints wallpaper, transparency and panel details to the Output panel."
	)
	developer_check.toggled.connect(_on_developer_mode_changed)
	card.add_child(developer_check)

	advanced_box = VBoxContainer.new()
	advanced_box.visible = _developer_mode()
	advanced_box.add_theme_constant_override("separation", 6)
	card.add_child(advanced_box)

	advanced_box.add_child(
		_make_hint(
			"Writes the background colors the editor uses for each panel "
			+ "to the Output panel."
		)
	)

	var inspect_button := Button.new()
	inspect_button.text = "Inspect panel backgrounds"
	inspect_button.pressed.connect(_print_stylebox_report)
	advanced_box.add_child(inspect_button)


func _add_card(title: String, subtitle: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _make_card_style())
	settings_panel.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var heading := Label.new()
	heading.text = title
	heading.add_theme_font_size_override("font_size", 17)

	if ui_font_bold != null:
		heading.add_theme_font_override("font", ui_font_bold)

	column.add_child(heading)

	if not subtitle.is_empty():
		column.add_child(_make_hint(subtitle))

	return column


func _add_row(parent: VBoxContainer, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var label := _make_label(text)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(label)

	return row


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _make_section_title(text: String) -> Label:
	var label := _make_label(text)
	label.add_theme_font_size_override("font_size", 13)
	label.modulate = Color(1, 1, 1, 0.85)

	if ui_font_bold != null:
		label.add_theme_font_override("font", ui_font_bold)

	return label


func _make_hint(text: String) -> Label:
	var hint := _make_label(text)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.62)
	return hint


# A friendly system font when the OS has one, otherwise the editor font.
func _make_ui_font(weight: int) -> Font:
	if not ClassDB.class_exists("SystemFont"):
		return null

	var font := ClassDB.instantiate("SystemFont") as Font

	if font == null:
		return null

	font.set("font_names", PackedStringArray(FONT_FAMILIES))
	font.set("font_weight", weight)
	font.set("antialiasing", TextServer.FONT_ANTIALIASING_GRAY)
	return font


func _make_ui_theme(body: Font) -> Theme:
	if body == null:
		return null

	var ui_theme := Theme.new()

	for type_name in [
		"Label", "Button", "CheckBox", "OptionButton", "LineEdit",
		"MenuButton", "LinkButton"
	]:
		ui_theme.set_font("font", type_name, body)

	return ui_theme


# Cards follow the editor theme, so they read correctly light or dark.
func _make_card_style() -> StyleBoxFlat:
	var base := Color(0.15, 0.16, 0.19)
	var editor_theme := EditorInterface.get_editor_theme()

	if editor_theme != null:
		var panel_style := editor_theme.get_stylebox("panel", "Panel")

		if panel_style is StyleBoxFlat:
			base = (panel_style as StyleBoxFlat).bg_color

	var light := base.get_luminance() > 0.5
	var style := StyleBoxFlat.new()
	style.bg_color = base.lightened(0.05) if light else base.lightened(0.04)
	style.border_color = base.darkened(0.10) if light else base.lightened(0.08)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.anti_aliasing = true
	return style


func _install_settings_tab() -> void:
	if ClassDB.class_exists("EditorDock") and has_method("add_dock"):
		_install_settings_dock_tab()
		return

	_install_legacy_main_screen()


func _install_settings_dock_tab() -> void:
	# A dock in the main screen slot becomes a tab in the workspace selector,
	# next to 2D/3D/Script/Game/Asset Store (that is how Game view does it).
	var dock := ClassDB.instantiate("EditorDock") as Node

	if dock == null:
		_install_legacy_main_screen()
		return

	dock.name = "WallpaperDock"
	dock.set("title", "📃 Wallpaper")
	dock.set("closable", false)
	dock.set(
		"default_slot",
		ClassDB.class_get_integer_constant("EditorDock", "DOCK_SLOT_MAIN_SCREEN")
	)
	dock.set(
		"available_layouts",
		ClassDB.class_get_integer_constant("EditorDock", "DOCK_LAYOUT_MAIN_SCREEN")
	)
	dock.add_child(settings_screen)

	settings_dock = dock

	add_dock(dock)

	if dock.get_parent() == null:
		# Dock registration failed; keep the settings reachable.
		dock.remove_child(settings_screen)
		dock.queue_free()
		settings_dock = null
		_fallback_settings_dock()


func _install_legacy_main_screen() -> void:
	var main_screen := EditorInterface.get_editor_main_screen()

	if main_screen == null:
		_fallback_settings_dock()
		return

	main_screen.add_child(settings_screen)
	_verify_legacy_main_screen()


func _verify_legacy_main_screen() -> void:
	# The editor reparents main screen content into a dock with a deferred call.
	# If that never happens, keep the UI reachable as a regular dock instead.
	for _attempt in 3:
		await get_tree().process_frame

		if not is_instance_valid(settings_screen):
			return

		var parent := settings_screen.get_parent()

		if parent != null and parent.get_class() == "EditorDock":
			return

	_fallback_settings_dock()


func _fallback_settings_dock() -> void:
	if not is_instance_valid(settings_screen):
		return

	# add_control_to_dock() requires the control to have no parent.
	var parent := settings_screen.get_parent()

	if parent != null:
		parent.remove_child(settings_screen)

	settings_in_dock = true
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, settings_screen)


func _add_target_checkbox(
	parent: Control,
	label_text: String,
	key: String
) -> void:
	var check := CheckBox.new()
	check.text = label_text
	check.button_pressed = _get_setting(key, true)

	check.toggled.connect(
		_on_target_changed.bind(key)
	)

	target_checks[key] = check
	parent.add_child(check)


# ---------------------------------------------------------
# SETTINGS EVENTS
# ---------------------------------------------------------

func _on_enabled_changed(value: bool) -> void:
	_save_setting("enabled", value)
	_update_transparency_controls_visibility()
	_queue_transparency_apply()


func _update_transparency_controls_visibility() -> void:
	if not is_instance_valid(transparency_box):
		return

	transparency_box.visible = (
		is_instance_valid(enable_check) and enable_check.button_pressed
	)


func _on_opacity_changed(value: float) -> void:
	_save_setting("opacity", value)
	_update_opacity_label(value)
	_queue_transparency_apply()


func _on_target_changed(value: bool, key: String) -> void:
	_save_setting(key, value)
	_queue_transparency_apply()


func _on_script_mode_changed(index: int) -> void:
	_save_setting("script_background", index)
	_update_script_controls_visibility()
	_queue_transparency_apply()


func _on_script_list_opacity_changed(value: float) -> void:
	_save_setting("script_list_opacity", value)
	_update_script_list_label(value)
	_queue_transparency_apply()


func _update_script_list_label(value: float) -> void:
	if is_instance_valid(script_list_label):
		script_list_label.text = "%d%%" % int(round(value))


func _on_script_color_changed(color: Color) -> void:
	_save_setting("script_color", color)
	_queue_transparency_apply()


func _update_script_controls_visibility() -> void:
	var mode := int(_get_setting("script_background", SCRIPT_BG_WALLPAPER))

	if is_instance_valid(script_color_box):
		script_color_box.visible = mode == SCRIPT_BG_CUSTOM

	# The list opacity only means something while the wallpaper shows through.
	if is_instance_valid(script_list_box):
		script_list_box.visible = mode == SCRIPT_BG_WALLPAPER


# Dragging the slider fires many times per frame, and applying means walking
# the whole editor tree, so coalesce everything into one pass per frame.
func _queue_transparency_apply() -> void:
	if apply_queued:
		return

	apply_queued = true
	call_deferred("_run_queued_transparency")


func _run_queued_transparency() -> void:
	apply_queued = false
	_apply_transparency()


func _update_opacity_label(value: float) -> void:
	opacity_label.text = "%d%%" % int(value)


func _get_setting(key: String, default_value: Variant) -> Variant:
	var full_key := SETTINGS_PREFIX + key

	if editor_settings.has_setting(full_key):
		return editor_settings.get_setting(full_key)

	editor_settings.set_setting(full_key, default_value)
	return default_value


func _save_setting(key: String, value: Variant) -> void:
	editor_settings.set_setting(
		SETTINGS_PREFIX + key,
		value
	)


func _is_target_enabled(key: String) -> bool:
	if not target_checks.has(key):
		return false

	var check: CheckBox = target_checks[key]
	return is_instance_valid(check) and check.button_pressed


# ---------------------------------------------------------
# TRANSPARENCY
# ---------------------------------------------------------

func _install_refresh_timer() -> void:
	var editor_root := EditorInterface.get_base_control()

	if editor_root == null:
		return

	refresh_timer = Timer.new()
	refresh_timer.name = "LiveWallpaperRefresh"
	refresh_timer.wait_time = REFRESH_INTERVAL
	refresh_timer.one_shot = false
	refresh_timer.timeout.connect(_on_refresh_timeout)

	editor_root.add_child(refresh_timer)
	refresh_timer.start()


func _on_refresh_timeout() -> void:
	_ensure_wallpaper_layer()

	if not is_instance_valid(enable_check) or not enable_check.button_pressed:
		return

	refresh_ticks += 1
	startup_ticks += 1

	# Docks are created after the plugin loads, so retry during the first
	# seconds instead of waiting for the next full rebuild.
	var dock_still_missing := (
		applied_styles.is_empty()
		and applied_modulates.is_empty()
		and startup_ticks <= 15
	)

	# Docks get recreated/reparented by the dock manager; re-collect when the
	# cached targets disappear, and occasionally anyway to pick up new ones.
	if (
		_has_stale_targets()
		or refresh_ticks >= REBUILD_EVERY
		or dock_still_missing
		or _script_editor_needs_rebuild()
	):
		_apply_transparency()
		refresh_ticks = 0
		return

	# The editor re-applies its own panel styles (the bottom panel does it on
	# every tab change), which silently throws our override away. Put it back.
	for entry in applied_styles:
		var control := _entry_control(entry)

		if control == null or not control.is_visible_in_tree():
			continue

		var style_name: StringName = entry["name"]

		if control.get_theme_stylebox(style_name) != entry["applied"]:
			control.add_theme_stylebox_override(
				style_name,
				entry["applied"] as StyleBox
			)

	for entry in applied_modulates:
		var control := _entry_control(entry)

		if control == null or not control.is_visible_in_tree():
			continue

		if not control.self_modulate.is_equal_approx(entry["target"] as Color):
			control.self_modulate = entry["target"] as Color


func _has_stale_targets() -> bool:
	for entry in applied_styles:
		if not is_instance_valid(entry["control"]):
			return true

	for entry in applied_modulates:
		if not is_instance_valid(entry["control"]):
			return true

	return false


func _apply_transparency() -> void:
	_clear_transparency()

	# The script editor background is a look of its own, so it stays applied
	# even when dock transparency is switched off.
	if not is_instance_valid(enable_check) or not enable_check.button_pressed:
		_apply_script_editor(1.0)
		return

	if not is_instance_valid(opacity_slider):
		return

	var editor_root := EditorInterface.get_base_control()
	if editor_root == null:
		return

	var opacity := float(opacity_slider.value) / 100.0
	var counts := {}
	var before := applied_styles.size()

	_scan_controls(editor_root, opacity)

	# Dock-based areas are found structurally, not by node name: the bottom
	# panel used to be the only special case, but Godot 4.6 replaced the dock
	# slots with named docks that can live in any slot.
	for area in ["scene_tree", "filesystem", "inspector", "output"]:
		before = applied_styles.size()
		_fade_dock_area(editor_root, area, opacity)
		counts[area] = applied_styles.size() - before

	before = applied_styles.size()
	_fade_main_editor(editor_root, opacity)
	counts["main_editor"] = applied_styles.size() - before

	before = applied_styles.size()
	_apply_script_editor(opacity)
	counts["script_editor"] = applied_styles.size() - before

	_print_apply_summary(counts)


func _print_apply_summary(counts: Dictionary) -> void:
	if not _developer_mode():
		return

	var total := applied_styles.size() + applied_modulates.size()

	if total == last_applied_total:
		return

	last_applied_total = total
	print("[Live Wallpaper] faded areas: ", counts, " (", total, " entries)")


func _scan_controls(node: Node, opacity: float) -> void:
	if node is Control:
		var control := node as Control

		if _should_modify_control(control):
			_apply_control_transparency(control, opacity)

	for child in node.get_children():
		_scan_controls(child, opacity)


func _get_control_path(control: Control) -> String:
	var parts: Array[String] = []
	var current: Node = control

	while current != null:
		parts.push_front(str(current.name).to_lower())
		current = current.get_parent()

	return "/" + "/".join(parts)


func _is_inside_target(path: String, key: String) -> bool:
	if not _is_target_enabled(key):
		return false

	match key:
		"scene_tree":
			return path.contains("/dockslotleftur")

		"filesystem":
			return path.contains("/dockslotleftbr")

		"inspector":
			return path.contains("/dockslotrightul")

		"main_editor":
			return (
				(
					path.contains("node3deditor")
					and path.contains("hflowcontainer")
				)
				or path.contains("/gameview/")
			)

	return false


func _should_modify_control(control: Control) -> bool:
	var path := _get_control_path(control)
	var c_name := control.get_class()

	# Scene Tree dock background.
	if (
		c_name == "SideDockTabContainer"
		and path.ends_with("/dockslotleftur")
		and _is_inside_target(path, "scene_tree")
	):
		return true

	# FileSystem dock background and file list.
	if (
		c_name == "SideDockTabContainer"
		and path.ends_with("/dockslotleftbr")
		and _is_inside_target(path, "filesystem")
	):
		return true

	if (
		c_name == "FileSystemList"
		and _is_inside_target(path, "filesystem")
	):
		return true

	# Inspector dock and category backgrounds.
	if (
		c_name == "SideDockTabContainer"
		and path.ends_with("/dockslotrightul")
		and _is_inside_target(path, "inspector")
	):
		return true

	if (
		c_name == "EditorInspectorCategory"
		and _is_inside_target(path, "inspector")
	):
		return true

	# Main Editor toolbar.
	if (
		c_name == "PanelContainer"
		and _is_inside_target(path, "main_editor")
	):
		return true

	# GameView background (older editor versions put a Panel on that path).
	if (
		c_name == "Panel"
		and path.contains("/gameview/")
		and _is_inside_target(path, "main_editor")
	):
		return true

	return false


func _apply_control_transparency(
	control: Control,
	opacity: float
) -> void:
	var style_names: Array = []

	match control.get_class():
		"SideDockTabContainer":
			style_names = [&"panel"]

		"FileSystemList":
			style_names = [&"panel"]

		"EditorInspectorCategory":
			style_names = [&"bg"]

		"PanelContainer":
			style_names = [&"panel"]

		"Panel":
			style_names = [&"panel"]

	_fade_styleboxes(control, style_names, opacity)


# ---------------------------------------------------------
# DOCK AREAS
# ---------------------------------------------------------
#
# Godot 4.6+ turned every dock into an EditorDock: the Output is an "EditorLog"
# dock named "Output" living inside an "EditorBottomPanel" (a DockTabContainer
# whose theme type variation is "BottomPanel"), and the side docks live in
# SideDockTabContainer slots named "dock_3", "dock_5", ... The old
# "/dockslotleftur" and "/editorbottompanel" path checks never match those.
# The bottom panel also re-applies its own panel style on every tab change, so
# an override has to be re-asserted (see _on_refresh_timeout).

func _fade_dock_area(root: Node, key: String, opacity: float) -> void:
	if not _is_target_enabled(key):
		return

	var dock_class: String = DOCK_CLASS_BY_TARGET.get(key, "")

	var dock := _find_control(root, func(control: Control) -> bool:
		return control.get_class() == dock_class
	)

	if dock == null:
		# Fall back to the bottom panel itself if the Output dock is closed.
		if key == "output":
			var bottom_panel := _find_control(root, _is_bottom_panel)

			if bottom_panel != null:
				_fade_styleboxes(
					bottom_panel,
					[&"panel", &"tabbar_background"],
					opacity
				)

		return

	# The dock content itself (a panel on some versions, a MarginContainer now).
	_fade_styleboxes(dock, [&"panel", &"bg", &"normal"], opacity)

	# The container that hosts the dock draws the actual dock background.
	_fade_ancestor_panels(dock, 5, opacity)

	# Inner backgrounds of the dock content.
	for control in _collect_controls(dock):
		match control.get_class():
			"FileSystemList":
				_fade_styleboxes(control, [&"panel"], opacity)

			"EditorInspectorCategory":
				_fade_styleboxes(control, [&"bg"], opacity)

			# The Output log's text background, when it has one.
			"RichTextLabel":
				_fade_styleboxes(control, [&"normal"], opacity)


func _fade_ancestor_panels(
	control: Control,
	max_levels: int,
	opacity: float
) -> void:
	var current := control.get_parent()
	var level := 0
	var tab_container: Control = null

	while current != null and current is Control and level < max_levels:
		var ancestor := current as Control
		var ancestor_class := ancestor.get_class()

		if (
			ancestor_class == "TabContainer"
			or ancestor_class.contains("DockTabContainer")
			or ancestor_class.contains("BottomPanel")
		):
			_fade_styleboxes(
				ancestor,
				[&"panel", &"tabbar_background"],
				opacity
			)

			if tab_container == null:
				tab_container = ancestor

		current = current.get_parent()
		level += 1

	# Older editor versions wrap the dock tab container in a Panel.
	if tab_container != null:
		var wrapper := tab_container.get_parent()

		if wrapper is Panel:
			_fade_styleboxes(wrapper as Panel, [&"panel"], opacity)


func _is_bottom_panel(control: Control) -> bool:
	if control.get_class() == "EditorBottomPanel":
		return true

	if str(control.theme_type_variation) == "BottomPanel":
		return true

	return false


# ---------------------------------------------------------
# MAIN EDITOR (top toolbar + game view)
# ---------------------------------------------------------

func _fade_main_editor(root: Node, opacity: float) -> void:
	if not _is_target_enabled("main_editor"):
		return

	_fade_top_toolbar(root, opacity)
	_fade_top_strips(root, opacity)
	_fade_game_view(root, opacity)


func _fade_top_toolbar(root: Node, opacity: float) -> void:
	# The main screens build their top toolbar from EditorToolbarGroup controls
	# (theme variation "PanelContainerButtonGroup"). The dark strip behind the
	# toolbar is painted by one of the containers above the screen, and which
	# one depends on the editor theme, so fade the whole chain up to the editor
	# root instead of guessing who owns it.
	for control in _collect_controls(root):
		var variation := str(control.theme_type_variation)
		var control_class := control.get_class()

		if variation == "PanelContainerButtonGroup":
			_fade_styleboxes(control, [&"panel"], opacity)

		if (
			control_class == "Node3DEditor"
			or control_class == "CanvasItemEditor"
			or control_class == "GameView"
		):
			_fade_styleboxes(control, [&"panel"], opacity)
			_fade_toolbar_ancestors(control, opacity)
			_fade_toolbar_row(control, opacity)
			_log_toolbar_chain(control)


# The scene tab strip (and the menu bar row under it) paint their own
# backgrounds above the main screen, outside the toolbar chain, so no class
# name has to be guessed: they are found by shape - wide, thin and touching
# the very top of the window.
func _fade_top_strips(root: Node, opacity: float) -> void:
	var editor_root := EditorInterface.get_base_control()

	if editor_root == null:
		return

	var window_width := editor_root.size.x

	for control in _collect_controls(root):
		if _is_wallpaper_control(control):
			continue

		var rect := control.get_global_rect()

		if rect.position.y > 16.0:
			continue

		if rect.size.x < window_width * 0.5:
			continue

		if rect.size.y > 120.0:
			continue

		_fade_styleboxes(control, [&"panel", &"tabbar_background"], opacity)
		_fade_toolbar_ancestors(control, opacity)
		_log_top_strip(control, rect)

		# The tabs themselves sit on that strip, so they fade with it.
		if control is TabBar:
			_fade_styleboxes(
				control,
				[&"tab_selected", &"tab_unselected", &"tab_hovered"],
				opacity
			)


func _log_top_strip(control: Control, rect: Rect2) -> void:
	# One-shot diagnostic: shows what the top strip is made of.
	if not _developer_mode() or top_strips_logged:
		return

	top_strips_logged = true

	print(
		"[Live Wallpaper] top strip: ",
		control.get_class(),
		" | variation=",
		control.theme_type_variation,
		" | rect=",
		rect
	)


func _is_wallpaper_control(control: Control) -> bool:
	if not is_instance_valid(wallpaper_layer):
		return false

	return control == wallpaper_layer or wallpaper_layer.is_ancestor_of(control)


func _log_toolbar_chain(screen: Control) -> void:
	# One-shot diagnostic: shows which container paints the toolbar strip.
	if not _developer_mode() or toolbar_chain_logged:
		return

	toolbar_chain_logged = true

	print("[Live Wallpaper] toolbar chain for ", screen.get_class(), ":")

	var editor_root := EditorInterface.get_base_control()
	var current: Node = screen
	var depth := 0

	while current != null and current != editor_root and depth < 12:
		if current is Control:
			var control := current as Control
			var panel := control.get_theme_stylebox(&"panel")
			var panel_class := "none" if panel == null else panel.get_class()

			print(
				"   ",
				control.get_class(),
				" | variation=",
				control.theme_type_variation,
				" | panel=",
				panel_class
			)

		current = current.get_parent()
		depth += 1


func _fade_toolbar_ancestors(control: Control, opacity: float) -> void:
	var editor_root := EditorInterface.get_base_control()
	var current := control.get_parent()

	# Containers without the stylebox are skipped by _fade_styleboxes, so this
	# stays limited to whatever actually paints the main screen background.
	while current != null and current != editor_root and current is Control:
		_fade_styleboxes(
			current as Control,
			[&"panel", &"tabbar_background"],
			opacity
		)

		current = current.get_parent()


func _fade_toolbar_row(screen: Control, opacity: float) -> void:
	# Toolbar wrappers directly under the screen (some themes wrap the row in a
	# PanelContainer, others draw it from the screen background).
	for child in screen.get_children():
		if not (child is Control):
			continue

		_fade_styleboxes(child as Control, [&"panel"], opacity)

		for grandchild in child.get_children():
			if grandchild is Control:
				_fade_styleboxes(grandchild as Control, [&"panel"], opacity)


# ---------------------------------------------------------
# GAME VIEW
# ---------------------------------------------------------
#
# GameView hosts a Panel with the "GamePanel" theme variation and an
# "EmbeddedProcess" control inside it. The embedded game is a native child
# window, so the editor itself paints the project's clear color (or the
# transparency checkerboard) behind it. Fading those two is what lets the
# wallpaper show through the letterbox area and around the game window.

func _fade_game_view(root: Node, opacity: float) -> void:
	if not _is_target_enabled("main_editor"):
		return

	var game_panels: Array[Control] = []

	for control in _collect_controls(root):
		if str(control.theme_type_variation) == "GamePanel":
			game_panels.append(control)
		elif control.get_class() == "GameView":
			game_panels.append(control)

	for panel in game_panels:
		_fade_styleboxes(panel, [&"panel"], opacity)

		for child in _collect_controls(panel):
			if child.get_class().contains("EmbeddedProcess"):
				_fade_self_modulate(child, opacity)

		# The dock container the Game view is shown in.
		_fade_ancestor_panels(panel, 6, opacity)


# ---------------------------------------------------------
# SCRIPT EDITOR
# ---------------------------------------------------------

func _apply_script_editor(opacity: float) -> void:
	var mode := int(_get_setting("script_background", SCRIPT_BG_WALLPAPER))

	script_control_count = 0

	if mode == SCRIPT_BG_DEFAULT:
		return

	var script_editor := EditorInterface.get_script_editor()

	if script_editor == null:
		return

	var controls := _collect_controls(script_editor)
	script_control_count = controls.size()

	var list_opacity := clampf(
		float(_get_setting("script_list_opacity", 65)) / 100.0,
		0.0,
		1.0
	)
	var color := Color(0.11, 0.11, 0.13, 1.0)

	if mode == SCRIPT_BG_CUSTOM:
		color = _get_setting("script_color", color)

		_set_stylebox_color(script_editor, &"panel", color)
		_apply_script_list_style(controls, mode, color, list_opacity)

		for control in controls:
			if control is CodeEdit:
				_set_stylebox_color(control, &"normal", color)

		return

	_fade_styleboxes(script_editor, [&"panel"], opacity)
	_apply_script_list_style(controls, mode, color, list_opacity)

	for control in controls:
		if control is CodeEdit:
			_fade_styleboxes(control, [&"normal"], opacity)


func _apply_script_list_style(
	controls: Array[Control],
	mode: int,
	color: Color,
	opacity: float
) -> void:
	# The script list is an ItemList whose background is the "panel" stylebox;
	# the "Filter Scripts" field above it draws its own "normal" stylebox, so
	# both have to be handled for the whole left column to change.
	for control in controls:
		var style_key := &""

		if control is ItemList:
			style_key = &"panel"
		elif control is LineEdit:
			style_key = &"normal"
		else:
			continue

		if mode == SCRIPT_BG_CUSTOM:
			_set_stylebox_color(control, style_key, color)
		else:
			_fade_styleboxes(control, [style_key], opacity)


func _script_editor_needs_rebuild() -> bool:
	if int(_get_setting("script_background", SCRIPT_BG_WALLPAPER)) == SCRIPT_BG_DEFAULT:
		return false

	var script_editor := EditorInterface.get_script_editor()

	if script_editor == null:
		return false

	# Scripts open and close all the time; re-apply when the editor gained or
	# lost controls.
	return _collect_controls(script_editor).size() != script_control_count


# ---------------------------------------------------------
# STYLEBOX HELPERS
# ---------------------------------------------------------

func _fade_styleboxes(
	control: Control,
	style_names: Array,
	opacity: float
) -> void:
	for style_name in style_names:
		var style_key := StringName(style_name)

		if _has_style_entry(control, style_key):
			continue

		if not control.has_theme_stylebox(style_key):
			continue

		var original := control.get_theme_stylebox(style_key)
		if original == null:
			continue

		var modified := original.duplicate() as StyleBox
		if modified == null:
			continue

		if not _fade_stylebox(modified, opacity):
			continue

		var had_override := control.has_theme_stylebox_override(style_key)

		control.add_theme_stylebox_override(style_key, modified)

		applied_styles.append({
			"control": control,
			"name": style_key,
			"original": original,
			"had_override": had_override,
			"applied": modified
		})


func _fade_stylebox(style: StyleBox, opacity: float) -> bool:
	if style is StyleBoxFlat:
		var flat := style as StyleBoxFlat
		var color := flat.bg_color

		if color.a <= 0.0:
			return false

		color.a *= opacity
		flat.bg_color = color
		return true

	if style is StyleBoxTexture:
		var texture_style := style as StyleBoxTexture
		var color := texture_style.modulate_color

		if color.a <= 0.0:
			return false

		color.a *= opacity
		texture_style.modulate_color = color
		return true

	return false


func _set_stylebox_color(
	control: Control,
	style_key: StringName,
	color: Color
) -> void:
	if _has_style_entry(control, style_key):
		return

	if not control.has_theme_stylebox(style_key):
		return

	var original := control.get_theme_stylebox(style_key)
	if original == null:
		return

	var modified := original.duplicate() as StyleBox
	if modified == null:
		return

	if modified is StyleBoxFlat:
		(modified as StyleBoxFlat).bg_color = color
	elif modified is StyleBoxTexture:
		(modified as StyleBoxTexture).modulate_color = color
	else:
		return

	var had_override := control.has_theme_stylebox_override(style_key)

	control.add_theme_stylebox_override(style_key, modified)

	applied_styles.append({
		"control": control,
		"name": style_key,
		"original": original,
		"had_override": had_override,
		"applied": modified
	})


func _fade_self_modulate(control: Control, opacity: float) -> void:
	for entry in applied_modulates:
		if _entry_control(entry) == control:
			return

	var original := control.self_modulate
	var target := original
	target.a *= opacity

	applied_modulates.append({
		"control": control,
		"original": original,
		"target": target
	})

	control.self_modulate = target


# Controls recorded in applied_styles / applied_modulates can be freed by the
# editor at any time (editing a script rebuilds the script editor), so the
# stored reference is fetched untyped and checked before it is ever assigned
# to a typed variable - a freed instance assigned to Control throws.
func _entry_control(entry: Dictionary) -> Control:
	var control = entry.get("control")

	if not is_instance_valid(control):
		return null

	return control as Control


func _has_style_entry(control: Control, style_key: StringName) -> bool:
	for entry in applied_styles:
		if _entry_control(entry) == control and entry["name"] == style_key:
			return true

	return false


func _clear_transparency() -> void:
	for entry in applied_styles:
		var control := _entry_control(entry)

		if control == null:
			continue

		var style_name: StringName = entry["name"]

		if bool(entry["had_override"]):
			control.add_theme_stylebox_override(
				style_name,
				entry["original"] as StyleBox
			)
		else:
			control.remove_theme_stylebox_override(style_name)

	applied_styles.clear()

	for entry in applied_modulates:
		var control := _entry_control(entry)

		if control != null:
			control.self_modulate = entry["original"] as Color

	applied_modulates.clear()


# ---------------------------------------------------------
# TREE HELPERS
# ---------------------------------------------------------

func _collect_controls(node: Node) -> Array[Control]:
	var result: Array[Control] = []

	for child in node.find_children("*", "Control", true, false):
		result.append(child as Control)

	return result


func _find_control(node: Node, predicate: Callable) -> Control:
	for child in node.get_children():
		if child is Control and predicate.call(child):
			return child as Control

		var found := _find_control(child, predicate)

		if found != null:
			return found

	return null



# ---------------------------------------------------------
# DEBUG REPORT
# ---------------------------------------------------------

func _print_stylebox_report() -> void:
	if not _developer_mode():
		return

	print("\n========== DOCK STYLEBOX REPORT ==========")

	var root := EditorInterface.get_base_control()
	_inspect_styleboxes(root, "")

	print("========== END REPORT ==========\n")


func _inspect_styleboxes(node: Node, parent_path: String) -> void:
	if not _developer_mode():
		return

	if node is Control:
		var control := node as Control

		var path := parent_path + "/" + str(control.name)
		var theme := control.get_theme()

		var relevant := (
			path.to_lower().contains("dock")
			or path.to_lower().contains("scene")
			or path.to_lower().contains("filesystem")
			or path.to_lower().contains("inspector")
			or path.to_lower().contains("output")
			or path.to_lower().contains("editor")
		)

		if relevant:
			print("\nNODE: ", path)
			print("CLASS: ", control.get_class())
			print("VARIATION: ", control.theme_type_variation)
			print("SIZE: ", control.size)

			if theme != null:
				var types := [
					control.get_class(),
					"Control"
				]

				if control.theme_type_variation != &"":
					types.append(str(control.theme_type_variation))

				for type_name in types:
					var styles := theme.get_stylebox_list(type_name)

					for style_name in styles:
						var style := control.get_theme_stylebox(
							style_name,
							type_name
						)

						if style != null:
							print(
								"  STYLE: ",
								type_name,
								" / ",
								style_name,
								" / ",
								style.get_class()
							)

	for child in node.get_children():
		_inspect_styleboxes(child, parent_path + "/" + str(node.name))
