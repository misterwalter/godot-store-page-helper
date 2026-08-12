@tool
class_name Screenshotter
extends Node

## Drop-in node that saves a screenshot every few seconds while the game runs.
##
## Add it anywhere in any scene, play the game, and every [member interval]
## seconds it writes a PNG. It is meant to be added while you gather store
## screenshots and deleted afterwards, so it holds no references to anything and
## nothing needs to reference it.
##
## It captures the viewport it is a child of, so parented to the scene root it
## grabs the whole window, and parented under a [SubViewport] it grabs just that.
##
## [member editor_builds_only] is on by default so that leaving one in by
## accident cannot make a shipped build write files to a player's disk.

## Emitted after each successful capture, with the path that was written.
signal screenshot_saved(path: String)

const _FALLBACK_FOLDER := "user://screenshots/"

## Master switch. Turning this off mid-run stops further captures.
@export var enabled := true:
	set(value):
		enabled = value
		_sync_timer()

## Seconds between captures.
@export_range(0.1, 120.0, 0.1, "or_greater", "suffix:s") var interval := 5.0:
	set(value):
		interval = maxf(value, 0.1)
		_sync_timer()
		update_configuration_warnings()

## Safety catch: when true this node does nothing unless the project is running
## from the editor. Turn it off only if you deliberately want captures out of an
## exported build.
@export var editor_builds_only := true:
	set(value):
		editor_builds_only = value
		_sync_timer()
		update_configuration_warnings()

@export_group("Output")
## Where PNGs are written. Falls back to [constant _FALLBACK_FOLDER] if this
## folder cannot be created, which is what happens in an exported build.
@export_dir var output_folder := "res://store_assets/screenshots/"

@export var file_prefix := "screenshot"

@export_group("Manual Capture")
## Optional input action that captures immediately when pressed, on top of the
## timer. Leave blank to rely on the timer alone.
@export var capture_action := ""

var _timer: Timer
var _run_id := ""
var _index := 0
var _resolved_folder := ""


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	# A stamp per run, so a second session never overwrites the first's images.
	_run_id = Time.get_datetime_string_from_system(false, false).replace("-", "").replace(":", "").replace("T", "_")

	_timer = Timer.new()
	_timer.name = "CaptureTimer"
	_timer.timeout.connect(capture)
	add_child(_timer)
	_sync_timer()

	set_process_input(not capture_action.is_empty())


func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or capture_action.is_empty():
		return
	if not InputMap.has_action(capture_action):
		return
	if event.is_action_pressed(capture_action):
		capture()


## True when this node is allowed to write files.
func is_armed() -> bool:
	if not enabled:
		return false
	if editor_builds_only and not OS.has_feature("editor"):
		return false
	return true


## Captures the current viewport and writes it out. Safe to call by hand.
func capture() -> void:
	if not is_armed() or not is_inside_tree():
		return

	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null:
		push_warning("Screenshotter: the viewport produced no image.")
		return

	var folder := _ensure_folder()
	if folder.is_empty():
		return

	_index += 1
	var path := folder.path_join("%s_%s_%04d.png" % [file_prefix, _run_id, _index])
	var error := image.save_png(path)
	if error != OK:
		push_warning("Screenshotter: could not write %s (%s)." % [path, error_string(error)])
		return

	print("Screenshotter: wrote %s (%dx%d)" % [path, image.get_width(), image.get_height()])
	screenshot_saved.emit(path)


## Creates the output folder, falling back to user:// when res:// is read-only
## (which is the case in an exported build).
func _ensure_folder() -> String:
	if not _resolved_folder.is_empty():
		return _resolved_folder

	for candidate in [output_folder, _FALLBACK_FOLDER]:
		if candidate.is_empty():
			continue
		if DirAccess.make_dir_recursive_absolute(candidate) == OK:
			if candidate != output_folder:
				push_warning("Screenshotter: %s was not writable, using %s instead." % [output_folder, candidate])
			_resolved_folder = candidate
			return _resolved_folder

	push_warning("Screenshotter: could not create an output folder.")
	return ""


func _sync_timer() -> void:
	if _timer == null:
		return
	_timer.wait_time = interval
	if is_armed():
		_timer.start()
	else:
		_timer.stop()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not enabled:
		warnings.append("Disabled, so no screenshots will be taken.")
	if not capture_action.is_empty() and not InputMap.has_action(capture_action):
		warnings.append("\"%s\" is not an input action in this project." % capture_action)
	if not editor_builds_only:
		warnings.append("The editor-only safety is off, so an exported build would also write screenshots.")
	return warnings
