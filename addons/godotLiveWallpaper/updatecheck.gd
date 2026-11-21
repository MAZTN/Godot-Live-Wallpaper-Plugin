@tool
extends Node

# Update check for https://github.com/MAZTN/godot-live-wallpaper-plugin
#
# The newest release is read from the GitHub API. A repository without any
# release answers 404 there, so the plugin.cfg on the main branch is used as a
# fallback: bumping the version is then enough to be noticed.
#
# install() downloads the source archive of that version and copies only
# addons/godotLiveWallpaper/ into the project.
# This is for anyone that thinks any api calls in this plugin is suspicious. Nope! Just for updates.

signal status_changed(text: String, has_update: bool)
signal install_finished(success: bool, message: String)

const REPO := "MAZTN/godot-live-wallpaper-plugin"
const API_LATEST := "https://api.github.com/repos/" + REPO + "/releases/latest"
const CONFIG_URL := (
	"https://raw.githubusercontent.com/"
	+ REPO
	+ "/main/addons/godotLiveWallpaper/plugin.cfg"
)
const TAG_ARCHIVE := "https://github.com/" + REPO + "/archive/refs/tags/%s.zip"
const BRANCH_ARCHIVE := "https://github.com/" + REPO + "/archive/refs/heads/main.zip"
const REPO_PAGE := "https://github.com/" + REPO

const ADDON_ROOT := "addons/godotLiveWallpaper/"
const DOWNLOAD_PATH := "user://live_wallpaper_update.zip"
const REQUEST_TIMEOUT := 15.0

var installed_version := ""
var latest_version := ""
var latest_page := ""
var update_available := false

var _http: HTTPRequest
var _callback := Callable()
var _archive_url := ""
var _quiet := true


func check(installed: String, announce := false) -> void:
	installed_version = installed
	latest_version = ""
	latest_page = ""
	_archive_url = ""
	update_available = false
	_quiet = not announce

	if not _quiet:
		print_rich(
			"[color=gray][b][Live Wallpaper][/b] Checking for updates...[/color]"
		)

	_request(API_LATEST, _on_release_response)


func install() -> void:
	if not update_available or _archive_url.is_empty():
		return

	status_changed.emit("Downloading version %s..." % latest_version, true)
	_request(_archive_url, _on_archive_response, DOWNLOAD_PATH)


# ---------------------------------------------------------
# REQUESTS
# ---------------------------------------------------------

func _request(url: String, callback: Callable, download_to := "") -> void:
	if not is_instance_valid(_http):
		_http = HTTPRequest.new()
		_http.name = "UpdateHTTP"
		_http.timeout = REQUEST_TIMEOUT
		_http.use_threads = true
		add_child(_http)

	if _http.request_completed.is_connected(_on_request_completed):
		_http.request_completed.disconnect(_on_request_completed)

	_callback = callback
	_http.download_file = download_to
	_http.request_completed.connect(_on_request_completed)

	var error := _http.request(
		url,
		["User-Agent: godot-live-wallpaper-update-check"]
	)

	if error != OK:
		_http.request_completed.disconnect(_on_request_completed)
		_callback = Callable()
		_fail("Could not start the request.")


func _on_request_completed(
	result: int,
	code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	if _http.request_completed.is_connected(_on_request_completed):
		_http.request_completed.disconnect(_on_request_completed)

	var callback := _callback
	_callback = Callable()

	if callback.is_valid():
		callback.call(result, code, body)


func _on_release_response(result: int, code: int, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("Could not reach GitHub. Are you online?")
		return

	if code == 404:
		# No release yet, or a private repository: compare the main branch.
		_request(CONFIG_URL, _on_config_response)
		return

	if code != 200:
		_fail("GitHub answered with HTTP %d." % code)
		return

	var parsed := JSON.parse_string(body.get_string_from_utf8())

	if not (parsed is Dictionary):
		_fail("GitHub sent an answer that could not be read.")
		return

	var tag := str((parsed as Dictionary).get("tag_name", ""))

	if tag.is_empty():
		_fail("The newest release has no version tag.")
		return

	_handle_remote(
		tag,
		str((parsed as Dictionary).get("html_url", REPO_PAGE)),
		TAG_ARCHIVE % tag
	)


func _on_config_response(result: int, code: int, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_fail(
			"No release or public folder found. "
			+ "The repository may be private."
		)
		return

	var config := ConfigFile.new()

	if config.parse(body.get_string_from_utf8()) != OK:
		_fail("The remote plugin.cfg could not be read.")
		return

	var remote_version := str(config.get_value("plugin", "version", ""))

	if remote_version.is_empty():
		_fail("The remote plugin.cfg has no version.")
		return

	_handle_remote(remote_version, REPO_PAGE, BRANCH_ARCHIVE)


func _handle_remote(version: String, page: String, archive: String) -> void:
	latest_version = _clean_version(version)
	latest_page = page if not page.is_empty() else REPO_PAGE
	_archive_url = archive

	if latest_version.is_empty() or installed_version.is_empty():
		_fail("The version number could not be read.")
		return

	if compare_versions(latest_version, installed_version) <= 0:
		update_available = false
		status_changed.emit(
			"You are up to date (version %s)." % installed_version,
			false
		)

		if not _quiet:
			print_rich(
				"[color=green][b][Live Wallpaper][/b] You are up to date "
				+ "(version " + installed_version + ").[/color]"
			)

		return

	update_available = true
	status_changed.emit(
		"Version %s is available (you have %s)."
		% [latest_version, installed_version],
		true
	)
	_announce_update()


func _announce_update() -> void:
	print_rich(
		"[color=yellow][b][Live Wallpaper] Update available:[/b] version "
		+ latest_version
		+ " (you are on " + installed_version + ").[/color]"
	)
	print_rich("[color=yellow]    " + latest_page + "[/color]")
	print_rich(
		"[color=yellow]    Or open the [b]Wallpaper[/b] tab, section "
		+ "[b]Updates[/b], and press [b]Install update[/b].[/color]"
	)


func _fail(message: String) -> void:
	update_available = false
	status_changed.emit(message, false)

	if not _quiet:
		print_rich(
			"[color=gray][b][Live Wallpaper][/b] " + message + "[/color]"
		)


# ---------------------------------------------------------
# INSTALL
# ---------------------------------------------------------

func _on_archive_response(result: int, code: int, _body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		install_finished.emit(false, "The download failed. Are you online?")
		return

	if code != 200:
		install_finished.emit(false, "The download failed (HTTP %d)." % code)
		return

	var problem := _extract(DOWNLOAD_PATH)
	_remove_download()

	if problem.is_empty():
		install_finished.emit(true, "Updated to version %s." % latest_version)
	else:
		install_finished.emit(false, problem)


func _extract(zip_path: String) -> String:
	var reader := ZIPReader.new()

	if reader.open(zip_path) != OK:
		return "The downloaded file could not be opened."

	var written := 0
	var failed := 0

	for entry in reader.get_files():
		var index := entry.find(ADDON_ROOT)

		if index < 0 or entry.ends_with("/"):
			continue

		var relative := entry.substr(index + ADDON_ROOT.length())

		if relative.is_empty() or relative.contains(".."):
			continue

		var destination := "res://" + ADDON_ROOT + relative
		var directory := destination.get_base_dir()

		if not DirAccess.dir_exists_absolute(directory):
			DirAccess.make_dir_recursive_absolute(directory)

		var file := FileAccess.open(destination, FileAccess.WRITE)

		if file == null:
			failed += 1
			continue

		file.store_buffer(reader.read_file(entry))
		file.close()
		written += 1

	reader.close()

	if written == 0:
		return "The archive did not contain the plugin folder."

	if failed > 0:
		return "%d file(s) could not be written. Is the project folder read-only?" % failed

	return ""


func _remove_download() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DOWNLOAD_PATH))


# ---------------------------------------------------------
# VERSIONS
# ---------------------------------------------------------

static func _clean_version(text: String) -> String:
	return text.strip_edges().trim_prefix("v").trim_prefix("V").strip_edges()


static func version_parts(text: String) -> PackedInt32Array:
	var parts := PackedInt32Array()

	for piece in _clean_version(text).split(".", false):
		var digits := ""

		for index in piece.length():
			var character := piece[index]

			if character < "0" or character > "9":
				break

			digits += character

		if digits.is_empty():
			break

		parts.append(int(digits))

	return parts


# 1 when a is newer, -1 when b is newer, 0 when they match.
static func compare_versions(a: String, b: String) -> int:
	var left := version_parts(a)
	var right := version_parts(b)
	var count := maxi(left.size(), right.size())

	for index in count:
		var left_part := left[index] if index < left.size() else 0
		var right_part := right[index] if index < right.size() else 0

		if left_part != right_part:
			return 1 if left_part > right_part else -1

	return 0
