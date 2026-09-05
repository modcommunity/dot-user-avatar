@tool
class_name DotAvatarSchema
extends Resource

## What parts exist, which slots they fit, and what a legal avatar looks like.
##
## [b]A resource, not a hardcoded enum.[/b] A low-poly shooter and a blocky sandbox
## want entirely different slot sets, and neither should have to fork this addon to
## get one. A game ships its own schema and both its client and its server load the
## same file.
##
## [b]This is the file a dedicated server needs and the meshes are the file it does
## not.[/b] Validating an avatar is: does every slot exist, does every part exist and
## fit its slot, is the player entitled to it, are the colours in range. All four are
## answered from ids. A server that had to load a mesh to check a hat would need every
## cosmetic anyone owns, which is the design this exists to avoid.

const CHANNEL := "avatar.schema"

## Identifier documents refer to. A document naming a different schema is refused.
@export var id: StringName = &""

## Bumped when slots are added or removed. Advisory; documents are repaired, not
## refused, when they no longer match. See [method conform].
@export var version: int = 1

@export var slots: Array[DotAvatarSlot] = []

@export var parts: Array[DotAvatarPart] = []

var _slots_by_id: Dictionary = {}
var _parts_by_id: Dictionary = {}
var _parts_by_slot: Dictionary = {}
var _built: bool = false


func _build() -> void:
	_slots_by_id.clear()
	_parts_by_id.clear()
	_parts_by_slot.clear()

	for slot in slots:
		if slot == null:
			continue
		if _slots_by_id.has(slot.id):
			DotLog.warn(
				CHANNEL, "duplicate slot id; the later one wins",
				{"id": String(slot.id)}
			)
		_slots_by_id[slot.id] = slot
		_parts_by_slot[slot.id] = []

	for part in parts:
		if part == null:
			continue

		if _parts_by_id.has(part.id):
			DotLog.warn(
				CHANNEL, "duplicate part id; the later one wins",
				{"id": String(part.id)}
			)

		_parts_by_id[part.id] = part

		if _parts_by_slot.has(part.slot):
			(_parts_by_slot[part.slot] as Array).append(part)

	_built = true


func invalidate() -> void:
	_built = false


func slot(id: StringName) -> DotAvatarSlot:
	if not _built:
		_build()
	return _slots_by_id.get(id)


func part(id: StringName) -> DotAvatarPart:
	if not _built:
		_build()
	return _parts_by_id.get(id)


## Every part that fits a slot, retired ones included.
func parts_for(slot_id: StringName) -> Array:
	if not _built:
		_build()
	return _parts_by_slot.get(slot_id, [])


## Parts an editor should offer: fits the slot, not retired, and the player has it.
func choices_for(
	slot_id: StringName,
	entitlements: DotAvatarEntitlements
) -> Array[DotAvatarPart]:
	var out: Array[DotAvatarPart] = []

	for candidate in parts_for(slot_id):
		var p := candidate as DotAvatarPart

		if p.retired:
			continue

		if p.free or entitlements == null or entitlements.holds(p.id):
			out.append(p)

	return out


## Slots in the order they should be applied. See [member DotAvatarSlot.layer].
func ordered_slots() -> Array[DotAvatarSlot]:
	if not _built:
		_build()

	var out: Array[DotAvatarSlot] = []
	for s in slots:
		if s != null:
			out.append(s)

	out.sort_custom(func(a: DotAvatarSlot, b: DotAvatarSlot) -> bool:
		if a.layer != b.layer:
			return a.layer < b.layer
		# Ties broken by id so the order is stable across machines. Leaving it to
		# array order makes the result depend on how the resource was edited.
		return String(a.id) < String(b.id)
	)

	return out


# --- Schema validation -----------------------------------------------------

## Checks the schema itself. Call at startup, not per join.
func validate_schema() -> DotResult:
	if id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "A schema needs an id.")

	if slots.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID, "A schema needs at least one slot.", String(id)
		)

	if slots.size() > DotAvatar.MAX_SLOTS:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"A schema may have at most %d slots." % DotAvatar.MAX_SLOTS,
			"%s has %d" % [id, slots.size()]
		)

	if not _built:
		_build()

	for s in slots:
		if s == null:
			return DotResult.fail(
				DotError.CODE_INVALID, "A schema slot is empty.", String(id)
			)

		var checked := s.validate()
		if not checked.ok:
			return checked

		if s.default_part != &"" and not _parts_by_id.has(s.default_part):
			# A default that does not exist means a required slot cannot be repaired,
			# so every document missing it is unusable. Better to fail at startup.
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A slot's default part is not in this schema.",
				"%s wants %s" % [s.id, s.default_part]
			)

		for hidden in s.hides:
			if not _slots_by_id.has(hidden):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"A slot hides a slot that does not exist.",
					"%s hides %s" % [s.id, hidden]
				)

	for p in parts:
		if p == null:
			return DotResult.fail(
				DotError.CODE_INVALID, "A schema part is empty.", String(id)
			)

		var checked_part := p.validate()
		if not checked_part.ok:
			return checked_part

		if not _slots_by_id.has(p.slot):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A part names a slot that does not exist.",
				"%s wants %s" % [p.id, p.slot]
			)

		if p.fallback_id != &"" and not _parts_by_id.has(p.fallback_id):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A part's fallback is not in this schema.",
				"%s wants %s" % [p.id, p.fallback_id]
			)

	return DotResult.success(true)


# --- Document validation ---------------------------------------------------

## Whether a document is legal under this schema and these entitlements.
##
## [b]This is the call a server makes on every join, and it loads nothing.[/b] It
## answers four questions from ids alone: does the slot exist, does the part exist and
## fit, is the player entitled to it, are the colours within the part's channel count.
##
## Pass [param entitlements] as null to skip the ownership check — correct for a
## client previewing its own work, never correct on a server.
func validate(
	avatar: DotAvatar,
	entitlements: DotAvatarEntitlements = null
) -> DotResult:
	if avatar == null:
		return DotResult.fail(DotError.CODE_INVALID, "No avatar.")

	var structural := avatar.validate()
	if not structural.ok:
		return structural

	if avatar.schema_id != id:
		return DotResult.fail(
			DotError.CODE_VERSION,
			"That avatar was made for a different schema.",
			"document says '%s', this is '%s'" % [avatar.schema_id, id]
		)

	if not _built:
		_build()

	for slot_id in avatar.filled_slots():
		var s: DotAvatarSlot = _slots_by_id.get(slot_id)

		if s == null:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"That avatar uses a slot this schema does not have.",
				String(slot_id)
			)

		var part_id := avatar.part_in(slot_id)
		var p: DotAvatarPart = _parts_by_id.get(part_id)

		if p == null:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"That avatar uses a part that does not exist.",
				"%s in %s" % [part_id, slot_id]
			)

		if p.slot != slot_id:
			# A part worn in the wrong slot is how a client gets a mesh to appear
			# somewhere it was never authored for, which at best looks broken and at
			# worst is a way to be much harder to see.
			return DotResult.fail(
				DotError.CODE_INVALID,
				"That part does not go in that slot.",
				"%s belongs in %s, not %s" % [part_id, p.slot, slot_id]
			)

		if entitlements != null and not p.free and not entitlements.holds(part_id):
			return DotResult.fail(
				DotError.CODE_FORBIDDEN,
				"You do not have that item.",
				String(part_id)
			)

		var channels: Array = avatar.colours.get(slot_id, [])

		if channels.size() > p.colour_channels:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"That part does not have that many colours.",
				"%s has %d, document carries %d" % [
					part_id, p.colour_channels, channels.size()
				]
			)

	for s in slots:
		if s != null and s.required and not avatar.has_slot(s.id):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"That avatar is missing a required slot.",
				String(s.id)
			)

	return DotResult.success(true)


## Repairs a document instead of refusing it, and reports what changed.
##
## [b]The difference between a schema change and every saved avatar breaking.[/b]
## Retiring a part, renaming a slot or adding a required one all make existing
## documents invalid, and refusing them means a player who has not logged in for a
## month loads into an error. So a server conforms first and validates after: unknown
## slots and parts are dropped, missing required slots take their default, entitlement
## losses fall back.
##
## Returns the list of changes, so a caller can tell the player what happened rather
## than silently redressing them.
func conform(
	avatar: DotAvatar,
	entitlements: DotAvatarEntitlements = null
) -> DotResult:
	if avatar == null:
		return DotResult.fail(DotError.CODE_INVALID, "No avatar.")

	if not _built:
		_build()

	var changes := PackedStringArray()

	if avatar.schema_id != id:
		# A document for another schema cannot be repaired; nothing in it means
		# anything here. This is the one case conform refuses.
		return DotResult.fail(
			DotError.CODE_VERSION,
			"That avatar was made for a different schema.",
			"document says '%s', this is '%s'" % [avatar.schema_id, id]
		)

	for slot_id in avatar.filled_slots():
		var s: DotAvatarSlot = _slots_by_id.get(slot_id)

		if s == null:
			avatar.clear_slot(slot_id)
			changes.append("dropped unknown slot '%s'" % slot_id)
			continue

		var part_id := avatar.part_in(slot_id)
		var p: DotAvatarPart = _parts_by_id.get(part_id)

		var lost := ""

		if p == null:
			lost = "no longer exists"
		elif p.slot != slot_id:
			lost = "does not belong in this slot"
		elif entitlements != null and not p.free and not entitlements.holds(part_id):
			lost = "is not owned"

		if lost != "":
			avatar.clear_slot(slot_id)
			changes.append("removed '%s' from '%s': it %s" % [part_id, slot_id, lost])
			continue

		# Trim colours the part cannot use. Left in place they would fail validation
		# for a document that is otherwise fine.
		var channels: Array = avatar.colours.get(slot_id, [])

		if channels.size() > p.colour_channels:
			channels.resize(p.colour_channels)
			avatar.colours[slot_id] = channels
			changes.append("trimmed colours on '%s'" % slot_id)

	for s in slots:
		if s == null or not s.required or avatar.has_slot(s.id):
			continue

		if s.default_part == &"":
			# validate_schema forbids this, so reaching it means the schema was not
			# validated at startup. Saying so beats producing an avatar that then
			# fails validation for a reason that points at the player.
			return DotResult.fail(
				DotError.CODE_INTERNAL,
				"A required slot has no default; this schema was never validated.",
				String(s.id)
			)

		avatar.set_part(s.id, s.default_part)
		changes.append("filled required slot '%s' with its default" % s.id)

	return DotResult.success(changes)


## A legal avatar with every required slot filled by its default.
func default_avatar() -> DotAvatar:
	var a := DotAvatar.make(id)

	for s in slots:
		if s != null and s.required and s.default_part != &"":
			a.set_part(s.id, s.default_part)

	return a


func describe() -> Dictionary:
	if not _built:
		_build()

	return {
		"id": String(id),
		"version": version,
		"slots": slots.size(),
		"parts": parts.size(),
		"required": ordered_slots().filter(
			func(s: DotAvatarSlot) -> bool: return s.required
		).size(),
	}


func _to_string() -> String:
	return "DotAvatarSchema(%s v%d)" % [id, version]
