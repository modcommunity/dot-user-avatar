extends RefCounted

## The manager and manager entitlements sections of avatar_demo.
## Counting stays in the host, so every check lands in the one total.

var h: Node = null


func _init(host: Node) -> void:
	h = host


func _make_manager(read_only: bool = false) -> DotAvatarManager:
	var manager := DotAvatarManager.new()
	manager.schema = h._schema
	manager.register_service = false
	manager.load_layered_config = false
	manager.config_file = ""

	var config := DotAvatarConfig.new()
	config.backend = "memory"
	config.read_only = read_only
	manager.config = config

	h.add_child(manager)
	return manager


func _test_manager() -> void:
	h._section("manager")

	var manager := _make_manager()
	var ready: DotResult = await manager.setup()

	if not h._check(ready.ok, "sets up", str(ready.error)):
		manager.queue_free()
		return

	var key: String = h._key("manager-1")
	var nothing := DotAvatarEntitlements.none()

	# A player with no avatar must still be visible.
	var first: DotResult = await manager.resolve(key, nothing)
	h._check(first.ok, "a player with no avatar resolves")
	h._check(
		(first.value as DotAvatar).has_slot(&"body"),
		"to the schema's default, with its required slots filled"
	)

	var mine: DotAvatar = h._wearable()
	var published: DotResult = await manager.publish(key, mine, nothing)
	h._check(published.ok, "an avatar publishes")
	h._check(
		str(published.value) == mine.digest(),
		"returning its digest, which is what tells other clients to refetch"
	)

	manager.clear_cache()
	var again: DotResult = await manager.resolve(key, nothing)
	h._check(
		again.ok and (again.value as DotAvatar).digest() == mine.digest(),
		"and comes back on the next resolve"
	)

	# A store that cannot answer must not leave the player invisible, and must not
	# overwrite what it could not read.
	var memory := manager.store as DotAvatarStoreMemory
	manager.clear_cache()
	memory.fail_next_fetch = true

	var degraded: DotResult = await manager.resolve(key, nothing)
	h._check(degraded.ok, "a failed read still produces a visible player")
	h._check(
		(degraded.value as DotAvatar).has_slot(&"body"),
		"using the default"
	)

	manager.clear_cache()
	var recovered: DotResult = await manager.resolve(key, nothing)
	h._check(
		recovered.ok and (recovered.value as DotAvatar).digest() == mine.digest(),
		"and the stored avatar is intact once the store recovers"
	)

	# A client in the editor publishes on every slider drag.
	var limited := false
	for i in range(60):
		var res: DotResult = await manager.publish(key, mine, nothing)
		if not res.ok and res.code() == DotError.CODE_RATE_LIMITED:
			limited = true
			break

	h._check(limited, "publishes are rate limited per player")

	var described := manager.describe_lines()
	h._check(described.size() >= 4, "describe_lines produces something usable")

	manager.queue_free()

	await _read_only_refuses(nothing)

	await _manager_defaults()
	h._done()


## A read-only manager refuses publishes rather than dropping them.
func _read_only_refuses(nothing: DotAvatarEntitlements) -> void:
	var locked := _make_manager(true)
	var locked_ready: DotResult = await locked.setup()

	if locked_ready.ok:
		var refused: DotResult = await locked.publish(
			h._key("manager-ro"), h._wearable(), nothing
		)
		h._check(
			not refused.ok,
			"a read-only manager refuses publishes rather than dropping them"
		)

	locked.queue_free()


## A game's own default and the site's translation, per player.
func _manager_defaults() -> void:
	var nothing := DotAvatarEntitlements.none()
	var mine: DotAvatar = h._wearable()
	# A game's own default, per player. The schema's is one document for everybody.
	var varied := _make_manager()
	var haired_key: String = h._key("varied-b")
	varied.default_avatar_fn = func(user_key: String) -> DotAvatar:
		var avatar: DotAvatar = h._schema.default_avatar()
		if user_key == haired_key:
			avatar.set_part(&"hair", &"hair_long")
		return avatar
	await varied.setup()

	var plain: DotResult = await varied.resolve(h._key("varied-a"), nothing)
	var haired: DotResult = await varied.resolve(h._key("varied-b"), nothing)
	h._check(
		plain.ok and haired.ok and not (plain.value as DotAvatar).has_slot(&"hair")
			and (haired.value as DotAvatar).part_in(&"hair") == &"hair_long",
		"a game's default is asked per player, by key, for somebody with nothing stored"
	)

	var stored_mine: DotResult = await varied.publish(h._key("varied-b"), mine, nothing)
	varied.clear_cache()
	var kept: DotResult = await varied.resolve(h._key("varied-b"), nothing)
	h._check(
		stored_mine.ok and kept.ok and (kept.value as DotAvatar).digest() == mine.digest(),
		"and never over what they did store"
	)

	varied.default_avatar_fn = func(_user_key: String) -> DotAvatar:
		var broken := DotAvatar.make(&"not_this_schema")
		return broken
	var fell_back: DotResult = await varied.resolve(h._key("varied-c"), nothing)
	h._check(
		fell_back.ok
			and (fell_back.value as DotAvatar).digest() == h._schema.default_avatar().digest(),
		"a default that does not fit the schema is the schema's own, not a refusal"
	)

	# Null is "no opinion": what dot-platform's wrapper answers for a game with no stock
	# function. The schema's default, and no WARN — one per first-time player otherwise.
	varied.default_avatar_fn = func(_user_key: String) -> DotAvatar:
		return null
	var warned := [0]
	var count_warns := func(rec: Dictionary) -> void:
		if int(rec.get("level", -1)) >= DotLog.Level.WARN:
			warned[0] += 1
	# The suite runs at ERROR, which would hide the very line this is about.
	DotLog.set_channel_level(DotAvatarManager.CHANNEL, DotLog.Level.WARN)
	DotLog.signals().record.connect(count_warns)
	var no_opinion: DotResult = await varied.resolve(h._key("varied-d"), nothing)
	DotLog.signals().record.disconnect(count_warns)
	DotLog.clear_channel_level(DotAvatarManager.CHANNEL)
	h._check(
		no_opinion.ok and warned[0] == 0
			and (no_opinion.value as DotAvatar).digest() == h._schema.default_avatar().digest(),
		"a default that answers null is the schema's own, and says nothing (%d warned)" % warned[0]
	)


	await _manager_translation(varied, nothing)
	varied.queue_free()


## The site's document through a game's translation, held to this schema.
func _manager_translation(varied: DotAvatarManager, nothing: DotAvatarEntitlements) -> void:
	# The site's avatar is over the SITE's schema. A game that says what its choices mean
	# in its own terms draws the member as they dressed; one that does not draws them as
	# stock, quietly. What a translation returns is still held to this schema.
	var site_doc := DotAvatar.make(&"builtin")
	site_doc.set_part(&"top", &"skin-c")
	var site_key: String = h._key("varied-site")
	await varied.store.store(site_key, site_doc)
	var untranslated: DotResult = await varied.resolve(site_key, nothing)
	h._check(
		untranslated.ok and (untranslated.value as DotAvatar).schema_id == h._schema.id
			and (untranslated.value as DotAvatar).digest() == h._schema.default_avatar().digest(),
		"a document for another schema, with no translation, is the default"
	)
	varied.translate_fn = func(foreign: DotAvatar) -> DotAvatar:
		if foreign.schema_id != &"builtin":
			return null
		var ours: DotAvatar = h._schema.default_avatar()
		if foreign.part_in(&"top") == &"skin-c":
			ours.set_part(&"hair", &"hair_long")
		return ours
	varied.clear_cache()
	var translated: DotResult = await varied.resolve(site_key, nothing)
	h._check(
		translated.ok and (translated.value as DotAvatar).part_in(&"hair") == &"hair_long",
		"a game's translation of the site's document is what the player wears"
	)
	varied.translate_fn = func(_foreign: DotAvatar) -> DotAvatar:
		var rogue: DotAvatar = h._schema.default_avatar()
		rogue.set_part(&"hair", &"hair_rare")
		return rogue
	varied.clear_cache()
	var held: DotResult = await varied.resolve(site_key, nothing)
	h._check(
		held.ok and (held.value as DotAvatar).part_in(&"hair") != &"hair_rare",
		"and a translation is held to this schema's entitlements like anything stored"
	)


func _test_manager_entitlements() -> void:
	h._section("manager: entitlements")

	var manager := _make_manager()
	var ready: DotResult = await manager.setup()

	if not h._check(ready.ok, "sets up"):
		manager.queue_free()
		return

	var key: String = h._key("manager-ent")
	var nothing := DotAvatarEntitlements.none()

	var cheating: DotAvatar = h._wearable()
	cheating.set_part(&"hair", &"hair_rare")

	var refused: DotResult = await manager.publish(key, cheating, nothing)

	h._check(
		not refused.ok,
		"publishing an avatar with an unowned part is refused"
	)
	h._check(
		manager.refused_count == 1,
		"and counted, so a moderator can see it"
	)

	var owned := DotAvatarEntitlements.of([&"hair_rare"])
	var accepted: DotResult = await manager.publish(key, cheating, owned)
	h._check(accepted.ok, "and accepted once the player owns the part")

	# A player who loses an entitlement keeps loading, wearing something else.
	manager.clear_cache()
	var after_loss: DotResult = await manager.resolve(key, nothing)
	h._check(after_loss.ok, "a player who lost an item still resolves")
	h._check(
		not (after_loss.value as DotAvatar).has_slot(&"hair"),
		"with the item removed rather than the whole avatar refused"
	)
	h._check(
		h._schema.validate(after_loss.value, nothing).ok,
		"and the result is valid"
	)

	# The setting that turns the whole check off, which exists for a creator sandbox.
	manager.config.enforce_entitlements = false
	manager.clear_cache()

	var unchecked: DotResult = await manager.publish(
		h._key("manager-sandbox"), cheating, nothing
	)
	h._check(
		unchecked.ok,
		"turning enforcement off accepts anything, as documented"
	)

	manager.queue_free()
	h._done()


## The backbone protocol, served from a dictionary: offline, but [DotAvatarStoreBackbone] is where a wrong PATH or status code is silent and total.
## Extends [DotHttp] (typed on the store) and overrides [method request] alone, so get_json/put_json keep the real JSON parsing.
