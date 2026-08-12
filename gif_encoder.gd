@tool
class_name GifEncoder
extends RefCounted

## A self-contained GIF89a encoder: octree colour quantization plus GIF's own
## variable-width LZW compression, written from the spec with no external
## binary and no other Godot module involved beyond [Image].
##
## The only entry point most callers need is [method encode_within_budget]: it
## takes a list of same-size frames and, if [param options] sets a byte budget,
## retries with cheaper settings (fewer colours, then fewer frames, then a
## smaller canvas, in that order) until the result fits or it runs out of
## tiers to try.
##
## GIF has no partial transparency — only a single palette index can be
## "transparent". Any pixel with alpha below 128 in any frame is treated as
## transparent; everything else is treated as fully opaque.

const _TRANSPARENT_ALPHA_THRESHOLD := 128
const _MAX_TRAINING_SAMPLES := 60000
const _MAX_LZW_CODE_SIZE := 12
const _LZW_DICTIONARY_LIMIT := 1 << _MAX_LZW_CODE_SIZE

static var _header: PackedByteArray = "GIF89a".to_utf8_buffer()
static var _netscape_loop: PackedByteArray = "NETSCAPE2.0".to_utf8_buffer()


## Encodes [param frames] (same-size [Image]s, any format) into a looping GIF,
## shrinking quality tier by tier until the result fits [code]options.max_size_bytes[/code]
## or the cheapest tier has been tried.
##
## [param delay_cs] is the uniform per-frame delay in centiseconds (GIF's
## native unit — 1/100 second). [param options] keys, all optional:
## [code]max_colors[/code] (2-256, default 256), [code]loop[/code] (default
## true), [code]max_size_bytes[/code] (0 = unlimited, default 0).
##
## Returns a dictionary: [code]ok[/code], and on success [code]bytes[/code]
## (PackedByteArray), [code]colors[/code] (palette entries actually used),
## [code]frame_count[/code], [code]width[/code], [code]height[/code],
## [code]under_budget[/code]. On failure, [code]error[/code] explains why.
static func encode_within_budget(frames: Array[Image], delay_cs: int, options: Dictionary = {}) -> Dictionary:
	if frames.is_empty():
		return {"ok": false, "error": "No frames to encode."}
	if frames[0].get_width() <= 0 or frames[0].get_height() <= 0:
		return {"ok": false, "error": "Frames have no size."}

	var base_colors := clampi(int(options.get("max_colors", 256)), 2, 256)
	var loop: bool = options.get("loop", true)
	var max_size := int(options.get("max_size_bytes", 0))

	# No budget requested: a single encode at the requested quality is all
	# that is needed, so skip the tiered search entirely.
	if max_size <= 0:
		var result := _encode(frames, delay_cs, base_colors, loop)
		result["ok"] = true
		result["under_budget"] = true
		return result

	var color_tiers: Array[int] = [base_colors]
	for step in [160, 96, 64, 40, 24, 16]:
		if step < color_tiers[-1]:
			color_tiers.append(step)

	# {frames, delay_cs} pairs. Dropping frames keeps the loop's total length
	# the same by multiplying the remaining frames' delay.
	var frame_tiers: Array[Dictionary] = [{"frames": frames, "delay_cs": delay_cs}]
	if frames.size() >= 12:
		frame_tiers.append({"frames": _take_every_nth(frames, 2), "delay_cs": delay_cs * 2})
	if frames.size() >= 24:
		frame_tiers.append({"frames": _take_every_nth(frames, 4), "delay_cs": delay_cs * 4})

	var scale_tiers: PackedFloat32Array = [1.0, 0.75, 0.5, 0.35]
	var min_scaled_dimension := 16
	# Bounds worst-case work on pathological input (e.g. per-pixel random
	# noise, which barely compresses at any setting) so the search always
	# finishes in bounded time instead of exhausting every combination.
	var max_attempts := 20
	var attempts := 0

	var best: Dictionary = {}
	for scale in scale_tiers:
		var scaled_frames := frames if scale == 1.0 else _scaled_copies(frames, scale, min_scaled_dimension)
		if scaled_frames.is_empty():
			continue
		for frame_tier in frame_tiers:
			var tier_frames: Array[Image] = frame_tier["frames"] if scale == 1.0 else _scaled_copies(frame_tier["frames"], scale, min_scaled_dimension)
			for colors in color_tiers:
				attempts += 1
				var attempt := _encode(tier_frames, frame_tier["delay_cs"], colors, loop)
				if best.is_empty() or attempt["bytes"].size() < best["bytes"].size():
					best = attempt
				if attempt["bytes"].size() <= max_size:
					attempt["ok"] = true
					attempt["under_budget"] = true
					return attempt
				if attempts >= max_attempts:
					best["ok"] = true
					best["under_budget"] = false
					return best

	best["ok"] = true
	best["under_budget"] = false
	return best


## Writes the result of [method encode_within_budget] to [param path]. Returns
## the same dictionary with an added [code]path[/code] key, or an
## [code]ok: false[/code] dictionary if the file could not be opened.
static func encode_to_file(frames: Array[Image], delay_cs: int, path: String, options: Dictionary = {}) -> Dictionary:
	var result := encode_within_budget(frames, delay_cs, options)
	if not result.get("ok", false):
		return result
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "Could not open %s for writing (%s)." % [path, error_string(FileAccess.get_open_error())]}
	file.store_buffer(result["bytes"])
	file.close()
	result["path"] = path
	return result


#region Frame tiers

static func _take_every_nth(frames: Array[Image], n: int) -> Array[Image]:
	var kept: Array[Image] = []
	var i := 0
	while i < frames.size():
		kept.append(frames[i])
		i += n
	# Always keep the final frame, so a looping animation doesn't jump.
	if kept.is_empty() or kept[-1] != frames[-1]:
		kept.append(frames[-1])
	return kept


static func _scaled_copies(frames: Array[Image], factor: float, min_dimension: int) -> Array[Image]:
	var width := maxi(int(frames[0].get_width() * factor), min_dimension)
	var height := maxi(int(frames[0].get_height() * factor), min_dimension)
	var copies: Array[Image] = []
	for frame in frames:
		var copy := frame.duplicate()
		copy.resize(width, height, Image.INTERPOLATE_LANCZOS)
		copies.append(copy)
	return copies

#endregion


#region Core encode (one quality tier)

static func _encode(frames: Array[Image], delay_cs: int, max_colors: int, loop: bool) -> Dictionary:
	var width := frames[0].get_width()
	var height := frames[0].get_height()
	var rgba_frames: Array[Image] = []
	for frame in frames:
		var rgba := frame
		if rgba.get_format() != Image.FORMAT_RGBA8:
			rgba = frame.duplicate()
			rgba.convert(Image.FORMAT_RGBA8)
		rgba_frames.append(rgba)

	var needs_transparency := false
	for frame in rgba_frames:
		if _has_transparent_pixel(frame.get_data()):
			needs_transparency = true
			break

	var quantizer := _OctreeQuantizer.new(max_colors - (1 if needs_transparency else 0))
	_train_quantizer(quantizer, rgba_frames)
	var palette := quantizer.build_palette()
	var transparent_index := -1
	if needs_transparency:
		transparent_index = 0
		palette.push_front(Color8(0, 0, 0))

	var padded_size := clampi(_next_power_of_two(palette.size()), 2, 256)
	while palette.size() < padded_size:
		palette.append(Color8(0, 0, 0))
	var min_code_size := maxi(2, _bits_for(padded_size))

	var indexed_frames: Array[PackedByteArray] = []
	for frame in rgba_frames:
		indexed_frames.append(_index_frame(frame, quantizer, transparent_index, needs_transparency))

	var bytes := _assemble_gif(indexed_frames, width, height, palette, padded_size, min_code_size, delay_cs, loop, transparent_index)
	return {
		"bytes": bytes,
		"colors": palette.size() - (1 if needs_transparency else 0),
		"frame_count": frames.size(),
		"width": width,
		"height": height,
	}


static func _has_transparent_pixel(data: PackedByteArray) -> bool:
	var i := 3
	while i < data.size():
		if data[i] < _TRANSPARENT_ALPHA_THRESHOLD:
			return true
		i += 4
	return false


static func _train_quantizer(quantizer: _OctreeQuantizer, frames: Array[Image]) -> void:
	var total_pixels := 0
	for frame in frames:
		total_pixels += frame.get_width() * frame.get_height()
	var stride := maxi(1, total_pixels / maxi(1, _MAX_TRAINING_SAMPLES))

	var counter := 0
	for frame in frames:
		var data := frame.get_data()
		var pixel_count := frame.get_width() * frame.get_height()
		for pixel in range(pixel_count):
			if counter % stride == 0:
				var offset := pixel * 4
				if data[offset + 3] >= _TRANSPARENT_ALPHA_THRESHOLD:
					quantizer.add_color(data[offset], data[offset + 1], data[offset + 2])
			counter += 1


static func _index_frame(frame: Image, quantizer: _OctreeQuantizer, transparent_index: int, needs_transparency: bool) -> PackedByteArray:
	var data := frame.get_data()
	var pixel_count := frame.get_width() * frame.get_height()
	var indices := PackedByteArray()
	indices.resize(pixel_count)
	var shift := 1 if needs_transparency else 0
	for pixel in range(pixel_count):
		var offset := pixel * 4
		if needs_transparency and data[offset + 3] < _TRANSPARENT_ALPHA_THRESHOLD:
			indices[pixel] = transparent_index
		else:
			indices[pixel] = quantizer.get_index(data[offset], data[offset + 1], data[offset + 2]) + shift
	return indices

#endregion


#region GIF container assembly

static func _assemble_gif(
	indexed_frames: Array[PackedByteArray],
	width: int,
	height: int,
	palette: Array,
	padded_size: int,
	min_code_size: int,
	delay_cs: int,
	loop: bool,
	transparent_index: int,
) -> PackedByteArray:
	var out := PackedByteArray()
	out.append_array(_header)

	_append_u16(out, width)
	_append_u16(out, height)
	var color_resolution_bits := _bits_for(padded_size) - 1
	out.append(0x80 | (color_resolution_bits << 4) | color_resolution_bits)  # global color table present
	out.append(0)  # background color index
	out.append(0)  # pixel aspect ratio

	for entry in palette:
		var c: Color = entry
		out.append(int(c.r8))
		out.append(int(c.g8))
		out.append(int(c.b8))

	if loop and indexed_frames.size() > 1:
		out.append(0x21)  # extension introducer
		out.append(0xFF)  # application extension
		out.append(0x0B)
		out.append_array(_netscape_loop)
		out.append(0x03)
		out.append(0x01)
		_append_u16(out, 0)  # loop forever
		out.append(0x00)

	for indices in indexed_frames:
		_append_graphic_control_extension(out, delay_cs, transparent_index)
		_append_image_descriptor(out, width, height)
		out.append(min_code_size)
		out.append_array(_pack_sub_blocks(_lzw_encode(indices, min_code_size)))

	out.append(0x3B)  # trailer
	return out


static func _append_graphic_control_extension(out: PackedByteArray, delay_cs: int, transparent_index: int) -> void:
	out.append(0x21)
	out.append(0xF9)
	out.append(0x04)
	var has_transparency := transparent_index >= 0
	# Disposal method 2 (restore to background) avoids ghosting between loops.
	out.append((2 << 2) | (1 if has_transparency else 0))
	_append_u16(out, delay_cs)
	out.append(maxi(transparent_index, 0))
	out.append(0x00)


static func _append_image_descriptor(out: PackedByteArray, width: int, height: int) -> void:
	out.append(0x2C)
	_append_u16(out, 0)
	_append_u16(out, 0)
	_append_u16(out, width)
	_append_u16(out, height)
	out.append(0x00)  # no local color table, no interlace


static func _append_u16(out: PackedByteArray, value: int) -> void:
	out.append(value & 0xFF)
	out.append((value >> 8) & 0xFF)


static func _pack_sub_blocks(data: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	var offset := 0
	while offset < data.size():
		var chunk_size := mini(255, data.size() - offset)
		out.append(chunk_size)
		out.append_array(data.slice(offset, offset + chunk_size))
		offset += chunk_size
	out.append(0x00)
	return out


static func _next_power_of_two(n: int) -> int:
	var p := 1
	while p < n:
		p *= 2
	return p


static func _bits_for(count: int) -> int:
	var bits := 1
	while (1 << bits) < count:
		bits += 1
	return bits

#endregion


#region LZW (GIF variant)

class _BitWriter:
	extends RefCounted
	var bytes := PackedByteArray()
	var _buffer := 0
	var _buffer_bits := 0

	func write(code: int, bits: int) -> void:
		_buffer |= code << _buffer_bits
		_buffer_bits += bits
		while _buffer_bits >= 8:
			bytes.append(_buffer & 0xFF)
			_buffer >>= 8
			_buffer_bits -= 8

	func flush() -> void:
		if _buffer_bits > 0:
			bytes.append(_buffer & 0xFF)
			_buffer = 0
			_buffer_bits = 0


## Standard GIF-flavoured LZW: codes 0..clear_code-1 are the raw palette
## indices, clear_code and end_code are reserved, and the dictionary resets
## with a fresh Clear Code whenever it would grow past 4096 entries.
static func _lzw_encode(indices: PackedByteArray, min_code_size: int) -> PackedByteArray:
	var clear_code := 1 << min_code_size
	var end_code := clear_code + 1
	var code_size := min_code_size + 1
	var next_code := clear_code + 2
	var trie := {}
	var writer := _BitWriter.new()

	writer.write(clear_code, code_size)

	if indices.is_empty():
		writer.write(end_code, code_size)
		writer.flush()
		return writer.bytes

	var prefix_code: int = indices[0]
	for i in range(1, indices.size()):
		var symbol: int = indices[i]
		var key := (prefix_code << 8) | symbol
		if trie.has(key):
			prefix_code = trie[key]
			continue

		writer.write(prefix_code, code_size)
		if next_code < _LZW_DICTIONARY_LIMIT:
			trie[key] = next_code
			next_code += 1
			# GIF's LZW is "early change": a decoder can only build a dictionary
			# entry once it has decoded the code *after* the one that created
			# it, so its view of next_code trails the encoder's by exactly one.
			# The encoder must widen codes one entry sooner than its own
			# next_code would naively suggest, to stay in sync with that lag.
			if next_code == (1 << code_size) + 1 and code_size < _MAX_LZW_CODE_SIZE:
				code_size += 1
		else:
			writer.write(clear_code, code_size)
			trie.clear()
			next_code = clear_code + 2
			code_size = min_code_size + 1
		prefix_code = symbol

	writer.write(prefix_code, code_size)
	writer.write(end_code, code_size)
	writer.flush()
	return writer.bytes

#endregion


#region Octree colour quantization

## Groups sampled colours into up to [member max_colors] representative
## colours by recursively subdividing RGB space and merging (from the deepest
## level up) whenever there are too many groups — the classic Gervautz &
## Purgathofer octree quantizer.
class _OctreeQuantizer:
	extends RefCounted

	class _Node:
		extends RefCounted
		var children: Array = [null, null, null, null, null, null, null, null]
		var is_leaf := false
		var pixel_count := 0
		var red := 0
		var green := 0
		var blue := 0
		var palette_index := 0

	var max_colors: int
	var _root := _Node.new()
	var _leaf_count := 0
	# Interior nodes that could still be merged away, bucketed by their own
	# depth (1..7). Reducing always drains the deepest bucket first, which
	# guarantees every node it ever merges is already a genuine leaf.
	var _reducible_by_depth: Array = []

	func _init(colors: int) -> void:
		max_colors = maxi(colors, 1)
		for _i in range(8):
			_reducible_by_depth.append([])

	func add_color(r: int, g: int, b: int) -> void:
		var node := _root
		var depth := 0
		while depth < 8:
			var index := _child_index(r, g, b, depth)
			var child = node.children[index]
			if child == null:
				child = _Node.new()
				node.children[index] = child
				if depth + 1 <= 7:
					_reducible_by_depth[depth + 1].append(child)
			node = child
			depth += 1
		if not node.is_leaf:
			node.is_leaf = true
			_leaf_count += 1
		node.pixel_count += 1
		node.red += r
		node.green += g
		node.blue += b
		while _leaf_count > max_colors:
			if not _reduce():
				break

	## Builds the final palette (assigning each surviving leaf a palette
	## index) and returns it as an [code]Array[Color][/code].
	func build_palette() -> Array:
		var palette: Array[Color] = []
		_assign_palette(_root, palette)
		return palette

	## Iterative descent — the hot path, called once per output pixel.
	func get_index(r: int, g: int, b: int) -> int:
		var node := _root
		var depth := 0
		while not node.is_leaf:
			var index := _child_index(r, g, b, depth)
			var child = node.children[index]
			if child == null:
				for candidate in node.children:
					if candidate != null:
						child = candidate
						break
			node = child
			depth += 1
		return node.palette_index

	func _child_index(r: int, g: int, b: int, depth: int) -> int:
		var shift := 7 - depth
		var bit := 1 << shift
		var index := 0
		if r & bit:
			index |= 4
		if g & bit:
			index |= 2
		if b & bit:
			index |= 1
		return index

	func _reduce() -> bool:
		var depth := 7
		while depth >= 1 and _reducible_by_depth[depth].is_empty():
			depth -= 1
		if depth < 1:
			return false
		var node: _Node = _reducible_by_depth[depth].pop_back()
		for child in node.children:
			if child != null:
				node.red += child.red
				node.green += child.green
				node.blue += child.blue
				node.pixel_count += child.pixel_count
				_leaf_count -= 1
		node.children = [null, null, null, null, null, null, null, null]
		node.is_leaf = true
		_leaf_count += 1
		return true

	func _assign_palette(node: _Node, palette: Array) -> void:
		if node.is_leaf:
			var count := maxi(node.pixel_count, 1)
			node.palette_index = palette.size()
			palette.append(Color8(node.red / count, node.green / count, node.blue / count))
			return
		for child in node.children:
			if child != null:
				_assign_palette(child, palette)

#endregion
