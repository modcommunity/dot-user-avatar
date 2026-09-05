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

const CHANNEL := "avatar.catalogue"

## Registry name dot-cloud publishes itself under.
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

## Parts asked for whose content has not arrived. Watched by a loading indicator.
var _pending: Dictionary = {}


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
		_pending[part.id] = true

	return path


func _resolve_uncached(part: DotAvatarPart) -> String:
	if resolver.is_valid():
		var custom: Variant = resolver.call(part)
		return str(custom) if custom != null else ""

	if part.content_id == "":
		var builtin := "%s%s%s" % [builtin_prefix, part.id, builtin_suffix]
		return builtin if ResourceLoader.exists(builtin) else ""

	var cloud := _cloud_client()

	if cloud == null:
		# No dot-cloud installed. A part naming content is then simply unavailable,
		# which is correct: the game did not ship it and nothing can fetch it.
		return ""

	if cloud.has_method("resolve"):
		var resolved: Variant = cloud.call("resolve", part.content_id)
		var path := str(resolved) if resolved != null else ""
		return path if path != "" and ResourceLoader.exists(path) else ""

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


func describe() -> Dictionary:
	return {
		"cached": _cache.size(),
		"pending": _pending.size(),
		"cloud": _cloud_client() != null,
		"builtin_prefix": builtin_prefix,
	}
