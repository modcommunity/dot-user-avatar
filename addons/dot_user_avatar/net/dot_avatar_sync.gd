class_name DotAvatarSync
extends RefCounted

## Moving avatars between machines: the wire format, and the backbone endpoints.
##
## [b]dot-net is not a dependency and is not imported.[/b] The family rule, and in
## GDScript not merely a preference: a script that so much as [i]mentions[/i] a
## [code]class_name[/code] the project does not have fails to parse and takes
## everything referencing it down too. So the writer and reader here are typed
## [Variant] and their methods are called by name, exactly as
## [code]DotTransportENet[/code] reaches ENet through [method ClassDB.instantiate].
##
## [b]An avatar is not replicated like movement.[/b] It changes when a player opens
## the editor and never otherwise, so it travels once on join and then only on change.
## What every other client actually needs continuously is the [i]digest[/i] — sixteen
## characters saying which avatar this is — so a scoreboard of thirty players carries
## thirty digests and fetches only the documents it does not already hold.

const CHANNEL := "avatar.sync"

## Bits for the slot count in a packed document.
const COUNT_BITS := 5

## Bits per id index. Ids travel as indices into the schema, not as strings.
##
## [b]This is what makes an avatar affordable to send.[/b] A document with eight slots
## as strings is several hundred bytes; as indices it is about twenty. It also means a
## client cannot invent a part id that is not in the schema, because there is no way
## to express one.
const INDEX_BITS := 12

## Bits per colour component.
const COLOUR_BITS := 8


# --- Wire format -----------------------------------------------------------

## Packs an avatar as indices into [param schema].
##
## Both peers must hold the same schema, which they do: it is content, delivered the
## same way the meshes are. A mismatch is caught by the digest rather than producing a
## plausible wrong avatar, which is why [method write] emits one.
static func write(
	avatar: DotAvatar,
	schema: DotAvatarSchema,
	writer: Variant
) -> DotResult:
	if avatar == null or schema == null:
		return DotResult.fail(DotError.CODE_INVALID, "Nothing to write.")

	var slots := schema.ordered_slots()
	var slot_index := {}

	for i in range(slots.size()):
		slot_index[slots[i].id] = i

	var part_index := {}

	for i in range(schema.parts.size()):
		var p := schema.parts[i]
		if p != null:
			part_index[p.id] = i

	var filled := avatar.filled_slots()
	var writable: Array[StringName] = []

	for slot_id in filled:
		if slot_index.has(slot_id) and part_index.has(avatar.part_in(slot_id)):
			writable.append(slot_id)

	if writable.size() >= (1 << COUNT_BITS):
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"That avatar fills more slots than the wire format carries.",
			"%d, maximum %d" % [writable.size(), (1 << COUNT_BITS) - 1]
		)

	writer.write_uint(writable.size(), COUNT_BITS)

	for slot_id in writable:
		writer.write_uint(slot_index[slot_id], INDEX_BITS)
		writer.write_uint(part_index[avatar.part_in(slot_id)], INDEX_BITS)

		var colours: Array = avatar.colours.get(slot_id, [])
		writer.write_uint(colours.size(), 2)

		for colour in colours:
			var c: Color = colour
			writer.write_uint(int(roundf(c.r * 255.0)), COLOUR_BITS)
			writer.write_uint(int(roundf(c.g * 255.0)), COLOUR_BITS)
			writer.write_uint(int(roundf(c.b * 255.0)), COLOUR_BITS)

	return DotResult.success(writable.size())


## Reads an avatar back. Every index is checked against the schema.
##
## [b]Everything here arrived from another machine.[/b] An index past the end of the
## slot or part list is not a crash to guard against so much as the obvious thing to
## send, so it is refused rather than clamped: clamping would silently dress the
## player in whatever part happens to sit at the boundary.
static func read(schema: DotAvatarSchema, reader: Variant) -> DotResult:
	if schema == null:
		return DotResult.fail(DotError.CODE_INVALID, "No schema to read against.")

	var slots := schema.ordered_slots()
	var avatar := DotAvatar.make(schema.id)

	var count: int = reader.read_uint(COUNT_BITS)

	if count > DotAvatar.MAX_SLOTS:
		return DotResult.fail(
			DotError.CODE_QUOTA,
			"That avatar claims more slots than are allowed.",
			"%d" % count
		)

	for _i in range(count):
		var slot_i: int = reader.read_uint(INDEX_BITS)
		var part_i: int = reader.read_uint(INDEX_BITS)

		if slot_i >= slots.size():
			return DotResult.fail(
				DotError.CODE_INVALID,
				"That avatar names a slot this schema does not have.",
				"index %d of %d" % [slot_i, slots.size()]
			)

		if part_i >= schema.parts.size():
			return DotResult.fail(
				DotError.CODE_INVALID,
				"That avatar names a part this schema does not have.",
				"index %d of %d" % [part_i, schema.parts.size()]
			)

		var slot := slots[slot_i]
		var part := schema.parts[part_i]

		if part == null:
			return DotResult.fail(
				DotError.CODE_INVALID, "That avatar names an empty part slot."
			)

		avatar.set_part(slot.id, part.id)

		var channels: int = reader.read_uint(2)

		if channels > DotAvatar.MAX_CHANNELS:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"That avatar claims more colour channels than are allowed.",
				"%d" % channels
			)

		for channel in range(channels):
			var r: int = reader.read_uint(COLOUR_BITS)
			var g: int = reader.read_uint(COLOUR_BITS)
			var b: int = reader.read_uint(COLOUR_BITS)

			avatar.set_colour(
				slot.id,
				channel,
				Color(r / 255.0, g / 255.0, b / 255.0)
			)

	return DotResult.success(avatar)


## Bits a document of [param slots] slots costs, worst case.
static func estimated_bits(slots: int) -> int:
	return COUNT_BITS + slots * (
		INDEX_BITS * 2 + 2 + DotAvatar.MAX_CHANNELS * COLOUR_BITS * 3
	)


# --- Backbone --------------------------------------------------------------

## Fetches a player's avatar over the open HTTP protocol.
##
## [param http] is a [DotHttp]. Kept as a parameter rather than owned so a caller can
## share one client, its retry policy and its connection pool across every backbone
## call the process makes.
static func fetch(
	http: DotHttp,
	user_key: String,
	headers: Dictionary = {}
) -> DotResult:
	if http == null:
		return DotResult.fail(DotError.CODE_STATE, "No HTTP client.")

	if not DotAvatarKey.is_usable(user_key):
		return DotResult.fail(
			DotError.CODE_INVALID, "That is not a usable player key."
		)

	var res: DotResult = await http.get_json(
		"/user/%s/avatar" % user_key.uri_encode(), headers
	)

	if not res.ok:
		# A player who has not made one yet is the common case on a platform that
		# has just launched, so it is not an error.
		if res.error != null and res.error.http_status == 404:
			return DotResult.success(null)
		return res.wrap("Could not read the avatar.")

	var body: Variant = res.value

	if not (body is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE, "The backbone returned something that is not an avatar."
		)

	var data := body as Dictionary

	if data.has("avatar") and data["avatar"] is Dictionary:
		data = data["avatar"] as Dictionary

	return DotAvatar.from_dict(data)


## Publishes a player's avatar.
##
## [b]The backbone validates too.[/b] This is a client or a server acting for a
## player, and neither is the authority: a backbone that trusted a published document
## would accept an avatar wearing items the player does not own, from anyone who can
## reach the endpoint.
## [param extra] is merged into the body before it is sent.
##
## For the replay fields a backbone may check — a Unix-SECONDS `ts` and a random
## `nonce`. They are not part of the document and a backbone that does not check
## them ignores them, which is why they are a parameter here rather than fields on
## [DotAvatar]: the document is what a player looks like, and a timestamp is not.
static func publish(
	http: DotHttp,
	user_key: String,
	avatar: DotAvatar,
	headers: Dictionary = {},
	extra: Dictionary = {}
) -> DotResult:
	if http == null:
		return DotResult.fail(DotError.CODE_STATE, "No HTTP client.")

	if avatar == null:
		return DotResult.fail(DotError.CODE_INVALID, "No avatar to publish.")

	var structural := avatar.validate()

	if not structural.ok:
		return structural.wrap("Refusing to publish an invalid avatar.")

	var body := avatar.to_dict()

	for key in extra:
		body[key] = extra[key]

	var res: DotResult = await http.put_json(
		"/user/%s/avatar" % user_key.uri_encode(), body, headers
	)

	if not res.ok:
		return res.wrap("Could not publish the avatar.")

	# The BACKBONE's digest when it reported one, ours otherwise.
	#
	# A backbone that computes a different sixteen characters from the same
	# document is a serious fault — the digest is the whole mechanism by which a
	# client knows its cached copy of another player is stale — and returning our
	# own unconditionally would hide it behind a value that always agrees with
	# itself. The caller compares them; see DotAvatarStoreBackbone._store.
	var answer: Variant = res.value

	if answer is Dictionary and (answer as Dictionary).has("digest"):
		var reported := str((answer as Dictionary)["digest"])
		if reported != "":
			return DotResult.success(reported)

	return DotResult.success(avatar.digest())
