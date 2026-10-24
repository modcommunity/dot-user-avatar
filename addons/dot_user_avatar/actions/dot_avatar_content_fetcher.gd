class_name DotAvatarContentFetcher
extends RefCounted

## Downloads the avatar and action files a server requires into a [DotAvatarContentCache],
## before the client connects.
##
## [codeblock]
## var fetcher := DotAvatarContentFetcher.new()
## fetcher.http = http                       # a DotHttp in the tree; HTTPRequest underneath, so web works
## fetcher.gate = client.gate                # optional: holds the cover and shows progress
## var res := await fetcher.prepare("https://site", server_id, required_ids)
## if not res.ok:
##     show_error(res.error.message)         # and do not connect
##     return
## connect_to_server()
## [/codeblock]
##
## [b]Contract.[/b] The server advertises content ids ([code]avatar/<id>/<version>[/code],
## [code]action/<id>/<version>[/code]); the site's [code]/api/avatar/v1/library[/code] lists
## url, size and sha256 for each. Every required id must be listed and arrive verified, or
## [method prepare] fails and the gate stays held, so a client never joins half-loaded. A
## version bump is a new id, so nothing is replaced in place and nothing is unmounted.
## Files are loaded with [GLTFDocument], not mounted as packs, so there is no pack to leak.

signal failed(error: DotError)

const CHANNEL := "avatar.fetch"

## The gate reason held while files arrive.
const REASON := &"avatar_content"

## Most ids one server may require; a hostile advertisement cannot queue thousands.
const MAX_REQUIRED := 64

var http: DotHttp = null
var cache := DotAvatarContentCache.new()
var gate: DotLoadGate = null


## Fetches the library, then every missing file in [param required]. Success value is the
## number of files downloaded (zero when all were already kept).
func prepare(base_url: String, server_id: int, required: Array) -> DotResult:
	var ids := _clean_ids(required)
	if not ids.ok:
		return _fail(ids.error)
	if (ids.value as Array).is_empty():
		return DotResult.success(0)
	if http == null:
		return _fail(DotError.make(DotError.CODE_STATE, "no HTTP client to fetch avatar content with"))

	if gate != null and is_instance_valid(gate):
		gate.hold(REASON, "Downloading avatars")
	var lib := await http.get_json("%s/api/avatar/v1/library?server=%d" % [base_url.trim_suffix("/"), server_id])
	if not lib.ok:
		return _fail(lib.error, "reading the avatar library")
	return await fetch_rows(rows_for(lib.value, ids.value))


## The library rows (avatars, then actions) that carry a file, keyed by content id.
static func index_library(library: Variant) -> Dictionary:
	var out := {}
	if not library is Dictionary:
		return out
	for key in ["avatars", "actions"]:
		var list: Variant = (library as Dictionary).get(key, [])
		if not list is Array:
			continue
		for row in list:
			if row is Dictionary and row.get("url") is String and row.get("contentId") is String:
				out[row["contentId"]] = row
	return out


## The rows for [param ids]; an id the library does not list becomes a row with no url, which
## [method fetch_rows] refuses by name.
static func rows_for(library: Variant, ids: Array) -> Array:
	var index := index_library(library)
	var rows := []
	for id in ids:
		rows.append(index.get(id, {"contentId": id}))
	return rows


## Downloads and keeps every row not already cached. Holds the gate for the duration and
## releases it only if all succeed.
func fetch_rows(rows: Array) -> DotResult:
	if gate != null and is_instance_valid(gate):
		gate.hold(REASON, "Downloading avatars")
	var todo := []
	for row in rows:
		var id := String(row.get("contentId", ""))
		var url := String(row.get("url", ""))
		if url == "":
			return _fail(DotError.make(DotError.CODE_INVALID, "the server requires %s but the library does not list it" % id))
		if not (url.begins_with("https://") or url.begins_with("http://")):
			return _fail(DotError.make(DotError.CODE_INVALID, "avatar content %s has a non-http url" % id))
		if int(row.get("size", -1)) <= 0 or int(row.get("size", -1)) > DotAvatarContentCache.MAX_BYTES:
			return _fail(DotError.make(DotError.CODE_INTEGRITY, "avatar content %s has an unusable size" % id))
		if not cache.has(row):
			todo.append(row)

	var done := 0
	for row in todo:
		_progress(done, todo.size(), String(row["contentId"]))
		var got := await http.get_bytes(String(row["url"]))
		if not got.ok:
			return _fail(got.error, "downloading %s" % row["contentId"])
		var kept := cache.store(row, got.value)
		if not kept.ok:
			return _fail(kept.error, "verifying %s" % row["contentId"])
		done += 1
	# The cache writes under user://; a browser keeps that in memory until synced.
	if done > 0:
		DotWeb.sync_filesystem()
	if gate != null and is_instance_valid(gate):
		gate.release(REASON)
	return DotResult.success(done)


func _clean_ids(required: Array) -> DotResult:
	if required.size() > MAX_REQUIRED:
		return DotResult.fail(DotError.CODE_INVALID, "the server requires too many avatar files", str(required.size()))
	var out := []
	for id in required:
		if not id is String or not DotAvatarContentCache.is_content_id(id):
			return DotResult.fail(DotError.CODE_INVALID, "the server advertised a malformed content id", str(id).left(64))
		if not out.has(id):
			out.append(id)
	return DotResult.success(out)


func _progress(done: int, total: int, id: String) -> void:
	if gate != null and is_instance_valid(gate):
		gate.set_progress(float(done) / maxf(1.0, float(total)), "Downloading %s (%d of %d)" % [id, done + 1, total])


## The gate stays held, with the reason as its text: the caller does not connect.
func _fail(err: DotError, context: String = "") -> DotResult:
	var res := DotResult.failure(err)
	if context != "":
		res = res.wrap(context)
	DotLog.warn(CHANNEL, str(res.error))
	if gate != null and is_instance_valid(gate):
		gate.set_progress(gate.progress(), "Could not load avatars: %s" % res.error.message)
	failed.emit(res.error)
	return res
