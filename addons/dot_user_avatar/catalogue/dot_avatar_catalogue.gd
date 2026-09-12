class_name DotAvatarCatalogue
extends RefCounted

## Turns a part id into something a client can actually render.
##
## [b]The client's half of the split.[/b] A server holds the schema and never resolves
## anything; a client holds the schema too and resolves part ids to content through
## dot-cloud, which already verifies signed manifests and content hashes. A cosmetic
## is content like any other and gets the same integrity guarantees as a map.
##
## [b]dot-cloud is not imported.[/b] The client is duck-typed: anything with
## [code]resolve(content_id)[/code] returning a path, or [code]has(content_id)[/code],
## works. Found through [DotRegistry] under [code]dot_cloud_client[/code] when it is
## installed, and absent it falls back to built-in paths — which is what a game that
## ships its cosmetics in the build wants and what every test wants.

## Emitted when content a part was waiting on has arrived and the part now resolves.
##
## [b]Without this, a cosmetic that downloads mid-game is never drawn.[/b] Resolving is
## synchronous because it happens while a character is being dressed, so a miss can only
## answer "not yet" — and something has to say when "yet" arrives. A renderer connects
## this and re-dresses whoever is wearing the part; a loading indicator connects it to
## take the part off its list.
signal part_ready(part_id: StringName)

## Fetch content on a resolve miss, rather than only resolving what is already mounted.
##
## [b]On, because off was the old behaviour and off is invisible.[/b] This catalogue
## asked dot-cloud [i]whether[/i] a part was mounted and never asked it to fetch one, so
## a part naming content nothing had downloaded resolved to "" forever and every wearer
## fell back to a stock part. The fallback is working-as-designed, so nothing errored and
## nothing warned: a developer could publish a cosmetic, wire it correctly, and watch it
## silently never appear. dot-map had the same hole with the ends one step further apart
## and it hid for months. Turn this off for a game that drives its own fetching and wants
## the catalogue to do nothing behind its back.
var auto_fetch: bool = true

const CHANNEL := "avatar.catalogue"

## Registry name dot-cloud publishes itself under.
##
## Kept for [method describe] and for a game that reaches the client directly. The
## fetching itself goes through [DotContent], which is the family's one caller for
## downloadable content and is duck-typed against the same service.
const CLOUD_SERVICE := &"dot_cloud_client"

## Where built-in parts live when a part names no content id.
##
## The id is appended, so [code]hair_long[/code] becomes
## [code]res://avatars/hair_long.tscn[/code]. A game with a different layout sets
## [member resolver] instead of renaming its files.
var builtin_prefix: String = "res://avatars/"

var builtin_suffix: String = ".tscn"

## Overrides everything. Takes a [DotAvatarPart] and returns a path, or "".
##
## The escape hatch for a game whose content layout is nothing like either default.
var resolver: Callable = Callable()

## The dot-cloud client, when one is installed. Resolved lazily.
var _cloud: Object = null
var _cloud_checked: bool = false

## part id -> resolved path. Cleared when content is mounted or released.
var _cache: Dictionary = {}

## Part id -> the [DotAvatarPart], for parts whose content has not arrived.
##
## The PART and not merely a marker, because when its content lands something has to
## re-resolve it, and an id alone cannot be re-resolved. [method pending] returns the
## keys, so it is unchanged by this.
var _pending: Dictionary = {}

## content id -> true while a fetch for it is in flight, so a part that is asked for
## every frame while it downloads starts one fetch rather than one per frame.
var _fetching: Dictionary = {}


func _cloud_client() -> Object:
	if _cloud_checked:
		return _cloud

	_cloud_checked = true
	_cloud = DotRegistry.get_service(CLOUD_SERVICE)

	if _cloud != null:
		DotLog.debug(CHANNEL, "resolving avatar content through dot-cloud")

	return _cloud


## Where a part's scene lives, or "" when it is not available yet.
##
## [b)Returning "" is a normal outcome, not a failure.[/b] A cosmetic somebody else is
## wearing may not have downloaded yet, and the answer then is to use the fallback and
## try again later — never to leave the player invisible.
func resolve(part: DotAvatarPart) -> String:
	if part == null:
		return ""

	if _cache.has(part.id):
		return _cache[part.id]

	var path := _resolve_uncached(part)

	if path != "":
		_cache[part.id] = path
		_pending.erase(part.id)
	else:
		_pending[part.id] = part

	return path


func _resolve_uncached(part: DotAvatarPart) -> String:
	if resolver.is_valid():
		var custom: Variant = resolver.call(part)
		return str(custom) if custom != null else ""

	if part.content_id == "":
		var builtin := "%s%s%s" % [builtin_prefix, part.id, builtin_suffix]
		return builtin if ResourceLoader.exists(builtin) else ""

	# Already downloaded and mounted: the cheap synchronous question, which is the one
	# worth asking while a character is being dressed.
	var mounted := _scene_in(DotContent.resolve(StringName(part.content_id)), part)

	if mounted != "":
		return mounted

	# Not here yet. [b]Ask for it[/b] — this is the line that did not exist, and without
	# it a part naming content that nobody had already mounted was unreachable for the
	# life of the process. The fetch is deliberately not awaited: resolving happens
	# mid-draw and must answer now, so the answer is "not yet" and [signal part_ready]
	# is how "yet" arrives.
	if auto_fetch:
		_fetch(part)

	return ""


## The part actually used for a slot, walking the fallback chain.
##
## [b]The chain is bounded and the bound is not paranoia.[/b] Two parts naming each
## other as fallbacks is a content-authoring mistake that would otherwise hang the
## renderer, and content is authored by people who are not looking at this code.
func resolve_with_fallback(
	part: DotAvatarPart,
	schema: DotAvatarSchema,
	max_depth: int = 4
) -> DotAvatarPart:
	var current := part
	var seen := {}
	var depth := 0

	while current != null and depth < max_depth:
		if resolve(current) != "":
			return current

		seen[current.id] = true

		if current.fallback_id == &"" or seen.has(current.fallback_id):
			break

		current = schema.part(current.fallback_id)
		depth += 1

	# Nothing in the chain is available. The caller shows a placeholder rather than
	# nothing: a player you cannot see is a competitive advantage.
	return null


## Where [param part]'s scene is inside mounted content at [param path], or "".
##
## [b]The mount is usually a DIRECTORY and the answer has to be a FILE.[/b] dot-cloud
## answers with the entry path when a manifest names one and with the mount prefix when
## it does not, so both arrive here — and a prefix is a directory, which
## [method ResourceLoader.exists] says nothing exists at. Accepting the client's answer
## unchanged therefore rejected every pack that did not name an entry, re-fetched it on
## the next resolve, and did that for every draw: found by running the suite, which
## counted two fetches for one part.
##
## The part's own scene under the prefix is tried first, because that is the layout
## [member builtin_prefix] already describes for a build that ships its parts — one
## naming rule whether a part is delivered or not.
func _scene_in(path: String, part: DotAvatarPart) -> String:
	if path == "" or part == null:
		return ""

	var dir := path if path.ends_with("/") else path + "/"
	var candidate := "%s%s%s" % [dir, part.id, builtin_suffix]

	if ResourceLoader.exists(candidate):
		return candidate

	# A manifest that named the entry document itself.
	if ResourceLoader.exists(path):
		return path

	return ""


## Download the content [param part] needs, then re-resolve everything waiting on it.
##
## Started from a resolve miss and never awaited by the caller — see the note there.
## Safe to call repeatedly: [method DotContent.ensure] is idempotent, and [member
## _fetching] keeps a part that is asked for every frame from starting a fetch per frame.
func _fetch(part: DotAvatarPart) -> void:
	if part == null or part.content_id == "":
		return

	var content := StringName(part.content_id)

	if _fetching.has(content):
		return

	# No cloud client at all is the ordinary shape of a build that ships its cosmetics,
	# and a part naming content there is a content mistake rather than a download. Said
	# once at debug by [DotContent] rather than warned per part per frame.
	if not DotContent.available():
		return

	_fetching[content] = true

	var res: DotResult = await DotContent.ensure(content)

	_fetching.erase(content)

	if not res.ok:
		# Warned, not failed. Every wearer is already drawing a fallback, so the game
		# carries on looking slightly wrong rather than stopping — but a cosmetic that
		# cannot be fetched is a thing an operator wants in the log exactly once.
		# `res.error` is the DotError; the message and the code live on IT, not on the
		# result. Reading `res.message` here threw, and the way that surfaced is worth
		# keeping: the throw aborted THIS coroutine only -- it is detached, because a
		# resolve miss starts it without awaiting -- so the suite still printed
		# "151 passed, 0 failed" and exited 0 with a SCRIPT ERROR in its stderr. The
		# line that failed was the one explaining why a download failed, which is the
		# line somebody is reading precisely when everything else has already gone
		# wrong. Read a suite's stderr even when it exits 0.
		DotLog.warn(CHANNEL, "could not fetch avatar content", {
			"content": String(content),
			"code": res.error.code if res.error != null else "",
			"message": res.error.message if res.error != null else "",
		})
		return

	_content_arrived(content)


## Re-resolve every pending part that was waiting on [param content], and announce the
## ones that now resolve.
##
## [b]Only the misses are dropped, not the whole cache.[/b] [method invalidate] clears
## everything and is right after a mount nobody was expecting; here the arrival is known,
## so throwing away resolutions that are still correct would make every other character
## in the scene re-resolve for nothing.
func _content_arrived(content: StringName) -> void:
	var ready: Array[StringName] = []

	for id in _pending.keys():
		var part: DotAvatarPart = _pending[id]

		if part == null or StringName(part.content_id) != content:
			continue

		var path := DotContent.resolve(content)
		var candidate := _scene_in(path, part)

		if candidate == "":
			# Mounted, and the part is not in it. A content mistake rather than a fetch
			# failure, and worth saying so: the two look identical from the outside and
			# only one of them is fixed by retrying.
			DotLog.warn(CHANNEL, "content mounted but the part is not in it", {
				"part": String(id), "content": String(content), "at": path,
			})
			continue

		_cache[id] = candidate
		_pending.erase(id)
		ready.append(StringName(str(id)))

	for id in ready:
		part_ready.emit(id)


## Fetch everything currently pending, and wait for all of it.
##
## The batched half of [member auto_fetch], for a caller that would rather block a
## loading screen once than watch characters change clothes as packs land. Returns how
## many parts became resolvable.
func fetch_pending() -> int:
	var before := _pending.size()

	var wanted: Array[DotAvatarPart] = []

	for id in _pending.keys():
		var part: DotAvatarPart = _pending[id]

		if part != null and part.content_id != "":
			wanted.append(part)

	for part in wanted:
		await _fetch(part)

	return before - _pending.size()


## Part ids whose content has been asked for and has not arrived.
func pending() -> Array[StringName]:
	var out: Array[StringName] = []

	for id in _pending:
		out.append(StringName(str(id)))

	out.sort()
	return out


func is_pending(part_id: StringName) -> bool:
	return _pending.has(part_id)


## Drops resolutions. Call after mounting or releasing content.
##
## Godot can never unmount a resource pack, so a path that resolved once keeps
## resolving — but a path that did [i]not[/i] resolve may start to, and a cache with
## no way to forget a miss would keep a player in their fallback for the rest of the
## session.
func invalidate() -> void:
	_cache.clear()
	_pending.clear()
	_cloud_checked = false
	# Not the in-flight set. A fetch that is still running will finish and call
	# [method _content_arrived] against a _pending that has been emptied, which resolves
	# nothing and emits nothing -- correct. Clearing it here would instead let the next
	# resolve start a SECOND fetch for content already on its way.


func describe() -> Dictionary:
	return {
		"cached": _cache.size(),
		"pending": _pending.size(),
		"cloud": _cloud_client() != null,
		"builtin_prefix": builtin_prefix,
	}
