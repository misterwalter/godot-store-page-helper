@tool
extends Control

## Renders every [StoreAsset] under [code]Screens[/code] to a PNG.
##
## How to use:
##   1. Put your artwork inside each StoreAsset node under Screens.
##   2. Run the scene.
##
## The tree under Screens is [StoreFront] -> [StoreAsset], and that structure is
## the whole configuration: a storefront becomes a subfolder of
## [constant OUTPUT_ROOT] and each asset becomes a PNG inside it. Delete a
## storefront you don't ship to and it stops being generated; add one and it
## starts. Sizes come from [StorePresets].
##
## A [StoreAsset] with [member StoreAsset.gif_enabled] on also gets an
## animated .gif alongside its .png, scrubbed frame by frame from its
## [AnimationPlayer] via [GifEncoder] — a self-contained encoder with no
## external dependency.
##
## Run with [code]-- --no-open[/code] to skip opening the output folder at the end.

const OUTPUT_ROOT := "res://store_assets/"
const NO_OPEN_ARGUMENT := "--no-open"

## Vertical gap between two storefronts' blocks of assets in the editor.
const _STOREFRONT_SPACING := 200.0

@export var open_output_folder_when_done := true

## Stacks the storefronts down the editor canvas so their asset boxes don't
## pile up on top of each other. Positions are an editor convenience only —
## every asset is rendered from its own origin.
@export var auto_arrange_storefronts := true

@onready var screens_root: Control = $Screens
@onready var sub_viewport: SubViewport = $SubViewportContainer/SubViewport
@onready var how_to_use: Label = $HowToUse

var _written := 0
var _warnings: PackedStringArray = PackedStringArray()


func _ready() -> void:
	if Engine.is_editor_hint():
		arrange_storefronts()
		return

	how_to_use.hide()
	# Rendering through a SubViewport is what makes transparent backgrounds
	# possible. keep_global_transform is off so Screens stays at the origin.
	screens_root.reparent(sub_viewport, false)
	screens_root.position = Vector2.ZERO
	sub_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	await generate_all()

	print(_summary())
	if open_output_folder_when_done and not NO_OPEN_ARGUMENT in OS.get_cmdline_user_args():
		OS.shell_open(ProjectSettings.globalize_path(OUTPUT_ROOT))
	get_tree().quit(1 if not _warnings.is_empty() else 0)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		arrange_storefronts()


## Stacks each storefront's block of assets down the canvas, top to bottom.
func arrange_storefronts() -> void:
	if not auto_arrange_storefronts or screens_root == null:
		return
	var next_y := 0.0
	for store_node in screens_root.get_children():
		if store_node is not Control:
			continue
		var storefront := store_node as Control
		if not is_equal_approx(storefront.position.y, next_y) or not is_zero_approx(storefront.position.x):
			storefront.position = Vector2(0.0, next_y)
		next_y += storefront.size.y + _STOREFRONT_SPACING


## Renders and saves every asset found under Screens.
func generate_all() -> void:
	var jobs := collect_jobs()
	if jobs.is_empty():
		_warn("Found no StoreAsset nodes under %s, so nothing was generated." % screens_root.name)
		return

	for child in screens_root.get_children():
		if child is CanvasItem:
			child.hide()

	for job in jobs:
		await _render_job(job)


## Walks Screens and builds one job per exportable asset.
##
## Anything unexpected in the tree is skipped rather than fatal, so a
## half-deleted storefront or a stray node can't stop the run.
func collect_jobs() -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []

	for store_node in screens_root.get_children():
		if store_node is not Control:
			continue

		var storefront := store_node as StoreFront
		if storefront != null and not storefront.enabled:
			print("Skipping %s: disabled." % store_node.name)
			continue

		# A plain Control still works as a storefront; it just uses its node
		# name as the folder and gets no preset help.
		var folder := storefront.output_folder() if storefront != null else StorePresets.slugify(String(store_node.name))
		if folder.is_empty():
			_warn("Storefront \"%s\" has no usable folder name, skipping it." % store_node.name)
			continue

		var used_names := {}
		for asset_node in store_node.get_children():
			if asset_node is not Control:
				continue
			var asset := asset_node as StoreAsset

			var pixels := asset.asset_size() if asset != null else Vector2i((asset_node as Control).size)
			if pixels.x <= 0 or pixels.y <= 0:
				_warn("Skipping %s/%s: its size is %dx%d." % [store_node.name, asset_node.name, pixels.x, pixels.y])
				continue

			var output := asset.output_name() if asset != null else StorePresets.slugify(String(asset_node.name))
			if output.is_empty():
				_warn("Skipping %s/%s: it has no usable file name." % [store_node.name, asset_node.name])
				continue
			if used_names.has(output):
				_warn("%s/%s writes to %s.png, which %s already wrote." % [
					store_node.name, asset_node.name, output, used_names[output],
				])
			used_names[output] = asset_node.name

			jobs.append({
				"node": asset_node,
				"storefront": store_node,
				"folder": folder,
				"file_name": output,
				"size": pixels,
				"alpha": asset.alpha_requirement() if asset != null else StorePresets.ALPHA_OPTIONAL,
			})

	return jobs


func _render_job(job: Dictionary) -> void:
	var asset: Control = job["node"]
	var storefront: Control = job["storefront"]
	var pixels: Vector2i = job["size"]

	storefront.show()
	for sibling in storefront.get_children():
		if sibling is CanvasItem:
			sibling.hide()
	asset.show()

	# Assets are laid out side by side in the editor, so shift the whole tree to
	# bring this one to the viewport origin, then put it back once every capture
	# for this asset (the still PNG, and any GIF frames) is done.
	var saved_position := screens_root.position
	screens_root.position -= asset.global_position
	sub_viewport.size = pixels

	var image := await _capture_frame()
	if image == null:
		_warn("%s/%s produced no image." % [job["folder"], job["file_name"]])
	else:
		if image.get_size() != pixels:
			_warn("%s/%s rendered at %dx%d instead of %dx%d." % [
				job["folder"], job["file_name"],
				image.get_width(), image.get_height(), pixels.x, pixels.y,
			])
		_apply_alpha_requirement(image, job)
		_save(image, job)

	if asset is StoreAsset and (asset as StoreAsset).gif_enabled:
		await _render_gif_job(asset as StoreAsset, job)

	screens_root.position = saved_position
	asset.hide()
	storefront.hide()


func _capture_frame() -> Image:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return sub_viewport.get_texture().get_image()


## Scrubs [param asset]'s animation frame by frame (never played in real
## time) and hands the captures to [GifEncoder]. Assumes the caller has
## already positioned/sized the viewport for this asset, as [method _render_job] does.
func _render_gif_job(asset: StoreAsset, job: Dictionary) -> void:
	var label := "%s/%s" % [job["folder"], job["file_name"]]

	if not asset.has_gif_animation():
		_warn("%s: GIF export is on but has no usable animation, skipping the .gif." % label)
		return

	var player := asset.find_gif_animation_player()
	var anim_name := asset.resolved_gif_animation_name()
	var animation := player.get_animation(anim_name)
	var fps := asset.gif_fps
	var frame_count := maxi(2, roundi(animation.length * fps))
	var delay_cs := maxi(2, roundi(100.0 / fps))

	# seek()'s "update" flag only actually applies track values once the
	# player has been played at least once — so play() once to activate it,
	# then freeze real-time playback dead so every frame below is positioned
	# purely by our own explicit seek() calls, not by wall-clock time.
	var original_speed := player.speed_scale
	player.play(anim_name)
	player.speed_scale = 0.0

	var frames: Array[Image] = []
	for i in range(frame_count):
		var t := clampf(float(i) / fps, 0.0, animation.length)
		player.seek(t, true)
		var frame := await _capture_frame()
		if frame != null:
			frames.append(frame)

	player.seek(0.0, true)
	player.stop()
	player.speed_scale = original_speed

	if frames.size() < 2:
		_warn("%s: captured fewer than 2 usable frames, skipping the .gif." % label)
		return

	if job["alpha"] == StorePresets.ALPHA_NONE:
		for frame in frames:
			frame.convert(Image.FORMAT_RGB8)
			frame.convert(Image.FORMAT_RGBA8)

	var options := {
		"max_colors": asset.gif_max_colors,
		"loop": asset.gif_loop,
		"max_size_bytes": asset.gif_max_size_kb * 1024,
	}
	var result := GifEncoder.encode_within_budget(frames, delay_cs, options)
	if not result.get("ok", false):
		_warn("%s: %s" % [label, result.get("error", "GIF encoding failed.")])
		return

	var directory := OUTPUT_ROOT.path_join(String(job["folder"]))
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		_warn("%s: could not create %s." % [label, directory])
		return
	var path := directory.path_join("%s.gif" % job["file_name"])
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_warn("%s: could not write %s (%s)." % [label, path, error_string(FileAccess.get_open_error())])
		return
	file.store_buffer(result["bytes"])
	file.close()

	_written += 1
	var kb: float = result["bytes"].size() / 1024.0
	print("  %s  %d frames @ %dfps, %d colors, %.1fKB" % [path, result["frame_count"], fps, result["colors"], kb])
	if not result["under_budget"]:
		_warn("%s.gif is %.1fKB, over the %dKB budget even at the lowest quality tier tried." % [
			job["file_name"], kb, asset.gif_max_size_kb,
		])


## Enforces the store's transparency rule, warning when the artwork disagrees
## with it. A store that forbids alpha gets the channel dropped rather than a
## rejected upload.
func _apply_alpha_requirement(image: Image, job: Dictionary) -> void:
	var label := "%s/%s" % [job["folder"], job["file_name"]]
	match job["alpha"]:
		StorePresets.ALPHA_NONE:
			if image.detect_alpha() != Image.ALPHA_NONE:
				_warn("%s must be opaque but has transparent pixels; flattening them to black." % label)
			image.convert(Image.FORMAT_RGB8)
		StorePresets.ALPHA_REQUIRED:
			if image.detect_alpha() == Image.ALPHA_NONE:
				_warn("%s is meant to have a transparent background but is fully opaque." % label)


func _save(image: Image, job: Dictionary) -> void:
	var directory := OUTPUT_ROOT.path_join(String(job["folder"]))
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK:
		_warn("Could not create %s (%s)." % [directory, error_string(error)])
		return

	var path := directory.path_join("%s.png" % job["file_name"])
	error = image.save_png(path)
	if error != OK:
		_warn("Could not write %s (%s)." % [path, error_string(error)])
		return

	_written += 1
	print("  %s  %dx%d" % [path, image.get_width(), image.get_height()])


func _warn(message: String) -> void:
	_warnings.append(message)
	push_warning(message)


func _summary() -> String:
	var lines := PackedStringArray()
	lines.append("")
	lines.append("Wrote %d image%s to %s" % [_written, "" if _written == 1 else "s", OUTPUT_ROOT])
	if not _warnings.is_empty():
		lines.append("%d problem%s:" % [_warnings.size(), "" if _warnings.size() == 1 else "s"])
		for warning in _warnings:
			lines.append("  - %s" % warning)
	return "\n".join(lines)
