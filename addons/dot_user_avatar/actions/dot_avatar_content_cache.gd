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

var directory := "user://avatar_content"

static var _id_re: RegEx = null


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


## Whether a library row ([code]contentId[/code], [code]size[/code]) is already kept at the right size.
func has(row: Dictionary) -> bool:
	var path := path_for(String(row.get("contentId", "")))
	if path == "" or not FileAccess.file_exists(path):
		return false
	return DotPaths.file_size(path) == int(row.get("size", -1))


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

	var written := DotPaths.write_bytes(path, bytes)
	if not written.ok:
		return written.wrap("keeping avatar content %s" % content_id)
	DotLog.debug(CHANNEL, "kept %s (%s)" % [content_id, DotPaths.format_bytes(bytes.size())])
	return DotResult.success(path)


## Builds the kept GLB into a scene. The caller owns (and frees) the returned [Node3D].
func load_scene(content_id: String) -> DotResult:
	var path := path_for(content_id)
	if path == "":
		return DotResult.fail(DotError.CODE_INVALID, "malformed avatar content id", content_id)
	var read := DotPaths.read_bytes(path)
	if not read.ok:
		return read.wrap("loading avatar content %s" % content_id)

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
	return DotResult.success(scene)


func describe() -> Dictionary:
	return {"directory": directory}
