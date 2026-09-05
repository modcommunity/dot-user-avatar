@tool
class_name DotAvatarSlot
extends Resource

## A position on the body that one part occupies: head, hair, torso, legs.
##
## Slots are the schema's structure and parts are its contents. A game defines its
## own — a blocky sandbox and a stylised shooter want entirely different sets and
## neither should have to fork this addon to get one.

## Stable identifier. Travels on the wire as an index into the schema's slot list.
@export var id: StringName = &""

@export var display_name: String = ""

## A player must have something in this slot.
##
## [b]Required slots are what stops an avatar being a way to be invisible.[/b] A
## document with no torso is not a stylistic choice; it is a player who cannot be
## seen. The schema fills a missing required slot with [member default_part] rather
## than refusing, so an older document stays loadable.
@export var required: bool = false

## Part used when the slot is empty or holds something unusable.
@export var default_part: StringName = &""

## Slots this one hides when filled. For a helmet that replaces hair.
##
## Resolved at build time, not at validation time: whether a hat hides hair is a
## rendering decision, and a server that enforced it would need to know what the
## meshes look like.
@export var hides: Array[StringName] = []

## Order slots are applied in. Lower first.
##
## Matters when parts share a mesh or a material: skin before clothing, clothing
## before accessories. Ordering by slot rather than by part keeps it stable when a
## player changes what they are wearing.
@export_range(0, 100, 1) var layer: int = 50

## Node name under the rig this slot attaches to. Empty means [member id].
##
## A [DotNodeRef] would be the family default, but a slot is not one node in one
## scene — it is a name looked up under whatever rig the builder is given, and there
## may be thirty rigs in a match. The lookup is the ref's job here.
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
		# A required slot with no default cannot be repaired, so any document missing
		# it has to be refused outright. That turns a schema change into every saved
		# avatar becoming invalid, which is a bad enough outcome to forbid the
		# configuration that causes it.
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
