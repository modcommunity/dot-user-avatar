class_name DotAvatarEntitlements
extends RefCounted

## What one player is allowed to wear: a set of ids and nothing else.
## Where they came from (purchase, pass, grant) is the game's business; this addon must not care about commerce.
## Default is that a player owns nothing, so a bug in whatever supplies the set cannot silently unlock everything.

## Part ids this player holds.
var owned: Dictionary = {}

## Grant everything. For a creator sandbox, a screenshot build, or an editor preview.
## Never set this from anything a client controls, or there is no entitlement system.
var unrestricted: bool = false


static func none() -> DotAvatarEntitlements:
	return DotAvatarEntitlements.new()


static func of(ids: Array) -> DotAvatarEntitlements:
	var e := DotAvatarEntitlements.new()
	for id in ids:
		e.grant(StringName(str(id)))
	return e


## For an editor preview or a creator sandbox. See [member unrestricted].
static func everything() -> DotAvatarEntitlements:
	var e := DotAvatarEntitlements.new()
	e.unrestricted = true
	return e


func grant(part_id: StringName) -> void:
	owned[part_id] = true


func revoke(part_id: StringName) -> void:
	owned.erase(part_id)


func holds(part_id: StringName) -> bool:
	return unrestricted or owned.has(part_id)


func count() -> int:
	return owned.size()


func to_list() -> Array[StringName]:
	var out: Array[StringName] = []

	for id in owned:
		out.append(StringName(str(id)))

	# By text: sort() orders StringNames by interning, which differs per process.
	out.sort_custom(func(x: StringName, y: StringName) -> bool: return String(x) < String(y))
	return out


func describe() -> Dictionary:
	return {
		"owned": owned.size(),
		"unrestricted": unrestricted,
	}


func _to_string() -> String:
	if unrestricted:
		return "DotAvatarEntitlements(unrestricted)"
	return "DotAvatarEntitlements(%d owned)" % owned.size()
