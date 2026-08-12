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
	# bring this one to the viewport origin, then put it back.
	var saved_position := screens_root.position
	screens_root.position -= asset.global_position
	sub_viewport.size = pixels

	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var image := sub_viewport.get_texture().get_image()
	screens_root.position = saved_position
	asset.hide()
	storefront.hide()

	if image == null:
		_warn("%s/%s produced no image." % [job["folder"], job["file_name"]])
		return
	if image.get_size() != pixels:
		_warn("%s/%s rendered at %dx%d instead of %dx%d." % [
			job["folder"], job["file_name"],
			image.get_width(), image.get_height(), pixels.x, pixels.y,
		])

	_apply_alpha_requirement(image, job)
	_save(image, job)


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
