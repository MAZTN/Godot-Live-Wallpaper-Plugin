@tool
extends EditorPlugin

const WALLPAPER_PATH := "res://addons/godotLiveWallpaper/assets/wallpaper.png"

const SETTINGS_PREFIX := "godotLiveWallpaper/"

# Settings target -> class of the editor dock that implements it. Docks are
# movable, so a dock is located by its content class, never by a slot name.
const DOCK_CLASS_BY_TARGET := {
	"scene_tree": "SceneTreeDock",
	"filesystem": "FileSystemDock",
	"inspector": "InspectorDock",
	"output": "EditorLog"
}

# How often the plugin makes sure the editor did not overwrite our styleboxes.
const REFRESH_INTERVAL := 0.4

# Full rebuild cadence (in refresh ticks) for changed dock layouts.
const REBUILD_EVERY := 25

var wallpaper_layer: TextureRect
var settings_panel: VBoxContainer

var enable_check: CheckBox
var opacity_slider: HSlider
var opacity_label: Label

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


func _enter_tree() -> void:
	editor_settings = EditorInterface.get_editor_settings()

	_install_settings_dock()
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

	if settings_panel != null:
		remove_control_from_docks(settings_panel)
		settings_panel.queue_free()


# ---------------------------------------------------------
# WALLPAPER
# ---------------------------------------------------------

func _install_wallpaper() -> void:
	var editor_root := EditorInterface.get_base_control()

	if editor_root == null:
		push_error("[Live Wallpaper] Editor root unavailable.")
		return

	if wallpaper_layer != null:
		return

	var texture := load(WALLPAPER_PATH) as Texture2D

	if texture == null:
		push_error("[Live Wallpaper] Failed to load wallpaper: " + WALLPAPER_PATH)
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

	print("[Live Wallpaper] Wallpaper installed.")


func _remove_wallpaper() -> void:
	if is_instance_valid(wallpaper_layer):
		wallpaper_layer.queue_free()

	wallpaper_layer = null


# ---------------------------------------------------------
# SETTINGS DOCK
# ---------------------------------------------------------

func _install_settings_dock() -> void:
	settings_panel = VBoxContainer.new()
	settings_panel.name = "Live Wallpaper Settings"
	settings_panel.custom_minimum_size = Vector2(220, 0)

	var heading := Label.new()
	heading.text = "Live Wallpaper"
	heading.add_theme_font_size_override("font_size", 18)
	settings_panel.add_child(heading)

	var description := Label.new()
	description.text = "Appearance settings"
	settings_panel.add_child(description)

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

	add_control_to_dock(DOCK_SLOT_RIGHT_UL, settings_panel)

	var inspect_button := Button.new()
	inspect_button.text = "Inspect Dock Backgrounds"
	inspect_button.pressed.connect(_print_stylebox_report)
	settings_panel.add_child(inspect_button)


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
	if _has_stale_targets() or refresh_ticks >= REBUILD_EVERY or dock_still_missing:
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

	if not is_instance_valid(enable_check) or not enable_check.button_pressed:
		return

	if not is_instance_valid(opacity_slider):
		return

	var editor_root := EditorInterface.get_base_control()
	if editor_root == null:
		return

	var opacity := float(opacity_slider.value) / 100.0

	_scan_controls(editor_root, opacity)

	# Dock-based areas are found structurally, not by node name: the bottom
	# panel used to be the only special case, but Godot 4.6 replaced the dock
	# slots with named docks that can live in any slot.
	_fade_dock_area(editor_root, "scene_tree", opacity)
	_fade_dock_area(editor_root, "filesystem", opacity)
	_fade_dock_area(editor_root, "inspector", opacity)
	_fade_dock_area(editor_root, "output", opacity)
	_fade_game_view(editor_root, opacity)


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
