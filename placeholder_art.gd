@tool
extends Control

## Stand-in artwork so a fresh [StoreAsset] renders something recognisable.
##
## Replace it with your own content — this scene exists only so that running
## the generator straight after cloning produces a full set of images. It scales
## its icon and title to whatever size the parent [StoreAsset] is, which is why
## none of the ~30 assets need hand-tuned font sizes.

## Fraction of the asset's shorter edge given over to the icon.
const _ICON_SCALE := 0.4
## Title size relative to the asset's height, and to its width, whichever is smaller.
const _TITLE_HEIGHT_SCALE := 0.16
const _TITLE_WIDTH_SCALE := 0.1
const _MIN_TITLE_SIZE := 12
const _MAX_TITLE_SIZE := 260

@export var title := "Game Title":
	set(value):
		title = value
		_refresh()

@export var background_color := Color.BLACK:
	set(value):
		background_color = value
		_refresh()

@export var icon: Texture2D:
	set(value):
		icon = value
		_refresh()

@onready var background: ColorRect = $Background
@onready var icon_rect: TextureRect = $Center/Stack/Icon
@onready var title_label: Label = $Center/Stack/Title


func _ready() -> void:
	resized.connect(_refresh)
	_refresh()


func _refresh() -> void:
	if not is_node_ready():
		return

	background.color = background_color
	# A logo asset is supposed to sit on a transparent background, so the
	# placeholder must not paint one in.
	var asset := get_parent() as StoreAsset
	background.visible = asset == null or asset.alpha_requirement() != StorePresets.ALPHA_REQUIRED

	icon_rect.texture = icon
	var icon_size := minf(size.x, size.y) * _ICON_SCALE
	icon_rect.custom_minimum_size = Vector2(icon_size, icon_size)
	icon_rect.visible = icon != null and icon_size >= 8.0

	var title_size := int(minf(size.y * _TITLE_HEIGHT_SCALE, size.x * _TITLE_WIDTH_SCALE))
	title_label.text = title
	title_label.visible = title_size >= _MIN_TITLE_SIZE and not title.is_empty()
	title_label.add_theme_font_size_override("font_size", clampi(title_size, _MIN_TITLE_SIZE, _MAX_TITLE_SIZE))
