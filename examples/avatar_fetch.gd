extends Node

## Fetch-before-connect for avatar and action files, offline: a fake HTTP client serves the
## library and the files. godot --headless --path . res://examples/avatar_fetch.tscn

const SECTIONS := 7
const CHECKS := 44

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0


## Serves a library and files from memory; counts requests.
class FakeHttp extends DotHttp:
	var files := {}
	var library := {}
	var library_fails := false
	var requests: Array[String] = []

	func get_json(path: String, _headers: Dictionary = {}) -> DotResult:
		requests.append(path)
		if library_fails:
			return DotResult.fail(DotError.CODE_NETWORK, "offline")
		return DotResult.success(library)

	## url -> bytes after which the next download of it breaks off (once).
	var cut := {}
	## The Range start of every download, in order.
	var ranges: Array[int] = []

	## Every max_bytes asked for, in order; urls that answer short and still report success.
	var caps: Array[int] = []
	var short := {}

	func get_bytes(path: String, _headers: Dictionary = {}, max_bytes: int = 0) -> DotResult:
		requests.append(path)
		caps.append(max_bytes)
		if not files.has(path):
			return DotResult.fail(DotError.CODE_HTTP, "404")
		if max_bytes > 0 and (files[path] as PackedByteArray).size() > max_bytes:
			return DotResult.fail(DotError.CODE_INVALID, "The response was too large.")
		return DotResult.success(files[path])

	func download_to_file(path: String, dest: String, range_start: int = 0, _headers: Dictionary = {}, max_bytes: int = 0) -> DotResult:
		requests.append(path)
		ranges.append(range_start)
		caps.append(max_bytes)
		if not files.has(path):
			return DotResult.fail(DotError.CODE_HTTP, "404")
		var body: PackedByteArray = (files[path] as PackedByteArray).slice(range_start)
		var stop := int(cut.get(path, -1))
		cut.erase(path)
		if short.has(path):
			body = body.slice(0, body.size() / 2)
		elif max_bytes > 0 and body.size() > max_bytes:
			stop = max_bytes
		if stop >= 0:
			body = body.slice(0, stop)
		DotPaths.ensure_parent_dir(dest)
		var f := FileAccess.open(dest, FileAccess.READ_WRITE if range_start > 0 and FileAccess.file_exists(dest) else FileAccess.WRITE)
		f.seek_end()
		f.store_buffer(body)
		f.close()
		if stop >= 0:
			return DotResult.fail(DotError.CODE_NETWORK, "connection reset")
		return DotResult.success({"status": 206 if range_start > 0 else 200, "size": body.size(), "resumed": range_start > 0})


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-user-avatar fetch self-test")
	await _test_fetch()
	await _test_failures()
	await _test_gate()
	await _test_ids()
	await _test_actions_read()
	await _test_mirrors_resume()
	await _test_caps()
	_check(_completed == _entered and _entered == SECTIONS, "every section ran (%d of %d)" % [_completed, SECTIONS])
	_check(_passed + _failed + 1 == CHECKS, "every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS])
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print(title)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		print("  FAIL  %s %s" % [what, detail])


func _glb() -> PackedByteArray:
	var root := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	root.add_child(mesh)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(root, state)
	var buf := doc.generate_buffer(state)
	root.free()
	return buf


func _row(kind: String, id: int, bytes: PackedByteArray) -> Dictionary:
	return {"id": id, "contentId": "%s/%d/1" % [kind, id], "size": bytes.size(),
		"sha256": DotHash.sha256_bytes(bytes), "url": "https://site.test/f/%s/%d.glb" % [kind, id]}


## Builds a fake with an avatar 5 and an action 7 listed, plus a built-in action with no file.
func _fixture() -> Array:
	var glb := _glb()
	var http := FakeHttp.new()
	add_child(http)
	var avatar := _row("avatar", 5, glb)
	var action := _row("action", 7, glb)
	http.library = {"avatars": [avatar], "actions": [action, {"id": 1, "builtin": "wave", "contentId": null, "url": null}]}
	http.files = {avatar["url"]: glb, action["url"]: glb}
	var fetcher := DotAvatarContentFetcher.new()
	fetcher.http = http
	fetcher.cache.directory = "user://test_avatar_fetch"
	DotPaths.remove_tree(fetcher.cache.directory)
	return [fetcher, http, avatar, action, glb]


func _cleanup(fx: Array) -> void:
	DotPaths.remove_tree((fx[0] as DotAvatarContentFetcher).cache.directory)
	(fx[1] as Node).free()


func _test_fetch() -> void:
	_section("fetch required files")
	var fx := _fixture()
	var fetcher: DotAvatarContentFetcher = fx[0]
	var http: FakeHttp = fx[1]
	var res: DotResult = await fetcher.prepare("https://site.test/", 3, ["avatar/5/1", "action/7/1", "avatar/5/1"])
	_check(res.ok and res.value == 2, "both files are downloaded once (duplicate id ignored)")
	_check(http.requests[0] == "https://site.test/api/avatar/v1/library?server=3", "the library of the server is read first")
	_check(fetcher.cache.has(fx[2]) and fetcher.cache.has(fx[3]), "both are kept verified")
	var loaded := fetcher.cache.load_scene("avatar/5/1")
	_check(loaded.ok, "and load as scenes")
	if loaded.ok:
		(loaded.value as Node).free()
	http.requests.clear()
	res = await fetcher.prepare("https://site.test", 3, ["avatar/5/1"])
	_check(res.ok and res.value == 0, "a second join downloads nothing")
	_check(http.requests.size() == 1, "beyond the library read")
	res = await fetcher.prepare("https://site.test", 3, [])
	_check(res.ok and res.value == 0 and http.requests.size() == 1, "a server requiring nothing makes no request")
	_check(DotAvatarContentFetcher.index_library("junk").is_empty(), "a malformed library indexes to nothing")
	_check(DotAvatarContentFetcher.index_library(http.library).size() == 2, "built-in actions without a file are not indexed")
	_cleanup(fx)
	_completed += 1


func _test_failures() -> void:
	_section("failures never succeed")
	var fx := _fixture()
	var fetcher: DotAvatarContentFetcher = fx[0]
	var http: FakeHttp = fx[1]
	var errors: Array = []
	fetcher.failed.connect(func(e: DotError) -> void: errors.append(e))

	var res: DotResult = await fetcher.prepare("https://site.test", 3, ["avatar/99/1"])
	_check(not res.ok and res.error.message.contains("avatar/99/1"), "an id the library lacks is named and refused")
	_check(not fetcher.cache.has({"contentId": "avatar/99/1", "size": 1}), "nothing kept")

	http.files.erase(fx[2]["url"])
	res = await fetcher.prepare("https://site.test", 3, ["avatar/5/1"])
	_check(not res.ok, "a 404 on a file fails")

	http.files[fx[2]["url"]] = "glTFxxxxxxxx".to_utf8_buffer()
	res = await fetcher.prepare("https://site.test", 3, ["avatar/5/1"])
	_check(not res.ok and res.error.code == DotError.CODE_INTEGRITY, "wrong bytes fail the size and hash check")
	_check(not fetcher.cache.has(fx[2]), "and are not kept")

	http.library_fails = true
	res = await fetcher.prepare("https://site.test", 3, ["avatar/5/1"])
	_check(not res.ok, "an unreachable library fails")

	res = await fetcher.prepare("https://site.test", 3, ["../etc/passwd"])
	_check(not res.ok and res.error.code == DotError.CODE_INVALID, "a malformed advertised id is refused")
	var many := []
	for i in 65:
		many.append("avatar/%d/1" % (i + 1))
	res = await fetcher.prepare("https://site.test", 3, many)
	_check(not res.ok, "more than the cap of ids is refused")
	_check(errors.size() == 6, "each failure emitted failed", str(errors.size()))

	var bad_url: Dictionary = fx[2].duplicate()
	bad_url["url"] = "file:///etc/passwd"
	res = await fetcher.fetch_rows([bad_url])
	_check(not res.ok, "a non-http url is refused")
	var huge: Dictionary = fx[2].duplicate()
	huge["size"] = DotAvatarContentCache.MAX_BYTES + 1
	res = await fetcher.fetch_rows([huge])
	_check(not res.ok, "an oversize row is refused before any download")
	_cleanup(fx)
	_completed += 1


func _test_gate() -> void:
	_section("the load gate")
	var fx := _fixture()
	var fetcher: DotAvatarContentFetcher = fx[0]
	var http: FakeHttp = fx[1]
	var gate := DotLoadGate.new()
	gate.warm_up_on_open = false
	add_child(gate)
	fetcher.gate = gate
	var res: DotResult = await fetcher.prepare("https://site.test", 3, ["avatar/5/1"])
	_check(res.ok and not gate.is_holding(DotAvatarContentFetcher.REASON), "success releases the hold")

	http.files.clear()
	DotPaths.remove_tree(fetcher.cache.directory)
	res = await fetcher.prepare("https://site.test", 3, ["avatar/5/1"])
	_check(not res.ok and gate.is_holding(DotAvatarContentFetcher.REASON), "failure keeps the gate held")
	_check(gate.status_text().contains("Could not load avatars"), "and says why", gate.status_text())
	_check(not gate.is_open(), "so the game never opens half-loaded")
	gate.free()
	_cleanup(fx)
	_completed += 1


func _test_ids() -> void:
	_section("content ids and paths")
	var cache := DotAvatarContentCache.new()
	_check(DotAvatarContentFetcher.rows_for({}, ["avatar/1/1"])[0] == {"contentId": "avatar/1/1"}, "an unlisted id becomes a url-less row")
	_check(cache.path_for("avatar/1/2") != cache.path_for("avatar/1/3"), "versions are different paths, never replaced in place")
	_check(DotAvatarContentFetcher.MAX_REQUIRED == 64, "the cap is 64")
	_completed += 1


func _test_actions_read() -> void:
	_section("the member's equipped actions")
	var http := FakeHttp.new()
	add_child(http)
	http.library = {"avatar": {}, "actions": {"EMOTE": [{"kind": "EMOTE", "name": "Wave", "builtin": "wave"}]}}
	var res: DotResult = await DotAvatarSync.fetch_actions(http, "player_key_01")
	_check(res.ok and res.value is Dictionary and (res.value as Dictionary).has("EMOTE"), "the read's actions come back as given")
	http.library = {"avatar": {}}
	res = await DotAvatarSync.fetch_actions(http, "player_key_01")
	_check(res.ok and res.value == null, "a backbone without actions gives null (the starter set)")
	res = await DotAvatarSync.fetch_actions(http, "x")
	_check(not res.ok and res.error.code == DotError.CODE_INVALID, "an unusable key is refused")
	http.free()
	_completed += 1


func _test_mirrors_resume() -> void:
	_section("mirrors first, origin last, interrupted files resume")
	var fx := _fixture()
	var fetcher: DotAvatarContentFetcher = fx[0]
	var http: FakeHttp = fx[1]
	var avatar: Dictionary = fx[2]
	var glb: PackedByteArray = fx[4]
	var origin := String(avatar["url"])
	var mirror := origin.replace("https://site.test/", "https://m.test/")
	fetcher.mirror_alternatives_fn = func(url: String) -> PackedStringArray:
		return PackedStringArray([url.replace("https://site.test/", "https://m.test/")])
	http.files[mirror] = glb
	var res: DotResult = await fetcher.fetch_rows([avatar])
	_check(res.ok and http.requests.has(mirror) and not http.requests.has(origin), "a healthy mirror serves the file and the origin is not asked")

	DotPaths.remove_tree(fetcher.cache.directory)
	http.requests.clear()
	var bad := glb.duplicate()
	bad[bad.size() - 1] = bad[bad.size() - 1] ^ 0xFF
	http.files[mirror] = bad
	res = await fetcher.fetch_rows([avatar])
	_check(res.ok and http.requests.has(origin), "a mirror serving bad bytes falls back to the origin")
	_check(fetcher.cache.has(avatar) and FileAccess.get_file_as_bytes(fetcher.cache.path_for("avatar/5/1")) == glb, "and only the origin's bytes are kept")

	fetcher.mirror_alternatives_fn = func(_url: String) -> Array:
		return ["http://plain.test/x", "https://a.test/1", "https://a.test/2", "https://a.test/3", "https://a.test/4", "https://a.test/5"]
	var urls := fetcher.urls_for(origin)
	_check(not urls.has("http://plain.test/x") and urls.size() == DotAvatarContentFetcher.MAX_MIRRORS_PER_FILE + 1, "plain-http mirrors are dropped and the list is capped", str(urls))
	_check(urls[urls.size() - 1] == origin, "the origin is always last")

	fetcher.mirror_alternatives_fn = Callable()
	DotPaths.remove_tree(fetcher.cache.directory)
	http.ranges.clear()
	var half := glb.size() / 2
	http.cut[origin] = half
	res = await fetcher.fetch_rows([avatar])
	var part := "%s/%s.part" % [fetcher.cache.directory, String(avatar["sha256"])]
	_check(not res.ok and DotPaths.file_size(part) == half, "an interrupted download fails and keeps its partial", str(DotPaths.file_size(part)))
	res = await fetcher.fetch_rows([avatar])
	_check(res.ok and http.ranges == [0, half], "the next attempt resumes where it stopped", str(http.ranges))
	_check(fetcher.cache.has(avatar) and not FileAccess.file_exists(part), "the joined file verifies and the partial is gone")

	DotPaths.remove_tree(fetcher.cache.directory)
	fetcher.resume = false
	http.requests.clear()
	res = await fetcher.fetch_rows([avatar])
	_check(res.ok and fetcher.cache.has(avatar), "resume off still downloads in one request")
	_cleanup(fx)
	_completed += 1


func _test_caps() -> void:
	_section("downloads are capped at the declared size")
	var fx := _fixture()
	var fetcher: DotAvatarContentFetcher = fx[0]
	var http: FakeHttp = fx[1]
	var avatar: Dictionary = fx[2]
	var size := int(avatar["size"])
	var origin := String(avatar["url"])
	var mirror := origin.replace("https://site.test/", "https://m.test/")
	fetcher.mirror_alternatives_fn = func(url: String) -> PackedStringArray:
		return PackedStringArray([url.replace("https://site.test/", "https://m.test/")])
	var flood := PackedByteArray()
	flood.resize(size * 3)
	flood.fill(0xAA)
	http.files[mirror] = flood
	var res: DotResult = await fetcher.fetch_rows([avatar])
	_check(res.ok and http.caps[0] == size and fetcher.cache.has(avatar),
		"a mirror streaming past the declared size is cut off at it and the origin serves the file", str(http.caps))

	DotPaths.remove_tree(fetcher.cache.directory)
	fetcher.mirror_alternatives_fn = Callable()
	http.short[origin] = true
	res = await fetcher.fetch_rows([avatar])
	var part := "%s/%s.part" % [fetcher.cache.directory, String(avatar["sha256"])]
	_check(not res.ok and res.error.code == DotError.CODE_INTEGRITY and not FileAccess.file_exists(part),
		"a download that ends short of the declared size is refused before it is read")

	http.short.clear()
	http.caps.clear()
	fetcher.resume = false
	fetcher.mirror_alternatives_fn = func(url: String) -> PackedStringArray:
		return PackedStringArray([url.replace("https://site.test/", "https://m.test/")])
	res = await fetcher.fetch_rows([avatar])
	_check(res.ok and http.caps == [size, size], "an in-memory download is capped the same way", str(http.caps))
	_cleanup(fx)
	_completed += 1
