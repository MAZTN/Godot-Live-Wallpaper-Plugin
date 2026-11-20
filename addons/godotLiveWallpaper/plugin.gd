@tool
extends EditorPlugin

const DEFAULT_WALLPAPER_PATH := "res://addons/godotLiveWallpaper/assets/wallpaper.png"

const WALLPAPER_IMAGE_FILTER := "*.png, *.jpg, *.jpeg, *.webp, *.bmp, *.tga, *.svg, *.exr, *.hdr"

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

var wallpaper_layer: TextureRect

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


func _enter_tree() -> void:
	editor_settings = EditorInterface.get_editor_settings()

	_install_settings_screen()
	_install_refresh_timer()

	call_deferred("_install_wallpaper")
	call_deferred("_queue_transparency_apply")


func _exit_tree() -> void:
	_clear_transparency()

	if refresh_timer != null:
		refresh_timer.stop()
		refresh_timer.queue_free()
		refresh_timer = null

	_remove_wallpaper()

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

	print_rich(
		"<yellow><b>[Live Wallpaper] Update available. (<gray>v0.1 <yellow>-> <green>v0.2<yellow>)"
	)

	if editor_root == null:
		push_error("[Live Wallpaper] Editor root unavailable.")
		return

	if wallpaper_layer != null:
		return

	var path := _get_wallpaper_path()
	var texture := _load_wallpaper_texture(path)

	if texture == null and path != DEFAULT_WALLPAPER_PATH:
		push_warning(
			"[Live Wallpaper] Could not load \"" + path + "\", using the bundled wallpaper."
		)
		texture = _load_wallpaper_texture(DEFAULT_WALLPAPER_PATH)

	if texture == null:
		push_error("[Live Wallpaper] Failed to load wallpaper: " + path)
		return

	wallpaper_layer = TextureRect.new()
	wallpaper_layer.name = "LiveWallpaperBackground"
	wallpaper_layer.texture = texture

	wallpaper_layer.set_anchors_and_offsets_preset(
		Control.PRESET_FULL_RECT
	)

	wallpaper_layer.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wallpaper_layer.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED

	wallpaper_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wallpaper_layer.focus_mode = Control.FOCUS_NONE

	editor_root.add_child(wallpaper_layer)
	editor_root.move_child(wallpaper_layer, 0)

	_update_wallpaper_preview(texture)

	print("[Live Wallpaper] Wallpaper installed: ", path)


func _remove_wallpaper() -> void:
	if is_instance_valid(wallpaper_layer):
		wallpaper_layer.queue_free()

	wallpaper_layer = null


func _get_wallpaper_path() -> String:
	var path := str(_get_setting("wallpaper", DEFAULT_WALLPAPER_PATH))

	return DEFAULT_WALLPAPER_PATH if path.is_empty() else path


func _load_wallpaper_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null

	# res:// images go through the resource loader so imported textures work.
	if path.begins_with("res://"):
		return load(path) as Texture2D

	# Anything else (absolute paths, user://) is read straight from disk, so a
	# wallpaper does not have to live inside the project.
	if not FileAccess.file_exists(path):
		return null

	var image := Image.load_from_file(path)

	if image == null or image.is_empty():
		return null

	return ImageTexture.create_from_image(image)


func _apply_wallpaper_path(path: String) -> void:
	path = path.strip_edges().replace("\\", "/")

	var texture := _load_wallpaper_texture(path)

	if texture == null:
		push_error("[Live Wallpaper] Failed to load wallpaper: " + path)
		return

	_save_setting("wallpaper", path)

	if is_instance_valid(wallpaper_path_edit):
		wallpaper_path_edit.text = path

	if is_instance_valid(wallpaper_layer):
		wallpaper_layer.texture = texture
	else:
		_install_wallpaper()

	_update_wallpaper_preview(texture)

	print("[Live Wallpaper] Wallpaper changed: ", path)


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

	wallpaper_dialog.popup_centered_ratio(0.6)


func _on_wallpaper_file_selected(path: String) -> void:
	_apply_wallpaper_path(path)


func _on_bundled_wallpaper_pressed() -> void:
	_apply_wallpaper_path(DEFAULT_WALLPAPER_PATH)


# ---------------------------------------------------------
# SETTINGS SCREEN (main screen tab)
# ---------------------------------------------------------

func _install_settings_screen() -> void:
	settings_panel = VBoxContainer.new()
	settings_panel.name = "Live Wallpaper Settings"
	settings_panel.custom_minimum_size = Vector2(320, 0)
	settings_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var heading := Label.new()
	heading.text = "📃 Wallpaper"
	heading.add_theme_font_size_override("font_size", 22)
	settings_panel.add_child(heading)

	var description := Label.new()
	description.text = "Wallpaper and transparency settings for the editor."
	settings_panel.add_child(description)

	# Wallpaper image.
	var image_heading := Label.new()
	image_heading.text = "Wallpaper image"
	settings_panel.add_child(image_heading)

	wallpaper_preview = TextureRect.new()
	wallpaper_preview.custom_minimum_size = Vector2(320, 180)
	wallpaper_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wallpaper_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	wallpaper_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	settings_panel.add_child(wallpaper_preview)

	var path_row := HBoxContainer.new()
	settings_panel.add_child(path_row)

	wallpaper_path_edit = LineEdit.new()
	wallpaper_path_edit.text = _get_wallpaper_path()
	wallpaper_path_edit.placeholder_text = "res:// or an absolute image path"
	wallpaper_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wallpaper_path_edit.text_submitted.connect(_on_wallpaper_path_submitted)
	path_row.add_child(wallpaper_path_edit)

	var browse_button := Button.new()
	browse_button.text = "Browse…"
	browse_button.pressed.connect(_on_browse_wallpaper_pressed)
	path_row.add_child(browse_button)

	var bundled_button := Button.new()
	bundled_button.text = "Use bundled wallpaper"
	bundled_button.pressed.connect(_on_bundled_wallpaper_pressed)
	settings_panel.add_child(bundled_button)

	_update_wallpaper_preview(_load_wallpaper_texture(_get_wallpaper_path()))

	settings_panel.add_child(HSeparator.new())

	# Master toggle.
	enable_check = CheckBox.new()
	enable_check.text = "Enable dock transparency"
	enable_check.button_pressed = _get_setting("enabled", true)
	enable_check.toggled.connect(_on_enabled_changed)
	settings_panel.add_child(enable_check)

	# Opacity slider.
	var opacity_heading := Label.new()
	opacity_heading.text = "Dock opacity"
	settings_panel.add_child(opacity_heading)

	opacity_slider = HSlider.new()
	opacity_slider.min_value = 0
	opacity_slider.max_value = 100
	opacity_slider.step = 1
	opacity_slider.value = _get_setting("opacity", 65)
	opacity_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opacity_slider.value_changed.connect(_on_opacity_changed)
	settings_panel.add_child(opacity_slider)

	opacity_label = Label.new()
	settings_panel.add_child(opacity_label)
	_update_opacity_label(opacity_slider.value)

	settings_panel.add_child(HSeparator.new())

	var targets_heading := Label.new()
	targets_heading.text = "Affected editor areas"
	settings_panel.add_child(targets_heading)

	_add_target_checkbox("Scene Tree", "scene_tree")
	_add_target_checkbox("FileSystem", "filesystem")
	_add_target_checkbox("Inspector", "inspector")
	_add_target_checkbox("Output", "output")
	_add_target_checkbox("Main Editor", "main_editor")

	var hint := Label.new()
	hint.text = "Main Editor also covers the top toolbar and the Game view."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.7)
	settings_panel.add_child(hint)

	settings_panel.add_child(HSeparator.new())

	var script_heading := Label.new()
	script_heading.text = "Script editor background"
	settings_panel.add_child(script_heading)

	script_mode_button = OptionButton.new()
	script_mode_button.add_item("Use the wallpaper", SCRIPT_BG_WALLPAPER)
	script_mode_button.add_item("Custom color", SCRIPT_BG_CUSTOM)
	script_mode_button.add_item("Editor default", SCRIPT_BG_DEFAULT)
	script_mode_button.select(
		int(_get_setting("script_background", SCRIPT_BG_WALLPAPER))
	)
	script_mode_button.item_selected.connect(_on_script_mode_changed)
	settings_panel.add_child(script_mode_button)

	script_color_button = ColorPickerButton.new()
	script_color_button.color = _get_setting(
		"script_color",
		Color(0.11, 0.11, 0.13, 1.0)
	)
	script_color_button.edit_alpha = true
	script_color_button.color_changed.connect(_on_script_color_changed)
	settings_panel.add_child(script_color_button)

	script_list_box = VBoxContainer.new()
	settings_panel.add_child(script_list_box)

	var list_heading := Label.new()
	list_heading.text = "Script list and filter box opacity"
	script_list_box.add_child(list_heading)

	script_list_slider = HSlider.new()
	script_list_slider.min_value = 0
	script_list_slider.max_value = 100
	script_list_slider.step = 1
	script_list_slider.value = float(_get_setting("script_list_opacity", 65))
	script_list_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	script_list_slider.value_changed.connect(_on_script_list_opacity_changed)
	script_list_box.add_child(script_list_slider)

	script_list_label = Label.new()
	script_list_box.add_child(script_list_label)
	_update_script_list_label(script_list_slider.value)

	_update_script_controls_visibility()

	var inspect_button := Button.new()
	inspect_button.text = "Inspect Dock Backgrounds"
	inspect_button.pressed.connect(_print_stylebox_report)
	settings_panel.add_child(inspect_button)

	var margin := MarginContainer.new()
	margin.name = "WallpaperContent"
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 20)
	margin.add_child(settings_panel)

	var scroll := ScrollContainer.new()
	scroll.name = "Wallpaper"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(margin)

	settings_screen = scroll

	_install_settings_tab()


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


func _add_target_checkbox(label_text: String, key: String) -> void:
	var check := CheckBox.new()
	check.text = label_text
	check.button_pressed = _get_setting(key, true)

	check.toggled.connect(
		_on_target_changed.bind(key)
	)

	target_checks[key] = check
	settings_panel.add_child(check)


# ---------------------------------------------------------
# SETTINGS EVENTS
# ---------------------------------------------------------

func _on_enabled_changed(value: bool) -> void:
	_save_setting("enabled", value)
	_queue_transparency_apply()


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

	if is_instance_valid(script_color_button):
		script_color_button.visible = mode == SCRIPT_BG_CUSTOM

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
	opacity_label.text = "%d%% opaque" % int(value)


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
		var control: Control = entry["control"]

		if not is_instance_valid(control) or not control.is_visible_in_tree():
			continue

		var style_name: StringName = entry["name"]

		if control.get_theme_stylebox(style_name) != entry["applied"]:
			control.add_theme_stylebox_override(
				style_name,
				entry["applied"] as StyleBox
			)

	for entry in applied_modulates:
		var control: Control = entry["control"]

		if not is_instance_valid(control) or not control.is_visible_in_tree():
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


func _log_toolbar_chain(screen: Control) -> void:
	# One-shot diagnostic: shows which container paints the toolbar strip.
	if toolbar_chain_logged:
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
		if entry["control"] == control:
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


func _has_style_entry(control: Control, style_key: StringName) -> bool:
	for entry in applied_styles:
		if entry["control"] == control and entry["name"] == style_key:
			return true

	return false


func _clear_transparency() -> void:
	for entry in applied_styles:
		var control: Control = entry["control"]

		if not is_instance_valid(control):
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
		var control: Control = entry["control"]

		if is_instance_valid(control):
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
	print("\n========== DOCK STYLEBOX REPORT ==========")

	var root := EditorInterface.get_base_control()
	_inspect_styleboxes(root, "")

	print("========== END REPORT ==========\n")


func _inspect_styleboxes(node: Node, parent_path: String) -> void:
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
