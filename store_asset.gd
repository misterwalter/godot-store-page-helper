@tool
class_name StoreAsset
extends Control

## One image to be exported, sized from a [StorePresets] entry.
##
## Put whatever you want the image to contain under this node — the generator
## renders this node's rectangle and writes it out as a PNG. Pick a preset in
## the inspector and the node resizes itself to match; pick "Custom" and set
## [member custom_size] by hand for anything the preset table doesn't cover.
##
## The dropdown lists the assets belonging to the parent [StoreFront]. Parented
## anywhere else, it lists every preset instead.

## Emitted when the node's size or preset changes, so a parent [StoreFront] can
## re-run its editor layout.
signal spec_changed

const _OUTLINE_WIDTH := 2.0
const _LABEL_MARGIN := 8.0
const _CORNER_TICK := 24.0

## The chosen [StorePresets] entry, e.g. "steam/library_logo". Stored as a
## string rather than an enum index so that adding, removing or reordering
## presets can never silently repoint an existing node at the wrong asset.
var preset_id: String = StorePresets.CUSTOM_ID

## Size used when [member preset_id] is [constant StorePresets.CUSTOM_ID].
## Hidden in the inspector while a preset is driving the size.
@export var custom_size := Vector2i(920, 430):
	set(value):
		custom_size = Vector2i(maxi(value.x, 1), maxi(value.y, 1))
		_apply_spec()

## Output file name without the extension. Defaults to the preset's asset id,
## falling back to this node's name.
@export var file_name := "":
	set(value):
		file_name = value
		update_configuration_warnings()

@export_group("Animated GIF", "gif_")
## Also writes an animated .gif alongside the .png, scrubbed frame by frame
## from an [AnimationPlayer] found anywhere under this node — no wiring
## needed, just drop one in.
@export var gif_enabled := false:
	set(value):
		gif_enabled = value
		update_configuration_warnings()

## Which animation to sample. Blank uses the player's autoplay animation, or
## its first animation if it has no autoplay set.
@export var gif_animation_name := "":
	set(value):
		gif_animation_name = value
		update_configuration_warnings()

@export_range(2, 30, 1, "suffix:fps") var gif_fps := 12

@export_range(2, 256, 1) var gif_max_colors := 256

## 0 = no limit. When set, quality is given up in this order: colours first,
## then dropped frames, then a smaller canvas — until the file fits or there
## is nothing cheaper left to try.
@export_range(0, 2000, 1, "or_greater", "suffix:KB") var gif_max_size_kb := 0

@export var gif_loop := true

@export_group("Editor Preview")
## Draws the labelled outline that marks out this asset's rectangle. Editor
## only — it is never part of the exported image.
@export var show_outline := true:
	set(value):
		show_outline = value
		queue_redraw()

@export var outline_color := Color(0.4, 0.85, 1.0, 0.9):
	set(value):
		outline_color = value
		queue_redraw()


func _init() -> void:
	# Presets are absolute pixel sizes, so the node must not be stretched by
	# anchors it inherited from whatever it was duplicated from.
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	resized.connect(queue_redraw)
	_apply_spec()


#region Spec

## The [StorePresets] entry backing this node, or an empty dictionary when the
## size is custom (or when the preset has since been removed from the table).
func spec() -> Dictionary:
	return StorePresets.get_preset(preset_id)


## The exported image size in pixels.
func asset_size() -> Vector2i:
	var preset := spec()
	if preset.is_empty():
		return custom_size
	return preset["size"]


## Whether the exported image must be opaque, must be transparent, or neither.
## See the ALPHA_* constants on [StorePresets].
func alpha_requirement() -> String:
	return StorePresets.preset_alpha(preset_id)


## File name (no extension) this asset is written out as.
func output_name() -> String:
	if not file_name.is_empty():
		return StorePresets.slugify(file_name)
	var asset_id := StorePresets.asset_of(preset_id)
	if not asset_id.is_empty() and StorePresets.has_preset(preset_id):
		return asset_id
	return StorePresets.slugify(String(name))


## The first [AnimationPlayer] found anywhere under this node, or null.
func find_gif_animation_player() -> AnimationPlayer:
	var found := find_children("*", "AnimationPlayer", true, false)
	return found[0] if not found.is_empty() else null


## The animation actually sampled for GIF export: [member gif_animation_name]
## if it names a real animation, else the player's autoplay animation, else
## its first animation. "" if none of those exist.
func resolved_gif_animation_name() -> String:
	var player := find_gif_animation_player()
	if player == null:
		return ""
	if not gif_animation_name.is_empty() and player.has_animation(gif_animation_name):
		return gif_animation_name
	if not player.autoplay.is_empty() and player.has_animation(player.autoplay):
		return player.autoplay
	var names := player.get_animation_list()
	return names[0] if not names.is_empty() else ""


## True once every piece needed to actually render a GIF is in place: enabled,
## a player, a resolvable animation, and a positive length to sample across.
func has_gif_animation() -> bool:
	if not gif_enabled:
		return false
	var player := find_gif_animation_player()
	if player == null:
		return false
	var anim_name := resolved_gif_animation_name()
	if anim_name.is_empty():
		return false
	var animation := player.get_animation(anim_name)
	return animation != null and animation.length > 0.0


func set_preset_id(value: String) -> void:
	if preset_id == value:
		return
	preset_id = value
	_apply_spec()
	# custom_size appears and disappears with the preset.
	notify_property_list_changed()


func _apply_spec() -> void:
	var target := Vector2(asset_size())
	if size != target:
		size = target
	queue_redraw()
	update_configuration_warnings()
	spec_changed.emit()


## Preset ids offered in the dropdown: the parent storefront's assets when
## there is one, otherwise everything. The current value is always included so
## that re-parenting a node can never drop its preset on the floor.
func _preset_choices() -> PackedStringArray:
	var choices := PackedStringArray()
	var store := get_parent() as StoreFront
	if store != null and not store.store_id.is_empty():
		choices = StorePresets.preset_ids_for_store(store.store_id)
	else:
		choices = StorePresets.preset_ids()
	if not preset_id.is_empty() and not Array(choices).has(preset_id):
		choices.append(preset_id)
	return choices

#endregion


#region Inspector

func _get_property_list() -> Array[Dictionary]:
	var properties: Array[Dictionary] = []

	# Persisted as a string, edited as an enum. Only the string is saved.
	properties.append({
		"name": "preset_id",
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_STORAGE,
	})

	var choices := _preset_choices()
	# A storefront's own assets don't need the store name repeating on every row.
	var qualify := get_parent() is not StoreFront
	var labels := PackedStringArray(["Custom"])
	for choice in choices:
		labels.append(StorePresets.preset_label(choice, qualify))
	properties.append({
		"name": "preset",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": ",".join(labels),
		"usage": PROPERTY_USAGE_EDITOR,
	})

	return properties


func _get(property: StringName) -> Variant:
	match property:
		&"preset_id":
			return preset_id
		&"preset":
			var index := Array(_preset_choices()).find(preset_id)
			return index + 1 if index >= 0 else 0
	return null


func _set(property: StringName, value: Variant) -> bool:
	match property:
		&"preset_id":
			set_preset_id(value)
			return true
		&"preset":
			var choices := _preset_choices()
			var index := int(value) - 1
			set_preset_id(choices[index] if index >= 0 and index < choices.size() else StorePresets.CUSTOM_ID)
			return true
	return false


func _validate_property(property: Dictionary) -> void:
	# Keep custom_size on disk but out of the way while a preset owns the size.
	if property.name == "custom_size" and not spec().is_empty():
		property.usage = PROPERTY_USAGE_STORAGE


func _property_can_revert(property: StringName) -> bool:
	return property == &"preset" or property == &"preset_id"


func _property_get_revert(property: StringName) -> Variant:
	match property:
		&"preset":
			return 0
		&"preset_id":
			return StorePresets.CUSTOM_ID
	return null


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()

	if get_parent() is not StoreFront:
		warnings.append("Put this under a StoreFront node so it knows which store folder to write into.")

	if not preset_id.is_empty() and spec().is_empty():
		warnings.append("Preset \"%s\" is not in StorePresets.STORES any more, so the size below is whatever it was last set to." % preset_id)

	var store := get_parent() as StoreFront
	var preset_store := StorePresets.store_of(preset_id)
	if store != null and not preset_store.is_empty() and preset_store != store.store_id:
		warnings.append("This is a %s preset but the parent storefront is %s, so it will be written into the wrong folder." % [
			StorePresets.store_label(preset_store), StorePresets.store_label(store.store_id),
		])

	var pixels := asset_size()
	if pixels.x <= 0 or pixels.y <= 0:
		warnings.append("Size is %dx%d, so there is nothing to export." % [pixels.x, pixels.y])

	if not file_name.is_empty() and StorePresets.slugify(file_name) != file_name:
		warnings.append("File name will be written as \"%s\"." % StorePresets.slugify(file_name))

	if gif_enabled:
		var gif_player := find_gif_animation_player()
		if gif_player == null:
			warnings.append("GIF export is on but there is no AnimationPlayer under this node, so no .gif will be written.")
		elif resolved_gif_animation_name().is_empty():
			warnings.append("%s has no animations to sample, so no .gif will be written." % gif_player.name)
		elif not has_gif_animation():
			warnings.append("\"%s\" has zero length, so no .gif will be written." % resolved_gif_animation_name())

	return warnings

#endregion


#region Editor preview

func _draw() -> void:
	# Runtime draws nothing at all, so none of this can leak into an export.
	if not Engine.is_editor_hint() or not show_outline:
		return

	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(outline_color, 0.06), true)
	draw_rect(rect, outline_color, false, _OUTLINE_WIDTH)

	# Corner ticks, so a large asset's extents stay findable when zoomed in.
	var tick := minf(_CORNER_TICK, minf(size.x, size.y) * 0.25)
	var corners: Array[Vector2] = [Vector2.ZERO, Vector2(size.x, 0.0), Vector2(0.0, size.y), size]
	for corner in corners:
		var toward_x := signf(size.x * 0.5 - corner.x) * tick
		var toward_y := signf(size.y * 0.5 - corner.y) * tick
		draw_line(corner, corner + Vector2(toward_x, 0.0), outline_color, _OUTLINE_WIDTH * 2.0)
		draw_line(corner, corner + Vector2(0.0, toward_y), outline_color, _OUTLINE_WIDTH * 2.0)

	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	draw_string(
		font,
		Vector2(0, -_LABEL_MARGIN),
		_outline_label(),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		outline_color,
	)


func _outline_label() -> String:
	var pixels := asset_size()
	var preset := spec()
	var title := String(preset["label"]) if not preset.is_empty() else String(name)
	var label := "%s  %dx%d" % [title, pixels.x, pixels.y]
	if alpha_requirement() == StorePresets.ALPHA_REQUIRED:
		label += "  (transparent)"
	elif alpha_requirement() == StorePresets.ALPHA_NONE:
		label += "  (opaque)"
	if has_gif_animation():
		label += "  +gif"
	return label

#endregion
