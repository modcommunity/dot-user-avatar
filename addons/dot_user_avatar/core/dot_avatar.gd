@tool
class_name DotAvatar
extends Resource

## What a player looks like, as data. A few dozen bytes, not a scene.
##
## [b]The document is the whole design.[/b] A server has to decide whether an avatar
## is legal — every part exists, the player is entitled to it, every value is in
## range — and it has to do that on every join, for thirty players, without loading a
## mesh. So the avatar is a schema id, a set of part ids and a set of colours, and
## the parts are named rather than embedded.
##
## [codeblock]
## var avatar := DotAvatar.new()
## avatar.schema_id = &"humanoid"
## avatar.set_part(&"hair", &"hair_long")
## avatar.set_colour(&"hair", 0, Color("6b4423"))
## [/codeblock]
##
## [b]It is relayed to every other player, so it is bounded.[/b] Slot count, id
## lengths and colour count are all capped in [method validate]. An unbounded avatar
## is an amplification vector: one player writes a large document and the server sends
## it to everyone in the match every time somebody joins.
##
## [b]Colours are quantised to 8 bits per channel here, not on the wire.[/b] Doing it
## at the wire would mean the document a client validated and the document a server
## stored differ in their low bits, so a digest computed on one machine would not
## match one computed on the other — and the digest is what tells a client its cached
## copy is stale.

const CHANNEL := "avatar"

## Bumped when the stored shape changes. See [method migrate].
const SCHEMA_VERSION := 1

## Most slots one avatar may fill.
##
## Bounded because the count travels on the wire and because a document with sixty
## slots is a rig, not an avatar.
const MAX_SLOTS := 24

## Longest a slot or part id may be, in characters.
const MAX_ID_LENGTH := 48

## Colour channels one slot may have. Matches [member DotAvatarPart.colour_channels].
const MAX_CHANNELS := 3

## Which schema this document is written against.
@export var schema_id: StringName = &""

## Version of the document format, not of the schema.
@export var version: int = SCHEMA_VERSION

## slot id -> part id.
@export var parts: Dictionary = {}

## slot id -> [Color], one per channel the part declares.
@export var colours: Dictionary = {}


static func make(p_schema_id: StringName) -> DotAvatar:
	var a := DotAvatar.new()
	a.schema_id = p_schema_id
	return a


# --- Reading and writing ---------------------------------------------------

func part_in(slot: StringName) -> StringName:
	var found: Variant = parts.get(slot, &"")
	return found if found is StringName else StringName(str(found))


func has_slot(slot: StringName) -> bool:
	return parts.has(slot) and part_in(slot) != &""


func set_part(slot: StringName, part: StringName) -> void:
	if part == &"":
		parts.erase(slot)
		colours.erase(slot)
		return

	parts[slot] = part


func clear_slot(slot: StringName) -> void:
	parts.erase(slot)
	colours.erase(slot)


func colour_of(slot: StringName, channel: int) -> Color:
	var list: Variant = colours.get(slot, [])

	if not (list is Array) or channel < 0 or channel >= (list as Array).size():
		return Color.WHITE

	return (list as Array)[channel]


## Sets one colour channel, quantised to 8 bits per component.
##
## Quantised here rather than on the wire so a document is byte-identical wherever it
## was built. See the class documentation.
func set_colour(slot: StringName, channel: int, colour: Color) -> DotResult:
	if channel < 0 or channel >= MAX_CHANNELS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A colour channel must be 0 to %d." % (MAX_CHANNELS - 1),
			"got %d" % channel
		)

	var list: Array = colours.get(slot, [])

	while list.size() <= channel:
		list.append(Color.WHITE)

	list[channel] = quantise(colour)
	colours[slot] = list

	return DotResult.success(true)


## Rounds a colour to what the wire format carries: 8 bits per component, no alpha.
##
## Alpha is dropped rather than quantised. A tint with alpha is a transparency
## setting, and a player who could make their avatar transparent would be harder to
## see, which is the same problem as an invisible one.
static func quantise(colour: Color) -> Color:
	return Color(
		roundf(clampf(colour.r, 0.0, 1.0) * 255.0) / 255.0,
		roundf(clampf(colour.g, 0.0, 1.0) * 255.0) / 255.0,
		roundf(clampf(colour.b, 0.0, 1.0) * 255.0) / 255.0,
		1.0
	)


func filled_slots() -> Array[StringName]:
	var out: Array[StringName] = []

	for slot in parts:
		var name := StringName(str(slot))
		if part_in(name) != &"":
			out.append(name)

	# Sorted so two avatars with the same content serialise identically, whatever
	# order they were built in. The digest depends on it.
	out.sort()
	return out


# --- Validation ------------------------------------------------------------

## Structural checks that need no schema: shape, bounds, and nothing else.
##
## [b]Separate from [method DotAvatarSchema.validate] on purpose.[/b] This is the
## check a server can run before it knows which schema a document claims, so a
## malformed document is refused before anything looks a slot up. The schema check is
## the one that decides whether the contents mean anything.
func validate() -> DotResult:
	if schema_id == &"":
		return DotResult.fail(
			DotError.CODE_INVALID, "An avatar must name a schema."
		)

	if String(schema_id).length() > MAX_ID_LENGTH:
		return DotResult.fail(
			DotError.CODE_INVALID, "That schema id is too long."
		)

	if parts.size() > MAX_SLOTS:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"An avatar may fill at most %d slots." % MAX_SLOTS,
			"got %d" % parts.size()
		)

	for slot in parts:
		var slot_name := str(slot)
		var part_name := str(parts[slot])

		if slot_name.length() > MAX_ID_LENGTH:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A slot id is too long.",
				slot_name.substr(0, 64)
			)

		if part_name.length() > MAX_ID_LENGTH:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A part id is too long.",
				part_name.substr(0, 64)
			)

		if not _is_safe_id(slot_name) or not _is_safe_id(part_name):
			# Ids become dictionary keys, log lines and, on the client, part of a
			# content lookup. A control character or a path separator in one is
			# never legitimate and is exactly what an attacker reaches for.
			return DotResult.fail(
				DotError.CODE_INVALID,
				"An id contains characters that are not allowed.",
				"%s / %s" % [slot_name.substr(0, 32), part_name.substr(0, 32)]
			)

	# Colours for a slot that holds nothing are not an error worth refusing over —
	# they are what is left after changing a part — but they must not accumulate.
	if colours.size() > MAX_SLOTS:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"An avatar carries colours for more slots than it can fill."
		)

	for slot in colours:
		var list: Variant = colours[slot]

		if not (list is Array):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"Colours for a slot must be a list.",
				str(slot)
			)

		if (list as Array).size() > MAX_CHANNELS:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A slot may have at most %d colour channels." % MAX_CHANNELS,
				"%s has %d" % [str(slot), (list as Array).size()]
			)

		for entry in (list as Array):
			if not (entry is Color):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"A colour channel is not a colour.",
					str(slot)
				)

	return DotResult.success(true)


## Ids are ASCII letters, digits, underscore, dash and dot.
##
## Deliberately narrow. Widening it later is easy; narrowing it after content has
## shipped with an id that no longer passes is not.
static func _is_safe_id(id: String) -> bool:
	if id.strip_edges() == "":
		return false

	for i in range(id.length()):
		var c := id.unicode_at(i)
		var ok := (
			(c >= 65 and c <= 90)
			or (c >= 97 and c <= 122)
			or (c >= 48 and c <= 57)
			or c == 95
			or c == 45
			or c == 46
		)
		if not ok:
			return false

	return true


# --- Identity --------------------------------------------------------------

## A short, stable hash of the document's contents.
##
## [b]What tells a client its cached copy is stale.[/b] A profile carries this rather
## than the avatar itself, so a scoreboard showing thirty players does not carry
## thirty documents — it carries thirty digests and fetches only the ones it does not
## already have.
##
## Depends on the sorted slot order and the quantised colours, so two machines that
## built the same avatar compute the same digest.
func digest() -> String:
	var parts_out := PackedStringArray()

	for slot in filled_slots():
		var channels := PackedStringArray()
		var list: Array = colours.get(slot, [])

		for colour in list:
			channels.append((colour as Color).to_html(false))

		parts_out.append("%s=%s:%s" % [slot, part_in(slot), ",".join(channels)])

	var canonical := "%s|%d|%s" % [schema_id, version, ";".join(parts_out)]
	return DotHash.sha256_text(canonical).substr(0, 16)


func equals(other: DotAvatar) -> bool:
	return other != null and digest() == other.digest()


# --- Serialisation ---------------------------------------------------------

func to_dict() -> Dictionary:
	var colour_out := {}

	for slot in colours:
		var encoded := PackedStringArray()
		for colour in (colours[slot] as Array):
			encoded.append((colour as Color).to_html(false))
		colour_out[str(slot)] = Array(encoded)

	var part_out := {}
	for slot in parts:
		part_out[str(slot)] = str(parts[slot])

	return {
		"version": version,
		"schema_id": String(schema_id),
		"parts": part_out,
		"colours": colour_out,
	}


## Rebuilds an avatar from stored or received data.
##
## Every field is read defensively and the result is validated, because this is where
## a hand-edited file, an older build and a hostile client payload all arrive.
static func from_dict(data: Dictionary) -> DotResult:
	var a := DotAvatar.new()

	a.version = int(data.get("version", 0))
	a.schema_id = StringName(str(data.get("schema_id", "")))

	var raw_parts: Variant = data.get("parts", {})

	if raw_parts is Dictionary:
		# Capped while reading, not after. A document claiming ten thousand slots
		# would otherwise be fully built in memory before being refused, which is the
		# denial of service the cap exists to prevent.
		var seen := 0

		for slot in (raw_parts as Dictionary):
			seen += 1
			if seen > MAX_SLOTS:
				return DotResult.fail(
					DotError.CODE_QUOTA,
					"That avatar fills more slots than are allowed.",
					"stopped at %d" % MAX_SLOTS
				)
			a.parts[StringName(str(slot))] = StringName(
				str((raw_parts as Dictionary)[slot])
			)

	var raw_colours: Variant = data.get("colours", {})

	if raw_colours is Dictionary:
		var seen_colours := 0

		for slot in (raw_colours as Dictionary):
			seen_colours += 1
			if seen_colours > MAX_SLOTS:
				return DotResult.fail(
					DotError.CODE_QUOTA,
					"That avatar carries colours for more slots than are allowed."
				)

			var list: Variant = (raw_colours as Dictionary)[slot]

			if not (list is Array):
				continue

			var decoded: Array = []

			for entry in (list as Array):
				if decoded.size() >= MAX_CHANNELS:
					break
				decoded.append(quantise(Color.html(str(entry))))

			a.colours[StringName(str(slot))] = decoded

	var migrated := a.migrate()
	if not migrated.ok:
		return migrated

	var valid := a.validate()
	if not valid.ok:
		return valid.wrap("That avatar document is not usable.")

	return DotResult.success(a)


## Brings an older document up to the current format.
func migrate() -> DotResult:
	if version > SCHEMA_VERSION:
		# Written by a newer build. Refusing beats silently dropping fields we do not
		# understand and then writing it back without them.
		return DotResult.fail(
			DotError.CODE_VERSION,
			"That avatar was made by a newer version.",
			"document v%d, this build understands v%d" % [version, SCHEMA_VERSION]
		)

	version = SCHEMA_VERSION
	return DotResult.success(true)


func duplicate_avatar() -> DotAvatar:
	var rebuilt := from_dict(to_dict())
	return rebuilt.value if rebuilt.ok else DotAvatar.make(schema_id)


func describe() -> Dictionary:
	return {
		"schema": String(schema_id),
		"version": version,
		"slots": parts.size(),
		"digest": digest(),
	}


func _to_string() -> String:
	return "DotAvatar(%s, %d slots, %s)" % [schema_id, parts.size(), digest()]
