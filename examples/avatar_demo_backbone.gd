extends RefCounted

## The backbone protocol, catalogue delivery, digest and transport sections of avatar_demo.
## Counting stays in the host, so every check lands in the one total.

var h: Node = null


func _init(host: Node) -> void:
	h = host


class FakeBackboneHttp extends DotHttp:
	## user_key -> the stored DotAvatar.to_dict().
	var avatars: Dictionary = {}

	## Every path this was asked for, in order. The assertions read it.
	var seen: Array[String] = []

	## Set to serve a 500, for the failure path.
	var fail_next: bool = false

	## Keys the site answers with its default document and `saved: false`: a member
	## who has never opened the editor.
	var unsaved: Array[String] = []

	func request(
		method: int,
		path: String,
		body: PackedByteArray = PackedByteArray(),
		_headers: Dictionary = {},
		_decode_text: bool = true
	) -> DotResult:
		seen.append("%d %s" % [method, path])

		# The real client's HTTPRequest refuses outside the tree, so this does too. A
		# fake that answered from anywhere is how the store shipped an orphan client
		# that never sent a single request.
		if not is_inside_tree():
			return DotResult.fail(
				DotError.CODE_IO,
				"starting request failed. (engine error 3 (Unconfigured))"
			)

		if fail_next:
			fail_next = false
			return DotResult.failure(DotError.from_http(500, "boom"))

				# The protocol's one address; anything else is a client bug, answered as a real backbone would.
		var parts := path.split("/", false)

		if parts.size() != 3 or parts[0] != "user" or parts[2] != "avatar":
			return DotResult.failure(DotError.from_http(404, "no such route"))

		var key := parts[1].uri_decode()

		match method:
			HTTPClient.METHOD_GET:
				if unsaved.has(key):
					return _json({"avatar": {"schema_id": "builtin", "version": 2,
						"parts": {"top": "skin-a"}}, "saved": false})

				if not avatars.has(key):
					return DotResult.failure(DotError.from_http(404, "no avatar"))

				return _json({"avatar": avatars[key], "digest": _digest_of(key)})

			HTTPClient.METHOD_PUT:
				var parsed: Variant = JSON.parse_string(
					body.get_string_from_utf8()
				)

				if not (parsed is Dictionary):
					return DotResult.failure(DotError.from_http(400, "not json"))

				avatars[key] = parsed
				return _json({"avatar": parsed, "digest": _digest_of(key)})

			HTTPClient.METHOD_DELETE:
				if not avatars.has(key):
					return DotResult.failure(DotError.from_http(404, "no avatar"))

				avatars.erase(key)
				return _json({"ok": true})

		return DotResult.failure(DotError.from_http(405, "method not allowed"))

	func _digest_of(key: String) -> String:
		var rebuilt := DotAvatar.from_dict(avatars[key])
		return (rebuilt.value as DotAvatar).digest() if rebuilt.ok else ""

		## A success in the shape [method DotHttp.request] returns, not just bytes:
		## get_json and put_json hand this to the REAL `_parse_json`, which reads `body_text` off a dictionary.
	static func _json(value: Variant) -> DotResult:
		var text := JSON.stringify(value)

		return DotResult.success({
			"status": 200,
			"headers": {"content-type": "application/json"},
			"body": text.to_utf8_buffer(),
			"body_text": text,
		})


func _fake_backbone_store() -> DotAvatarStoreBackbone:
	var store := DotAvatarStoreBackbone.at(
		"https://backbone.test/api/integration/v1", "test-token"
	)
	store.http = FakeBackboneHttp.new()
	return store


## The parts of the protocol the shared store contract cannot see.
func _test_backbone_protocol() -> void:
	h._section("backbone protocol")

	var store := _fake_backbone_store()
	var http := store.http as FakeBackboneHttp
	var key: String = h._key("backbone-protocol")

	var opened: DotResult = await store.open()

	# The site's answer for a member who never saved one is a document, not a 404.
	http.unsaved.append("Unsaved_member_key01")
	var unsaved: DotResult = await store.fetch("Unsaved_member_key01")
	h._check(
		unsaved.ok and unsaved.value == null,
		"a member who never saved an avatar has none, not the site's default"
	)
	h._check(opened.ok, "opens against a configured backbone")

	var missing: DotResult = await store.fetch(key)
	h._check(
		missing.ok and missing.value == null,
		"a 404 means the player has no avatar yet, not a failure"
	)

	var a: DotAvatar = h._wearable()
	var stored: DotResult = await store.store(key, a)
	h._check(stored.ok, "an avatar publishes")

	h._check(
		http.seen.has("%d /user/%s/avatar" % [HTTPClient.METHOD_PUT, key]),
		"to PUT /user/{key}/avatar, the documented address"
	)

	var read: DotResult = await store.fetch(key)
	h._check(
		read.ok and read.value != null,
		"and reads back through the wrapped payload"
	)

	if read.ok and read.value != null:
		h._check(
			(read.value as DotAvatar).digest() == a.digest(),
			"with the digest both sides compute independently"
		)

		# A backbone whose digest disagrees breaks every client's cache invalidation, so the store warns;
		# here we assert only that the publish still succeeds, as the write did happen.
	http.fail_next = true
	var failed: DotResult = await store.store(key, a)
	h._check(not failed.ok, "a backbone error is reported rather than swallowed")

	var removed: DotResult = await store.remove(key)
	h._check(removed.ok, "an avatar erases")
	h._check(
		http.seen.has("%d /user/%s/avatar" % [HTTPClient.METHOD_DELETE, key]),
		"through DELETE on the same address"
	)

	var gone: DotResult = await store.fetch(key)
	h._check(gone.ok and gone.value == null, "and is then absent")

	var read_only: DotAvatarStoreBackbone = await _protocol_refusals(key, a)

	store.close()

	# Supplied clients, so closing left them to us — and an otherwise-clean run that
	# prints "ObjectDB instances leaked" is a run people stop reading the end of.
	(store.http as Node).free()
	(read_only.http as Node).free()
	h._done()


## A read-only store and a store with no credential both refuse; returns the read-only one, which the caller frees.
func _protocol_refusals(key: String, a: DotAvatar) -> DotAvatarStoreBackbone:
	var read_only := _fake_backbone_store()
	read_only.read_only = true
	await read_only.open()

	var refused: DotResult = await read_only.store(key, a)
	h._check(
		not refused.ok,
		"a read-only backbone store refuses publishes rather than dropping them"
	)

	var no_token := DotAvatarStoreBackbone.at("https://backbone.test", "")
	var unopened: DotResult = await no_token.open()
	h._check(
		not unopened.ok,
		"a backbone store with no credential refuses to open"
	)
	# It refused BEFORE building a client, so there is nothing to free here —
	# asserted rather than assumed, because a store that built one anyway would
	# be holding a transport for a connection it just declined to make.
	h._check(no_token.http == null, "and builds no client for a refused open")
	return read_only


# Delivered content: the catalogue once asked dot-cloud whether a part was mounted and never to fetch it,
# so every such wearer fell back silently. The catalogue test above runs with NO cloud client and cannot see it.


## The duck-typed interface [DotContent] speaks, and nothing else.
## A Node whose `ensure` awaits a frame, so the test drives a real coroutine (`await` on a non-coroutine proves nothing).
class StubCloud extends Node:
	var mounted: Dictionary = {}
	var asked: PackedStringArray = PackedStringArray()
	var refuse: bool = false

		## Where this pretends content lands. `res://examples` exists and has `avatar_demo.tscn`,
		## standing in for a part scene, since the catalogue checks the path with `ResourceLoader.exists`.
	const PREFIX := "res://examples"

	func ensure(
		content_id: StringName,
		_version: String = "",
		_groups: PackedStringArray = PackedStringArray(),
		_manifest_url: String = ""
	) -> DotResult:
		asked.append(String(content_id))
		await get_tree().process_frame

		if refuse:
			return DotResult.fail(DotError.CODE_IO, "the network said no")

		mounted[String(content_id)] = true
		return DotResult.success(PREFIX)

	func resolve(content_id: StringName) -> String:
		return PREFIX if mounted.has(String(content_id)) else ""

	func is_mounted(content_id: StringName, _version: String = "") -> bool:
		return mounted.has(String(content_id))


func _test_catalogue_delivery() -> void:
	h._section("delivered content")

	var cloud := StubCloud.new()
	cloud.name = "StubCloud"
	h.add_child(cloud)
	DotRegistry.register(&"dot_cloud_client", cloud)

	var catalogue := DotAvatarCatalogue.new()

	# `avatar_demo` so that PREFIX + "/" + id + ".tscn" is a file that exists. The part
	# id is doing double duty as a filename, which is exactly what the real catalogue
	# does with `builtin_prefix`.
	var part := DotAvatarPart.make(&"avatar_demo", &"hat")
	part.content_id = "test_pack"

	var arrived: Array[StringName] = []
	catalogue.part_ready.connect(func(id: StringName) -> void: arrived.append(id))

	h._check(
		catalogue.resolve(part) == "",
		"content that is not mounted still resolves to nothing at first"
	)
	h._check(
		catalogue.is_pending(&"avatar_demo"),
		"and is pending while it downloads"
	)

	# Two frames: one for the stub's own await, one for the resolution that follows it.
	await h.get_tree().process_frame
	await h.get_tree().process_frame

	h._check(
		cloud.asked.size() == 1 and cloud.asked[0] == "test_pack",
		"a resolve miss ASKS for the content",
		"asked for %s" % str(cloud.asked)
	)
	h._check(
		arrived.has(&"avatar_demo"),
		"and announces the part when it lands, so a renderer can re-dress"
	)
	h._check(
		catalogue.resolve(part) == "res://examples/avatar_demo.tscn",
		"which then resolves to the scene inside the mount",
		catalogue.resolve(part)
	)
	h._check(
		not catalogue.is_pending(&"avatar_demo"),
		"and is no longer pending"
	)

	# One fetch, not one per resolve. A character is dressed every time it spawns and a
	# part that started a download per call would hammer the content origin.
	catalogue.invalidate()
	catalogue.resolve(part)
	catalogue.resolve(part)
	await h.get_tree().process_frame

	h._check(
		cloud.asked.size() == 1,
		"already-mounted content is not fetched again",
		"asked %d times" % cloud.asked.size()
	)

	await _delivery_failed(cloud)

	DotRegistry.unregister(&"dot_cloud_client")
	cloud.queue_free()
	h._done()


## A fetch that fails leaves the wearer on their fallback rather than stopping.
func _delivery_failed(cloud: StubCloud) -> void:
	# A fetch that fails leaves the wearer on their fallback rather than stopping.
	var catalogue_b := DotAvatarCatalogue.new()
	cloud.refuse = true
	var missing := DotAvatarPart.make(&"nowhere", &"hat")
	missing.content_id = "absent_pack"

	h._check(catalogue_b.resolve(missing) == "", "a part whose content refuses resolves to nothing")

	await h.get_tree().process_frame
	await h.get_tree().process_frame

	h._check(
		catalogue_b.is_pending(&"nowhere"),
		"stays pending after a failed fetch, so a retry is still possible"
	)
	h._check(
		catalogue_b.resolve(missing) == "",
		"and resolving again does not crash"
	)


## The digest, pinned to values the SITE computes, not to another Godot run.
## Self-comparison missed `sort()` ordering StringNames by intern order; the values are website-city's fixtures
## ([code]scripts/verify-avatar-backbone.ts[/code]) plus a dev-site round trip.
func _test_digest_matches_site() -> void:
	h._section("digest matches the site")

	var cases := [
		[{"version": 1, "schema_id": "builtin", "parts": {}, "colours": {}}, "f4d2dc7590ed92bd"],
		[
			{
				"version": 1, "schema_id": "builtin",
				"parts": {"hair": "hair.long", "top": "top.jacket"},
				"colours": {"hair": ["2b2118"], "top": ["2b4c7e"]},
			},
			"81ac5b2e0a82a697",
		],
		[
			{
				"version": 1, "schema_id": "builtin",
				"parts": {"face": "face.skin-b", "top": "top.skin-a", "legs": "legs.skin-a"},
				"colours": {},
			},
			"1b719ab816e3f768",
		],
	]

	for case in cases:
		var doc: DotResult = DotAvatar.from_dict(case[0])
		var got := (doc.value as DotAvatar).digest() if doc.ok else "(unreadable)"
		h._check(got == case[1], "site digest %s" % case[1], "got %s" % got)

	# Interned in reverse order on purpose, under names nothing else uses, so their
	# interning order is the opposite of their alphabetical one whatever ran before.
	var stamp := str(Time.get_ticks_usec())
	var reversed := DotAvatar.make(&"order")
	for prefix in ["c", "b", "a"]:
		reversed.set_part(StringName("%s_slot_%s" % [prefix, stamp]), &"part")
	var order := reversed.filled_slots().map(func(n: StringName) -> String: return String(n).left(1))
	h._check(order == ["a", "b", "c"], "slots sort by text, not by when they were interned", str(order))

	h._done()


## The backbone store's HTTP client has to be IN THE TREE to send anything.
## [DotHttp] sends through HTTPRequest children; an orphan client failed every read with engine error 3.
## The fake the rest of the suite uses never noticed, so this drives the REAL [DotHttp] against a closed loopback port ("connection refused" differs from error 3).
func _test_backbone_transport() -> void:
	h._section("backbone store transport")

	var store := DotAvatarStoreBackbone.at("http://127.0.0.1:9", "tmci_test")
	store.read_only = true
	store.timeout_sec = 3.0
	var opened: DotResult = await store.open()
	h._check(opened.ok, "a loopback URL with a token opens")
	h._check(
		store.http != null and store.http.is_inside_tree(),
		"and its HTTP client is in the tree before the first request"
	)

	var res: DotResult = await store.fetch("AbCdEfGhIjKlMnOpQrStUv")
	var why := str(res.error) if res.error != null else ""
	h._check(not res.ok, "an unreachable backbone is a failure, never an absent avatar")
	h._check(
		not why.contains("Unconfigured"),
		"and the request reached the network",
		why.substr(0, 160)
	)

	var client := store.http
	store.close()
	await h.get_tree().process_frame
	h._check(not is_instance_valid(client), "closing frees the client the store built")

	# A client the host supplied (one shared across every backbone call) is the host's.
	var shared := DotHttp.new()
	h.add_child(shared)
	var hosted := DotAvatarStoreBackbone.at("http://127.0.0.1:9", "tmci_test")
	hosted.http = shared
	await hosted.open()
	hosted.close()
	await h.get_tree().process_frame
	h._check(is_instance_valid(shared), "and leaves a supplied client to its owner")
	shared.free()

	# A manager's _ready and its host's setup() both open the store. Two overlapping
	# opens each queued the same client onto the root, and the second add_child was an
	# engine error on every boot of a server using dot-platform.
	var slow := SlowOpenStore.new()
	var results: Array = []
	var opener := func() -> void: results.append(await slow.open())
	opener.call()
	opener.call()
	for _i in 30:
		if results.size() == 2:
			break
		await h.get_tree().process_frame
	h._check(
		results.size() == 2 and slow.attempts == 1 and (results[0] as DotResult).ok
			and (results[1] as DotResult).ok,
		"two overlapping opens share one attempt",
		"%d results, %d attempts" % [results.size(), slow.attempts]
	)

	h._done()


## A store whose open suspends for a frame, as the backbone store's does.
class SlowOpenStore extends DotAvatarStoreMemory:
	var attempts := 0

	func _open() -> DotResult:
		attempts += 1
		await (Engine.get_main_loop() as SceneTree).process_frame
		return DotResult.success(true)
