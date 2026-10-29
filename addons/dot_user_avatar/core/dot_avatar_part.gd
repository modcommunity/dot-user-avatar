@tool
class_name DotAvatarPart
extends Resource

## One thing a player can wear or be: a hair style, a jacket, a head shape.
## A description, not an asset: it names content by id, so a dedicated server holds the whole catalogue without a vertex.
## The asset is resolved on the client through [DotAvatarCatalogue] and dot-cloud.

## Stable identifier. Travels on the wire and is what entitlements key on.
## Never reassign one: a changed meaning silently redresses everyone wearing it.
@export var id: StringName = &""

## Which slot this occupies. Must exist in the schema.
@export var slot: StringName = &""

## Name shown in the editor UI. Untrusted for nothing; it comes from the schema.
@export var display_name: String = ""

@export_group("Content")

## Content id resolved through dot-cloud. Empty means the part is built into the game.
## A plain string, not a resource path, so a server can carry it without the asset in its build.
@export var content_id: String = ""

## Fallback part used when the content has not arrived yet.
## Not optional in practice: an invisible player is a competitive advantage, and nobody waits on someone else's hat.
@export var fallback_id: StringName = &""

@export_group("Colour")

## How many independently tintable channels this part has, 0 to 3.
## Bounded because the count is part of the wire format.
@export_range(0, 3, 1) var colour_channels: int = 0

@export_group("Availability")

## Everybody has this part without owning it.
## Default [b]false[/b]: an untagged part is unwearable, a safe failure; defaulting to free would let a mis-tagged part be worn by everyone.
@export var free: bool = false

## Hidden from the editor's list but still valid if already worn.
## For a retired seasonal item: removing the part would invalidate saved avatars.
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
