@tool
class_name DotAvatarPart
extends Resource

## One thing a player can wear or be: a hair style, a jacket, a head shape.
##
## [b]A part is a description, not an asset.[/b] It names a piece of content by id and
## says which slot it fits and how it may be coloured. Nothing here loads a mesh, and
## a dedicated server holds the whole catalogue without holding a single vertex —
## which is the property that makes validating an avatar cheap enough to do on every
## join.
##
## The asset itself is resolved on the client through [DotAvatarCatalogue], which goes
## to dot-cloud, which already verifies signed manifests and content hashes. A
## cosmetic is content like any other and gets the same integrity guarantees.

## Stable identifier. Travels on the wire and is what entitlements key on.
##
## Never reassign one. A part id that changes meaning silently redresses everyone
## wearing it, and an entitlement granted for the old meaning still applies.
@export var id: StringName = &""

## Which slot this occupies. Must exist in the schema.
@export var slot: StringName = &""

## Name shown in the editor UI. Untrusted for nothing; it comes from the schema.
@export var display_name: String = ""

@export_group("Content")

## Content id resolved through dot-cloud. Empty means the part is built into the game.
##
## Kept as a plain string rather than a resource path so a server can carry it without
## the asset existing in its build at all.
@export var content_id: String = ""

## Fallback part used when the content has not arrived yet.
##
## [b)Not optional in practice.[/b] A player whose cosmetic has not downloaded must
## still be visible: an invisible player is a competitive advantage, and "wait for the
## download" is not available when the download is somebody else's hat.
@export var fallback_id: StringName = &""

@export_group("Colour")

## How many independently tintable channels this part has, 0 to 3.
##
## Bounded because the count is part of the wire format and because a part with a
## dozen tintable regions is a material parameter set, not an avatar part.
@export_range(0, 3, 1) var colour_channels: int = 0

@export_group("Availability")

## Everybody has this part without owning it.
##
## The default is [b]false[/b]: a part nobody is entitled to is simply unwearable,
## which is a safe failure. Defaulting to free would make a mis-tagged part wearable
## by everyone, which is not.
@export var free: bool = false

## Hidden from the editor's list but still valid if already worn.
##
## For a retired seasonal item: the player who has it keeps it, and nobody new picks
## it up. Removing the part outright would make their saved avatar invalid.
@export var retired: bool = false

## Free-form tags for a game's own filtering.
@export var tags: PackedStringArray = PackedStringArray()


static func make(
	p_id: StringName,
	p_slot: StringName,
	p_free: bool = false
) -> DotAvatarPart:
	var part := DotAvatarPart.new()
	part.id = p_id
	part.slot = p_slot
	part.free = p_free
	return part


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A part needs an id.")

	if slot == &"":
		return DotResult.fail(
			DotError.CODE_INVALID, "A part needs a slot.", String(id)
		)

	if colour_channels < 0 or colour_channels > 3:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A part may have at most three colour channels.",
			"%s has %d" % [id, colour_channels]
		)

	if fallback_id == id:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A part cannot be its own fallback.",
			String(id)
		)

	return DotResult.success(true)


func describe() -> Dictionary:
	return {
		"id": String(id),
		"slot": String(slot),
		"content": content_id if content_id != "" else "<built in>",
		"channels": colour_channels,
		"free": free,
		"retired": retired,
	}


func _to_string() -> String:
	return "DotAvatarPart(%s in %s)" % [id, slot]
