class_name DotAvatarContentCache
extends RefCounted

## Uploaded avatar, action and wearable GLBs on disk, keyed by the site's content id
## ([code]avatar|action|wearable/<id>/<version>[/code]), verified before
## they are kept and loaded at runtime with [GLTFDocument].
##
## [codeblock]
## var cache := DotAvatarContentCache.new()
## if not cache.has(row):
##     var stored := cache.store(row, downloaded_bytes)   # checks size and sha256
## var scene := cache.load_scene(row["contentId"])        # DotResult of a Node3D
## [/codeblock]
##
## A version bump is a new id, so an entry is never rewritten in place. Fetching belongs to the
## load gate that runs before connecting; this only checks, keeps and loads.

const CHANNEL := "avatar.content"

## The site's upload cap for avatars (AVATAR_MODEL_MAX_BYTES); actions are smaller.
const MAX_BYTES := 25 * 1024 * 1024

## The content id is a path segment, so nothing but this shape reaches the filesystem.
const _CONTENT_ID := "^(avatar|action|wearable)/[1-9][0-9]{0,9}/[1-9][0-9]{0,9}$"

## What a GLB's JSON may ask for before [GLTFDocument] sees it: the parser does whatever a file
## says, so a hostile upload or mirror is stopped here (external URIs, unknown extensions, counts
## that cost minutes or gigabytes).
const MAX_JSON_BYTES := 4 * 1024 * 1024
const MAX_NODES := 4096
const MAX_MESHES := 1024
const MAX_ACCESSORS := 8192
const MAX_ACCESSOR_ELEMENTS := 8_000_000
const MAX_KEYFRAMES := 1_000_000
const MAX_ANIMATIONS := 256
const MAX_CHANNELS := 16384
const MAX_IMAGES := 64
const MAX_IMAGE_SIDE := 4096
const MAX_MATERIALS := 256
const MAX_SKINS := 32
const MAX_JOINTS := 1024

## Extensions Godot's importer handles that change nothing outside the model.
const EXTENSIONS: PackedStringArray = ["KHR_materials_unlit", "KHR_materials_emissive_strength",
	"KHR_materials_pbrSpecularGlossiness", "KHR_materials_specular", "KHR_materials_ior", "KHR_materials_clearcoat",
	"KHR_materials_sheen", "KHR_materials_transmission", "KHR_materials_volume", "KHR_texture_transform",
	"KHR_mesh_quantization", "KHR_lights_punctual", "GODOT_single_root"]

var directory := "user://avatar_content"

static var _id_re: RegEx = null
## path -> sha256 of the files checked against a row's hash this session.
static var _verified: Dictionary = {}


## Whether [param s] is a well-formed content id.
static func is_content_id(s: String) -> bool:
	if _id_re == null:
		_id_re = RegEx.create_from_string(_CONTENT_ID)
	return _id_re.search(s) != null


## Where an entry lives, or "" for a malformed id.
func path_for(content_id: String) -> String:
	if not is_content_id(content_id):
		return ""
	return "%s/%s.glb" % [directory, content_id]


## Whether a library row ([code]contentId[/code], [code]size[/code], [code]sha256[/code]) is kept: the
## size every time, the hash the first time this session (a file that fails it is removed).
func has(row: Dictionary) -> bool:
	var path := path_for(String(row.get("contentId", "")))
	if path == "" or not FileAccess.file_exists(path):
		return false
	if DotPaths.file_size(path) != int(row.get("size", -1)):
		return false
	return _verify(path, String(row.get("sha256", "")).to_lower())


func _verify(path: String, sha: String) -> bool:
	if sha.length() != 64:
		return false
	if _verified.get(path, "") == sha:
		return true
	if DotHash.sha256_bytes(FileAccess.get_file_as_bytes(path)) != sha:
		DotLog.warn(CHANNEL, "kept avatar content failed its hash; removed", {"path": path})
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		var _e := _verified.erase(path)
		return false
	if _verified.size() > 1024:
		_verified.clear()
	_verified[path] = sha
	return true


## Keeps [param bytes] for [param row] after checking id, size, sha256 and the GLB magic.
func store(row: Dictionary, bytes: PackedByteArray) -> DotResult:
	var content_id := String(row.get("contentId", ""))
	var path := path_for(content_id)
	if path == "":
		return DotResult.fail(DotError.CODE_INVALID, "malformed avatar content id", content_id)
	if bytes.size() > MAX_BYTES or bytes.size() != int(row.get("size", -1)):
		return DotResult.fail(DotError.CODE_INTEGRITY, "avatar content has the wrong size", content_id)
	if DotHash.sha256_bytes(bytes) != String(row.get("sha256", "")).to_lower():
		return DotResult.fail(DotError.CODE_INTEGRITY, "avatar content hash mismatch", content_id)
	if bytes.size() < 4 or bytes.slice(0, 4).get_string_from_ascii() != "glTF":
		return DotResult.fail(DotError.CODE_INVALID, "avatar content is not a binary glTF", content_id)
	var safe := check_glb(bytes, content_id.get_slice("/", 0))
	if not safe.ok:
		return safe.wrap("avatar content %s" % content_id)

	var written := DotPaths.write_bytes(path, bytes)
	if not written.ok:
		return written.wrap("keeping avatar content %s" % content_id)
	_verified[path] = String(row.get("sha256", "")).to_lower()
	DotLog.debug(CHANNEL, "kept %s (%s)" % [content_id, DotPaths.format_bytes(bytes.size())])
	return DotResult.success(path)


## Builds the kept GLB into a scene. The caller owns (and frees) the returned [Node3D]. With
## [param sha256], a file not yet checked this session is checked first. Lights and cameras are
## dropped from an avatar or action; a wearable carrying one was refused by [method check_glb].
func load_scene(content_id: String, sha256: String = "") -> DotResult:
	var path := path_for(content_id)
	if path == "":
		return DotResult.fail(DotError.CODE_INVALID, "malformed avatar content id", content_id)
	if sha256 != "" and FileAccess.file_exists(path) and not _verify(path, sha256.to_lower()):
		return DotResult.fail(DotError.CODE_INTEGRITY, "kept avatar content failed its hash", content_id)
	var read := DotPaths.read_bytes(path)
	if not read.ok:
		return read.wrap("loading avatar content %s" % content_id)
	var safe := check_glb(read.value, content_id.get_slice("/", 0))
	if not safe.ok:
		return safe.wrap("loading avatar content %s" % content_id)

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_buffer(read.value, "", state)
	if err != OK:
		return DotResult.failure(DotError.from_engine(err, "parsing avatar content %s" % content_id))
	var scene := doc.generate_scene(state)
	if not scene is Node3D:
		if scene != null:
			scene.free()
		return DotResult.fail(DotError.CODE_INVALID, "avatar content has no 3D scene", content_id)
	for extra: Node in scene.find_children("*", "Light3D", true, false) + scene.find_children("*", "Camera3D", true, false):
		extra.get_parent().remove_child(extra)
		extra.free()
	return DotResult.success(scene)


## Reads a GLB's header and JSON chunk and refuses what [GLTFDocument] should never be handed:
## a buffer or image outside the file, an extension not in [constant EXTENSIONS], counts past the
## caps, an embedded image larger than [constant MAX_IMAGE_SIDE], and for a [param kind] of
## `wearable` any light or camera.
static func check_glb(bytes: PackedByteArray, kind: String = "") -> DotResult:
	if bytes.size() < 20 or bytes.slice(0, 4).get_string_from_ascii() != "glTF":
		return _refuse("not a binary glTF")
	if bytes.decode_u32(4) != 2 or int(bytes.decode_u32(8)) != bytes.size():
		return _refuse("an unsupported glTF version or a wrong length")
	var json_len := int(bytes.decode_u32(12))
	if bytes.decode_u32(16) != 0x4E4F534A or json_len <= 0 or json_len > MAX_JSON_BYTES or 20 + json_len > bytes.size():
		return _refuse("a missing or oversized JSON chunk")
	var parsed: Variant = JSON.parse_string(bytes.slice(20, 20 + json_len).get_string_from_utf8())
	if not parsed is Dictionary:
		return _refuse("unreadable JSON")
	var g: Dictionary = parsed
	var bin := PackedByteArray()
	var bin_at := 20 + ((json_len + 3) & ~3)
	if bin_at + 8 <= bytes.size() and bytes.decode_u32(bin_at + 4) == 0x004E4942:
		var bin_len := int(bytes.decode_u32(bin_at))
		if bin_at + 8 + bin_len > bytes.size():
			return _refuse("a BIN chunk past the end")
		bin = bytes.slice(bin_at + 8, bin_at + 8 + bin_len)

	for key: String in ["extensionsUsed", "extensionsRequired"]:
		for ext: Variant in _list(g, key):
			if not EXTENSIONS.has(String(ext)):
				return _refuse("the extension %s" % String(ext).left(64))
	for b: Variant in _list(g, "buffers"):
		if b is Dictionary and (b as Dictionary).has("uri") and not String(b["uri"]).begins_with("data:"):
			return _refuse("a buffer outside the file")
	var caps := {"nodes": MAX_NODES, "meshes": MAX_MESHES, "accessors": MAX_ACCESSORS, "animations": MAX_ANIMATIONS,
		"images": MAX_IMAGES, "materials": MAX_MATERIALS, "skins": MAX_SKINS, "textures": MAX_IMAGES * 2,
		"bufferViews": MAX_ACCESSORS, "buffers": 16, "scenes": 16, "samplers": 256}
	for key: String in caps:
		if _list(g, key).size() > int(caps[key]):
			return _refuse("too many %s" % key)
	if kind == "wearable":
		var lights: Variant = (g.get("extensions", {}) as Dictionary).get("KHR_lights_punctual") if g.get("extensions") is Dictionary else null
		if not _list(g, "cameras").is_empty() or lights != null or _list(g, "extensionsUsed").has("KHR_lights_punctual"):
			return _refuse("a light or camera on a wearable")
	var accessors := _list(g, "accessors")
	var elements := 0
	for a: Variant in accessors:
		elements += maxi(0, int((a as Dictionary).get("count", 0))) if a is Dictionary else 0
	if elements > MAX_ACCESSOR_ELEMENTS:
		return _refuse("too many vertices or keys")
	var channels := 0
	var keys := 0
	for anim: Variant in _list(g, "animations"):
		if not anim is Dictionary:
			continue
		channels += _list(anim, "channels").size()
		for sampler: Variant in _list(anim, "samplers"):
			var input := int((sampler as Dictionary).get("input", -1)) if sampler is Dictionary else -1
			if input >= 0 and input < accessors.size() and accessors[input] is Dictionary:
				keys += maxi(0, int((accessors[input] as Dictionary).get("count", 0)))
	if channels > MAX_CHANNELS or keys > MAX_KEYFRAMES:
		return _refuse("too many animation channels or keyframes")
	for skin: Variant in _list(g, "skins"):
		if skin is Dictionary and _list(skin, "joints").size() > MAX_JOINTS:
			return _refuse("too many joints")
	var views := _list(g, "bufferViews")
	for image: Variant in _list(g, "images"):
		if not image is Dictionary:
			return _refuse("a malformed image")
		var im: Dictionary = image
		if im.has("uri") and not String(im["uri"]).begins_with("data:"):
			return _refuse("an image outside the file")
		if im.has("bufferView"):
			var vi := int(im["bufferView"])
			if vi < 0 or vi >= views.size() or not views[vi] is Dictionary:
				return _refuse("an image with no buffer view")
			var view: Dictionary = views[vi]
			var at := int(view.get("byteOffset", 0))
			var side := _image_side(bin.slice(at, mini(bin.size(), at + mini(int(view.get("byteLength", 0)), 65536))))
			if side < 0 or side > MAX_IMAGE_SIDE:
				return _refuse("an embedded image that is not PNG or JPEG, or larger than %d px" % MAX_IMAGE_SIDE)
	return DotResult.success(true)


static func _refuse(why: String) -> DotResult:
	return DotResult.fail(DotError.CODE_INVALID, "refused a GLB: %s" % why)


static func _list(d: Variant, key: String) -> Array:
	var v: Variant = (d as Dictionary).get(key, []) if d is Dictionary else []
	return v if v is Array else []


## The larger side of a PNG or JPEG from its first bytes; -1 when it is neither or unreadable.
static func _image_side(head: PackedByteArray) -> int:
	if head.size() >= 24 and head[0] == 0x89 and head.slice(1, 4).get_string_from_ascii() == "PNG":
		return maxi(_be32(head, 16), _be32(head, 20))
	if head.size() < 4 or head[0] != 0xFF or head[1] != 0xD8:
		return -1
	var i := 2
	while i + 9 < head.size():
		if head[i] != 0xFF:
			return -1
		var marker := head[i + 1]
		if marker in [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]:
			return maxi((head[i + 5] << 8) | head[i + 6], (head[i + 7] << 8) | head[i + 8])
		i += 2 + ((head[i + 2] << 8) | head[i + 3])
	return -1


static func _be32(b: PackedByteArray, at: int) -> int:
	return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]


func describe() -> Dictionary:
	return {"directory": directory}
