class_name DotAvatarCatalogue
extends RefCounted

## Turns a part id into something a client can render, through dot-cloud (signed manifests, content hashes).
## Duck-typed, never imported: anything with [code]resolve(content_id)[/code] or [code]has(content_id)[/code]
## found under [code]dot_cloud_client[/code] works; absent it, built-in paths are used.

## Emitted when content a part was waiting on has arrived and the part now resolves.
## Resolving is synchronous (it happens while dressing a character), so a miss can only say "not yet";
## a renderer connects this to re-dress whoever wears the part.
signal part_ready(part_id: StringName)

## Fetch content on a resolve miss, rather than only resolving what is already mounted.
## On because a miss otherwise resolved to "" forever and every wearer silently fell back to a stock part.
## Turn off for a game that drives its own fetching.
var auto_fetch: bool = true

const CHANNEL := "avatar.catalogue"

## Registry name dot-cloud publishes itself under.
## Kept for [method describe]; fetching goes through [DotContent], the family's one caller for downloadable content.
const CLOUD_SERVICE := &"dot_cloud_client"

## Where built-in parts live when a part names no content id; the id is appended
## ([code]hair_long[/code] -> [code]res://avatars/hair_long.tscn[/code]).
## A different layout sets [member resolver] instead of renaming files.
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
## The part, not a marker, because arrival has to re-resolve it and an id alone cannot be.
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
## "" is normal, not a failure: use the fallback and retry later, never leave the player invisible.
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

	# Ask for it. The fetch is not awaited: resolving happens mid-draw and must answer now,
	# so the answer is "not yet" and [signal part_ready] is how "yet" arrives.
	if auto_fetch:
		_fetch(part)

	return ""


## The part actually used for a slot, walking the fallback chain.
## The chain is bounded: parts naming each other as fallbacks is an authoring mistake that would otherwise hang the renderer.
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
## The mount is usually a directory and the answer must be a file, so a bare prefix is not accepted as-is
## (it would re-fetch every draw); the part's own scene under it is tried first, matching [member builtin_prefix].
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
## Never awaited by the caller; idempotent, and [member _fetching] stops a part asked for every frame fetching every frame.
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
		# Warn once and carry on: every wearer is already drawing a fallback. The error code and message
		# live on `res.error`, not `res`; reading `res.message` aborted this detached coroutine
		# while the suite still exited 0, so read stderr.
		DotLog.warn(CHANNEL, "could not fetch avatar content", {
			"content": String(content),
			"code": res.error.code if res.error != null else "",
			"message": res.error.message if res.error != null else "",
		})
		return

	_content_arrived(content)


## Re-resolve every pending part that was waiting on [param content], and announce the ones that now resolve.
## Only the misses are dropped, not the whole cache ([method invalidate]), so other characters do not re-resolve for nothing.
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
## The batched half of [member auto_fetch], for a loading screen. Returns how many parts became resolvable.
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

	# By text: sort() orders StringNames by interning, which differs per process.
	out.sort_custom(func(x: StringName, y: StringName) -> bool: return String(x) < String(y))
	return out


func is_pending(part_id: StringName) -> bool:
	return _pending.has(part_id)


## Drops resolutions. Call after mounting or releasing content.
## A pack can never be unmounted, but a path that did not resolve may start to, and without this a miss would pin a player to their fallback.
func invalidate() -> void:
	_cache.clear()
	_pending.clear()
	_cloud_checked = false
	# Not the in-flight set: a running fetch finishes against an empty _pending (resolves nothing, correct);
	# clearing it here would let the next resolve start a second fetch for content already on its way.


func describe() -> Dictionary:
	return {
		"cached": _cache.size(),
		"pending": _pending.size(),
		"cloud": _cloud_client() != null,
		"builtin_prefix": builtin_prefix,
	}
