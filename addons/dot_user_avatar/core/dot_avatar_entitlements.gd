class_name DotAvatarEntitlements
extends RefCounted

## What one player is allowed to wear.
##
## [b]Deliberately a set of ids and nothing else.[/b] Where the entitlements came from
## — a purchase, a season pass, a site group, a grant from an admin — is somebody
## else's problem, and encoding any of it here would make this addon care about
## commerce. A game supplies the set; this decides what it permits.
##
## [b]The default is that a player owns nothing.[/b] A part is wearable only if it is
## marked free in the catalogue or is in this set. Defaulting the other way would mean
## a bug in whatever supplies the set silently unlocks everything, and that failure is
## invisible until somebody notices a player wearing something they did not buy.

## Part ids this player holds.
var owned: Dictionary = {}

## Grant everything. For a creator sandbox, a screenshot build, or an editor preview.
##
## [b]Never set this from anything a client controls.[/b] It exists so a developer can
## try things, and a server that honoured a client asking for it would have no
## entitlement system at all.
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

	out.sort()
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
