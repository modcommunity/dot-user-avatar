class_name DotAvatarStoreBackbone
extends DotAvatarStore

## Avatars over the open HTTP protocol, so they follow a player between servers.
##
## [b]The protocol is the product here.[/b] TMC runs an instance and anyone can run
## their own, which is only true if the reference implementation is the thing TMC
## runs and if a self-hoster gets the same functionality rather than a degraded
## version. So this speaks three boring endpoints and has no opinion about storage:
##
## [codeblock]
## GET    /user/{key}/avatar     read a player's avatar
## PUT    /user/{key}/avatar     publish it
## DELETE /user/{key}/avatar     erase it
## [/codeblock]
##
## The full specification, including the schema endpoint a client fetches at startup
## and the reason [param user_key] is a scoped derivation rather than an account id,
## is published at [code]docs/api/avatar-protocol.md[/code] on the backbone.
##
## [b]What this must never do is hold a credential that works anywhere else.[/b] A
## game server running this holds a server token scoped to reading and writing
## avatars for players connected to it, and nothing more. The moment a server can
## present a player's own account token, every operator has a live credential for
## every player's whole account — which is the exact failure dot-auth's ticket flow
## exists to prevent. Same rule, same wording, as [DotUserStoreBackbone]; the two are
## deliberately separate classes because this addon does not depend on dot-user.
##
## [b]The wire format is [method DotAvatar.to_dict], not this addon's packed one.[/b]
## [DotAvatarSync.write] exists for the match, where a document travels to thirty
## peers many times a second and indices into the schema are worth the coupling. A
## backbone is asked once per player per join, JSON is what an HTTP API elsewhere can
## read, and — the deciding reason — index-based encoding requires both ends to hold
## the SAME schema, which a backbone serving several games does not.

const BACKBONE_CHANNEL := "avatar.store.backbone"

## Where the backbone lives. Required.
var base_url: String = ""

## Token identifying this server to the backbone.
##
## [b]Not a player credential.[/b] See the class documentation. Never logged, never
## sent to a client, and refused from the environment and argv by
## [method DotAvatarConfig.sensitive_keys] for the usual reason: both are readable by
## other processes and end up in pasted bug reports.
var server_token: String = ""

## HTTP client. One is built if none is supplied.
##
## A parameter rather than owned outright so a host can share one client, its retry
## policy and its connection pool across every backbone call the process makes.
var http: DotHttp = null

## Whether writes are permitted. A read-only mirror is a legitimate deployment, and
## most servers should read avatars and never publish them — but the default matches
## [member DotAvatarConfig.read_only] rather than being safer than it, because a store
## quietly stricter than the configuration it was built from is a setting that does
## nothing.
var read_only: bool = false

## Seconds a request may take before it is abandoned.
##
## Short, because this is on the join path: a player waiting on a backbone that is
## not answering should be admitted with a default avatar rather than held.
var timeout_sec: float = 8.0


static func at(url: String, token: String) -> DotAvatarStoreBackbone:
	var s := DotAvatarStoreBackbone.new()
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
			"e.g. https://themodcommunity.com/api/integration/v1"
		)

	if not (base_url.begins_with("https://") or base_url.begins_with("http://")):
		return DotResult.fail(
			DotError.CODE_INVALID, "The backbone URL needs a scheme.", base_url
		)

	# Plain HTTP carries the server token in the clear, and that token can read
	# every connected player's avatar. Refusing outright would break local
	# development against a loopback backbone, so it is a warning — but a loud
	# one, because the failure is silent and total.
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

	http.base_url = base_url
	http.timeout_sec = timeout_sec

	DotLog.debug(
		BACKBONE_CHANNEL,
		"avatar store open",
		{"url": base_url, "read_only": read_only}
	)

	return DotResult.success(true)


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
##
## Delegates to [method DotAvatarSync.fetch] rather than repeating the request here,
## so the 404-means-no-avatar rule and the payload unwrapping live in one place and
## a client and a server cannot disagree about them.
func _fetch(user_key: String) -> DotResult:
	return await DotAvatarSync.fetch(http, user_key, _headers())


func _store(user_key: String, avatar: DotAvatar) -> DotResult:
	# The replay fields, which are free to send and close a real gap: without a
	# `ts` a backbone has nothing to bound how long a captured publish stays
	# useful. Unix SECONDS — milliseconds are refused by a window check, which is
	# a mistake worth making impossible here rather than at every call site.
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

	# The backbone answers with the digest it computed. A mismatch means the two
	# sides canonicalise differently, which is not cosmetic: the digest is the
	# entire mechanism by which a client knows its cached copy of another player
	# is stale, so if they disagree every client re-fetches every avatar on every
	# join and nothing anywhere reports an error. Warned rather than failed —
	# the write DID happen, and refusing it afterwards would be a lie.
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
