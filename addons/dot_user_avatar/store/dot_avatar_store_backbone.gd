class_name DotAvatarStoreBackbone
extends DotAvatarStore

## Avatars over the open HTTP protocol, so they follow a player between servers.
## GET, PUT, DELETE on [code]/user/{key}/avatar[/code], no opinion about storage; spec in [code]docs/api/avatar-protocol.md[/code] on the backbone.
## The server token is scoped to connected players' avatars and works nowhere else, as in [DotUserStoreBackbone]. Wire is [method DotAvatar.to_dict] JSON, since [DotAvatarSync.write] indices need both ends to share a schema.

const BACKBONE_CHANNEL := "avatar.store.backbone"

## Where the backbone lives. Required.
var base_url: String = ""

## Token identifying this server to the backbone. Not a player credential.
## Never logged or sent to a client, and refused from environment and argv by [method DotAvatarConfig.sensitive_keys].
var server_token: String = ""

## HTTP client. One is built if none is supplied.
## A parameter so a host can share one client, retry policy and pool across backbone calls.
var http: DotHttp = null

## Whether writes are permitted. A read-only mirror is a legitimate deployment.
## The default matches [member DotAvatarConfig.read_only], not stricter: a store stricter than its configuration is a setting that does nothing.
var read_only: bool = false

## Seconds a request may take before it is abandoned.
## Short, because this is on the join path: admit with a default avatar rather than hold the player.
var timeout_sec: float = 8.0

## Whether [member http] was built (and parented to the root) by this store, so
## [method _close] frees it.
var _owns_http: bool = false


static func at(url: String, token: String) -> DotAvatarStoreBackbone:
	# Not this class's own name. A script that names itself in an expression, loaded after
	# its base, cuts Godot 4.7.2's exit teardown short and leaks every script loaded before
	# it. See docs/gdscript-hazards.md, "A script that names itself".
	var s := new()
	s.base_url = url
	s.server_token = token
	return s


func _store_name() -> String:
	return "DotAvatarStoreBackbone"


func _writable() -> bool:
	return not read_only


func _open() -> DotResult:
	if base_url.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The backbone avatar store needs a base URL.",
			"e.g. https://moddingcommunity.com/api/integration/v1"
		)

	if not (base_url.begins_with("https://") or base_url.begins_with("http://")):
		return DotResult.fail(
			DotError.CODE_INVALID, "The backbone URL needs a scheme.", base_url
		)

		# Plain HTTP sends the server token in the clear and it can read every connected player's avatar.
		# Refusing would break loopback development, so warn, loudly, because the failure is silent and total.
	if base_url.begins_with("http://") and not _is_loopback(base_url):
		DotLog.warn(
			BACKBONE_CHANNEL,
			"the backbone URL is plain HTTP; the server token travels in the clear",
			{"url": base_url}
		)

	if server_token.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_AUTH, "The backbone avatar store needs a server token."
		)

	if http == null:
		http = DotHttp.new()
		http.name = "DotAvatarStoreBackboneHttp"
		_owns_http = true

	http.base_url = base_url
	http.timeout_sec = timeout_sec

		# DotHttp is a Node and sends through HTTPRequest children, which only work in the tree; an orphan
		# client fails every request with engine error 3. Parent to the root, deferred (open() may run inside
		# _ready), then await a frame. Same fix as dot-user's DotUserStoreBackbone.
	if not http.is_inside_tree():
		var tree := Engine.get_main_loop() as SceneTree

		if tree == null:
			return DotResult.fail(
				DotError.CODE_STATE,
				"The backbone avatar store needs a running scene tree for its HTTP client."
			)

		if http.get_parent() == null:
			tree.root.add_child.call_deferred(http)

		await tree.process_frame

	DotLog.debug(
		BACKBONE_CHANNEL,
		"avatar store open",
		{"url": base_url, "read_only": read_only}
	)

	return DotResult.success(true)


func _close() -> void:
	# Only a client this store built: one a caller supplied is the caller's to free.
	if _owns_http and is_instance_valid(http):
		http.queue_free()
		http = null
		_owns_http = false


static func _is_loopback(url: String) -> bool:
	return (
		url.begins_with("http://127.0.0.1")
		or url.begins_with("http://localhost")
		or url.begins_with("http://[::1]")
	)


func _headers() -> Dictionary:
	return {
		"Authorization": "Bearer %s" % server_token,
		"Accept": "application/json",
	}


## Reads a player's avatar.
## Delegates to [method DotAvatarSync.fetch] so the 404-means-no-avatar rule lives in one place.
func _fetch(user_key: String) -> DotResult:
	return await DotAvatarSync.fetch(http, user_key, _headers())


func _store(user_key: String, avatar: DotAvatar) -> DotResult:
		# Replay fields: without a `ts` a backbone cannot bound how long a captured publish stays useful.
		# Unix SECONDS, as milliseconds are refused by the window check.
	var res: DotResult = await DotAvatarSync.publish(
		http,
		user_key,
		avatar,
		_headers(),
		{
			"ts": int(Time.get_unix_time_from_system()),
			"nonce": DotHash.random_hex(16),
		}
	)

	if not res.ok:
		return res

		# The backbone's digest: a mismatch means the sides canonicalise differently, so every client would
		# re-fetch every avatar on every join with no error. Warn, not fail: the write DID happen.
	var mine := avatar.digest()

	if res.value is String and res.value != "" and res.value != mine:
		DotLog.warn(
			BACKBONE_CHANNEL,
			"the backbone computed a different digest for this avatar",
			{"ours": mine, "theirs": res.value}
		)

	return DotResult.success(true)


func _remove(user_key: String) -> DotResult:
	var res: DotResult = await http.request(
		HTTPClient.METHOD_DELETE,
		"/user/%s/avatar" % user_key.uri_encode(),
		PackedByteArray(),
		_headers()
	)

	if not res.ok:
		# Already gone is the outcome the caller asked for.
		if res.error != null and res.error.http_status == 404:
			return DotResult.success(true)

		return res.wrap("Could not erase the avatar.")

	return DotResult.success(true)


func describe() -> Dictionary:
	var out := super.describe()
	out["base_url"] = base_url
	out["read_only"] = read_only
	# Deliberately reports presence, never the value.
	out["has_token"] = server_token != ""
	return out
