@tool
class_name StoreFront
extends Control

## Groups the [StoreAsset] nodes for one storefront and names their output folder.
##
## Each storefront writes into its own subfolder, so
## [code]Steam/header_capsule[/code] becomes
## [code]store_assets/steam/header_capsule.png[/code]. Delete a storefront you
## are not shipping to and it simply stops being generated; add a node and
## point it at a store in [StorePresets] and it starts being generated. Nothing
## else refers to these nodes by name.

const _LABEL_MARGIN := 34.0
const _MIN_ARRANGE_SPACING := 8

## Which [StorePresets] store this represents. Drives the output folder and the
## preset dropdown on every child [StoreAsset].
var store_id: String = StorePresets.CUSTOM_ID

## Skips this whole storefront without deleting it.
@export var enabled := true:
	set(value):
		enabled = value
		queue_redraw()
		update_configuration_warnings()

## Output folder name. Defaults to the store's folder from [StorePresets], or
## to this node's name when the store is custom.
@export var folder_override := "":
	set(value):
		folder_override = value
		queue_redraw()
		update_configuration_warnings()

@export_group("Editor Layout")
## Spreads the child assets out so their outlines don't sit on top of each
## other. Positions are editor conveniences only — the generator renders each
## asset from its own origin, so moving them around cannot shift an export.
@export var auto_arrange := true:
	set(value):
		auto_arrange = value
		if value:
			arrange_assets()

@export_range(0, 512, 1, "or_greater") var arrange_spacing := 64:
	set(value):
		arrange_spacing = maxi(value, _MIN_ARRANGE_SPACING)
		arrange_assets()

## Assets wrap onto a new row once a row gets wider than this.
@export_range(512, 16384, 1, "or_greater") var arrange_wrap_width := 4200:
	set(value):
		arrange_wrap_width = maxi(value, 512)
		arrange_assets()

@export_group("Editor Preview")
@export var label_color := Color(1.0, 0.85, 0.4, 0.9):
	set(value):
		label_color = value
		queue_redraw()

var _layout_fingerprint := ""


func _init() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	child_order_changed.connect(_on_children_changed)
	arrange_assets()


func _process(_delta: float) -> void:
	# Child assets resize whenever their preset changes, and there is no single
	# signal for "anything under me moved or resized", so the layout is checked
	# from a cheap fingerprint. Editor only.
	if not Engine.is_editor_hint() or not auto_arrange:
		return
	if _fingerprint() != _layout_fingerprint:
		arrange_assets()


#region Store

## Folder these images are written into, relative to the output root.
func output_folder() -> String:
	if not folder_override.is_empty():
		return StorePresets.slugify(folder_override)
	if not store_id.is_empty():
		return StorePresets.store_folder(store_id)
	return StorePresets.slugify(name)


## Child [StoreAsset] nodes, in tree order.
func assets() -> Array[StoreAsset]:
	var found: Array[StoreAsset] = []
	for child in get_children():
		if child is StoreAsset:
			found.append(child)
	return found


func set_store_id(value: String) -> void:
	if store_id == value:
		return
	store_id = value
	# Child dropdowns list this store's assets, so they need rebuilding.
	for asset in assets():
		asset.notify_property_list_changed()
	queue_redraw()
	update_configuration_warnings()

#endregion


#region Editor layout

## Packs the child assets into rows so every outline is visible at once.
func arrange_assets() -> void:
	if not is_inside_tree() or not auto_arrange:
		return

	var pen := Vector2.ZERO
	var row_height := 0.0
	var extents := Vector2.ZERO

	for asset in assets():
		var asset_size := Vector2(asset.asset_size())
		if pen.x > 0.0 and pen.x + asset_size.x > float(arrange_wrap_width):
			pen = Vector2(0.0, pen.y + row_height + arrange_spacing + _LABEL_MARGIN)
			row_height = 0.0
		asset.position = pen
		pen.x += asset_size.x + arrange_spacing
		row_height = maxf(row_height, asset_size.y)
		extents = extents.max(asset.position + asset_size)

	size = extents
	_layout_fingerprint = _fingerprint()
	queue_redraw()


## Cheap summary of everything the layout depends on.
func _fingerprint() -> String:
	var parts := PackedStringArray([str(arrange_spacing), str(arrange_wrap_width)])
	for asset in assets():
		parts.append("%s:%s" % [asset.name, asset.asset_size()])
	return "|".join(parts)


func _on_children_changed() -> void:
	arrange_assets()
	update_configuration_warnings()

#endregion


#region Inspector

func _get_property_list() -> Array[Dictionary]:
	return [
		{
			"name": "store_id",
			"type": TYPE_STRING,
			"usage": PROPERTY_USAGE_STORAGE,
		},
		{
			"name": "store",
			"type": TYPE_INT,
			"hint": PROPERTY_HINT_ENUM,
			"hint_string": StorePresets.store_hint_string(),
			"usage": PROPERTY_USAGE_EDITOR,
		},
	]


func _get(property: StringName) -> Variant:
	match property:
		&"store_id":
			return store_id
		&"store":
			return StorePresets.store_index(store_id)
	return null


func _set(property: StringName, value: Variant) -> bool:
	match property:
		&"store_id":
			set_store_id(value)
			return true
		&"store":
			set_store_id(StorePresets.store_at(int(value)))
			return true
	return false


func _property_can_revert(property: StringName) -> bool:
	return property == &"store" or property == &"store_id"


func _property_get_revert(property: StringName) -> Variant:
	return 0 if property == &"store" else StorePresets.CUSTOM_ID


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()

	if store_id.is_empty() and folder_override.is_empty():
		warnings.append("Pick a store, or set a folder override — otherwise images land in a folder named after this node.")

	if not store_id.is_empty() and StorePresets.get_store(store_id).is_empty():
		warnings.append("Store \"%s\" is not in StorePresets.STORES any more." % store_id)

	if assets().is_empty():
		warnings.append("No StoreAsset children, so this storefront generates nothing.")

	var seen := {}
	for asset in assets():
		var output := asset.output_name()
		if seen.has(output):
			warnings.append("\"%s\" and \"%s\" both write to %s.png — one will overwrite the other." % [
				seen[output], asset.name, output,
			])
		seen[output] = asset.name

	var missing := PackedStringArray()
	for preset_id in StorePresets.preset_ids_for_store(store_id):
		var preset := StorePresets.get_preset(preset_id)
		if preset.get("required", false) and not _has_preset(preset_id):
			missing.append(String(preset["label"]))
	if not missing.is_empty():
		warnings.append("%s also requires: %s." % [StorePresets.store_label(store_id), ", ".join(missing)])

	return warnings


func _has_preset(preset_id: String) -> bool:
	for asset in assets():
		if asset.preset_id == preset_id:
			return true
	return false

#endregion


#region Editor preview

func _draw() -> void:
	if not Engine.is_editor_hint():
		return
	var font := get_theme_default_font()
	var font_size := int(get_theme_default_font_size() * 1.5)
	var store_name: String = StorePresets.store_label(store_id) if not store_id.is_empty() else String(name)
	var label := "%s  ->  store_assets/%s/" % [store_name, output_folder()]
	if not enabled:
		label += "   [disabled]"
	draw_string(
		font,
		Vector2(0, -_LABEL_MARGIN),
		label,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		Color(label_color, 0.4) if not enabled else label_color,
	)

#endregion
