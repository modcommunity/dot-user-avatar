@tool
class_name DotAvatarSlot
extends Resource

## A position on the body that one part occupies: head, hair, torso, legs.
## Slots are the schema's structure and parts its contents; each game defines its own set.

## Stable identifier. Travels on the wire as an index into the schema's slot list.
@export var id: StringName = &""

@export var display_name: String = ""

## A player must have something in this slot.
## A document with no torso is a player who cannot be seen; a missing required slot takes [member default_part] so older documents stay loadable.
@export var required: bool = false

## Part used when the slot is empty or holds something unusable.
@export var default_part: StringName = &""

## Slots this one hides when filled. For a helmet that replaces hair.
## Resolved at build time: hiding is a rendering decision a server cannot make without the meshes.
@export var hides: Array[StringName] = []

## Order slots are applied in. Lower first.
## Matters when parts share a mesh or material (skin, clothing, accessories); by slot so it stays stable as parts change.
@export_range(0, 100, 1) var layer: int = 50

## Node name under the rig this slot attaches to. Empty means [member id].
## Not a [DotNodeRef]: a slot is a name looked up under whatever rig the builder is given, and a match has many rigs.
@export var attach_to: StringName = &""


static func make(
	p_id: StringName,
	p_required: bool = false,
	p_default: StringName = &""
) -> DotAvatarSlot:
	var slot := DotAvatarSlot.new()
	slot.id = p_id
	slot.required = p_required
	slot.default_part = p_default
	return slot


func attachment_name() -> StringName:
	return attach_to if attach_to != &"" else id


func validate() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A slot needs an id.")

	if required and default_part == &"":
		# A required slot with no default cannot be repaired, so any document missing it would be refused;
		# that turns a schema change into every saved avatar becoming invalid, so forbid the configuration.
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A required slot needs a default part, or an avatar missing it "
			+ "cannot be repaired.",
			String(id)
		)

	if hides.has(id):
		return DotResult.fail(
			DotError.CODE_INVALID, "A slot cannot hide itself.", String(id)
		)

	return DotResult.success(true)


func describe() -> Dictionary:
	return {
		"id": String(id),
		"required": required,
		"default": String(default_part),
		"layer": layer,
		"hides": Array(hides),
	}


func _to_string() -> String:
	return "DotAvatarSlot(%s)" % id
