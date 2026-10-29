class_name DotAvatarSync
extends RefCounted

## Moving avatars between machines: the wire format, and the backbone endpoints.
## dot-net is not imported: a script naming a class the project lacks fails to parse, so writer and reader are typed [Variant] and called by name, as [code]DotTransportENet[/code] reaches ENet.
## An avatar changes only in the editor, so it travels once on join; every client needs continuously only the 16-character digest.

# No log channel: a static codec that logged would write a line per hostile packet with nothing to name;
# the helpers' only caller is DotAvatarStoreBackbone, whose store base logs failures with the key.

## Bits for the slot count in a packed document.
const COUNT_BITS := 5

## Bits per id index. Ids travel as indices into the schema, not as strings.
## Eight slots cost about twenty bytes instead of several hundred, and a client cannot express a part id outside the schema.
const INDEX_BITS := 12

## Bits per colour component.
const COLOUR_BITS := 8


## Packs an avatar as indices into [param schema].
## Both peers hold the same schema (it is content); a mismatch is caught by the digest [method write] emits, not a plausible wrong avatar.
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
## It arrived from another machine: an out-of-range index is refused, not clamped, which would dress the player in the boundary part.
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


## Fetches a player's avatar over the open HTTP protocol.
## [param http] is a [DotHttp], a parameter so a caller can share one client, retry policy and pool across backbone calls.
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

		# The site answers every member; a never-saved one gets its default with `saved: false`.
		# Read as theirs, it made every such member the same person in every game. Unsaved is no avatar.
	if data.get("saved", true) == false:
		return DotResult.success(null)

	if data.has("avatar") and data["avatar"] is Dictionary:
		data = data["avatar"] as Dictionary

	return DotAvatar.from_dict(data)


## The [code]actions[/code] of the same read (equipped emotes, poses, gestures by key), for
## [code]DotAvatarActions.from_backbone[/code]. Success value is null when the member has no
## avatar read or the backbone predates actions: the caller then plays the starter set.
static func fetch_actions(http: DotHttp, user_key: String, headers: Dictionary = {}) -> DotResult:
	if http == null:
		return DotResult.fail(DotError.CODE_STATE, "No HTTP client.")
	if not DotAvatarKey.is_usable(user_key):
		return DotResult.fail(DotError.CODE_INVALID, "That is not a usable player key.")
	var res: DotResult = await http.get_json("/user/%s/avatar" % user_key.uri_encode(), headers)
	if not res.ok:
		if res.error != null and res.error.http_status == 404:
			return DotResult.success(null)
		return res.wrap("Could not read the avatar actions.")
	var actions: Variant = (res.value as Dictionary).get("actions") if res.value is Dictionary else null
	return DotResult.success(actions if actions is Dictionary else null)


## The read's equipped wearables (wire rows for [DotAvatarWearables]), [] when none, null for no player.
static func fetch_wearables(http: DotHttp, user_key: String, headers: Dictionary = {}) -> DotResult:
	if http == null:
		return DotResult.fail(DotError.CODE_STATE, "No HTTP client.")
	if not DotAvatarKey.is_usable(user_key):
		return DotResult.fail(DotError.CODE_INVALID, "That is not a usable player key.")
	var res: DotResult = await http.get_json("/user/%s/avatar" % user_key.uri_encode(), headers)
	if not res.ok:
		if res.error != null and res.error.http_status == 404:
			return DotResult.success(null)
		return res.wrap("Could not read the avatar wearables.")
	var rows: Variant = (res.value as Dictionary).get("wearables") if res.value is Dictionary else null
	return DotResult.success(rows if rows is Array else [])


## Publishes a player's avatar.
## The backbone validates too: neither a client nor a server acting for a player is the authority.
## [param extra] is merged into the body: replay fields (Unix-SECONDS `ts`, random `nonce`), not part of the document.
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

	# The backbone's digest when it reported one, ours otherwise: a different digest from the same document
	# is a serious fault that returning ours would hide. The caller compares; see DotAvatarStoreBackbone._store.
	var answer: Variant = res.value

	if answer is Dictionary and (answer as Dictionary).has("digest"):
		var reported := str((answer as Dictionary)["digest"])
		if reported != "":
			return DotResult.success(reported)

	return DotResult.success(avatar.digest())
