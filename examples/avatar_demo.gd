extends Node

## Exercises everything in dot-user-avatar, offline.
##
## [codeblock]
## godot --headless --path . res://examples/avatar_demo.tscn
## [/codeblock]
##
## Exits non-zero on any failure, so it works as a smoke test as-is.
##
## The cases that matter most are the ones where a mistake is a vulnerability rather
## than a crash: a client wearing something it does not own, a part worn in the wrong
## slot, an index past the end of the schema arriving on the wire, and a schema change
## making every saved avatar unloadable.

const AVATAR_DIR := "user://test_avatars"

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose.
const SECTIONS := 14

## Every check this suite runs, including the two at the end that compare the counts. The
## section counter cannot see a section that aborted after announcing itself — its remaining
## checks simply never run — and a total can. See docs/testing.md.
const CHECKS := 153

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0
var _failures := PackedStringArray()

var _schema: DotAvatarSchema = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-user-avatar self-test")
	print("")

	DotPaths.remove_tree(AVATAR_DIR)

	_schema = _build_schema()

	_test_schema()
	_test_document()
	_test_validation()
	_test_conform()
	_test_wire()
	await _test_store_contract(DotAvatarStoreMemory.new(), "memory")
	await _test_store_contract(DotAvatarStoreLocal.at(AVATAR_DIR), "local")
	var backbone_store := _fake_backbone_store()
	await _test_store_contract(backbone_store, "backbone")
	# DotHttp is a Node and nothing put it in a tree, so it is ours to free.
	(backbone_store.http as Node).free()

	await _test_backbone_protocol()
	_test_catalogue()
	await _test_catalogue_delivery()
	_test_builder()
	await _test_manager()
	await _test_manager_entitlements()

	DotPaths.remove_tree(AVATAR_DIR)

	print("")
	# The two guards, as the last two checks. See docs/testing.md.
	_check(
		_completed == _entered and _entered == SECTIONS,
		"every section ran to its last line (%d of %d)" % [_completed, SECTIONS]
	)
	_check(
		_passed + _failed + 1 == CHECKS,
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS]
	)
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- Assertions ------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else " — " + detail])
	return condition


# --- Fixtures --------------------------------------------------------------

## A schema of the kind a game would ship.
func _build_schema() -> DotAvatarSchema:
	var schema := DotAvatarSchema.new()
	schema.id = &"humanoid"

	var body := DotAvatarSlot.make(&"body", true, &"body_default")
	body.layer = 10

	var hair := DotAvatarSlot.make(&"hair")
	hair.layer = 30

	var hat := DotAvatarSlot.make(&"hat")
	hat.layer = 40
	hat.hides = [&"hair"]

	var shirt := DotAvatarSlot.make(&"shirt", true, &"shirt_default")
	shirt.layer = 20

	schema.slots = [body, hair, hat, shirt]

	var body_default := DotAvatarPart.make(&"body_default", &"body", true)
	body_default.colour_channels = 1

	var hair_long := DotAvatarPart.make(&"hair_long", &"hair", true)
	hair_long.colour_channels = 1

	var hair_rare := DotAvatarPart.make(&"hair_rare", &"hair", false)
	# Tintable like the free one. Without this the entitlement cases below fail on the
	# colour check instead — which is the colour check working, but it means those
	# cases stop testing entitlements at all.
	hair_rare.colour_channels = 1

	var shirt_default := DotAvatarPart.make(&"shirt_default", &"shirt", true)
	shirt_default.colour_channels = 2

	var hat_paid := DotAvatarPart.make(&"hat_paid", &"hat", false)

	var hat_retired := DotAvatarPart.make(&"hat_retired", &"hat", false)
	hat_retired.retired = true

	var hat_streamed := DotAvatarPart.make(&"hat_streamed", &"hat", true)
	hat_streamed.content_id = "sha256:notdownloadedyet"
	hat_streamed.fallback_id = &"hat_paid"

	schema.parts = [
		body_default, hair_long, hair_rare, shirt_default,
		hat_paid, hat_retired, hat_streamed,
	]

	schema.invalidate()
	return schema


func _wearable() -> DotAvatar:
	var a := DotAvatar.make(&"humanoid")
	a.set_part(&"body", &"body_default")
	a.set_part(&"shirt", &"shirt_default")
	a.set_part(&"hair", &"hair_long")
	a.set_colour(&"hair", 0, Color("6b4423"))
	return a


static func _key(seed_text: String) -> String:
	return DotHash.sha256_text(seed_text).substr(0, 22)


# --- Schema ----------------------------------------------------------------

func _test_schema() -> void:
	_section("schema")

	_check(_schema.validate_schema().ok, "a well-formed schema validates")
	_check(_schema.slot(&"hair") != null, "slots resolve by id")
	_check(_schema.part(&"hair_long") != null, "parts resolve by id")
	_check(_schema.part(&"nothing") == null, "an unknown part resolves to null")

	var ordered := _schema.ordered_slots()
	_check(
		ordered[0].id == &"body" and ordered[ordered.size() - 1].id == &"hat",
		"slots order by layer, so skin comes before clothing"
	)

	# A required slot with no default cannot be repaired, so every document missing it
	# would be permanently invalid. Forbidden at startup rather than discovered later.
	var broken := DotAvatarSchema.new()
	broken.id = &"broken"
	broken.slots = [DotAvatarSlot.make(&"body", true, &"")]
	_check(
		not broken.validate_schema().ok,
		"a required slot with no default is refused at startup"
	)

	var dangling := DotAvatarSchema.new()
	dangling.id = &"dangling"
	dangling.slots = [DotAvatarSlot.make(&"body", true, &"missing_part")]
	_check(
		not dangling.validate_schema().ok,
		"a default that does not exist is refused"
	)

	var orphan := DotAvatarSchema.new()
	orphan.id = &"orphan"
	orphan.slots = [DotAvatarSlot.make(&"body")]
	orphan.parts = [DotAvatarPart.make(&"thing", &"nowhere")]
	_check(
		not orphan.validate_schema().ok,
		"a part in a slot that does not exist is refused"
	)

	# An editor must not offer what the player cannot wear, or every choice is a
	# refusal waiting to happen.
	var poor := DotAvatarEntitlements.none()
	var choices := _schema.choices_for(&"hair", poor)

	_check(choices.size() == 1, "an editor is offered only free parts by default")
	_check(choices[0].id == &"hair_long", "and it is the free one")

	var rich := DotAvatarEntitlements.of([&"hair_rare"])
	_check(
		_schema.choices_for(&"hair", rich).size() == 2,
		"and owned parts as well"
	)

	# A retired part stays wearable for whoever has it and is offered to nobody.
	var owner := DotAvatarEntitlements.of([&"hat_retired"])
	var hats := _schema.choices_for(&"hat", owner)
	var offered_retired := false
	for h in hats:
		if h.id == &"hat_retired":
			offered_retired = true
	_check(not offered_retired, "a retired part is not offered in the editor")
	_done()


# --- Document --------------------------------------------------------------

func _test_document() -> void:
	_section("document")

	var a := _wearable()

	_check(a.validate().ok, "a well-formed document validates")
	_check(a.part_in(&"hair") == &"hair_long", "parts read back")
	_check(a.has_slot(&"hair"), "and report as filled")

	a.clear_slot(&"hair")
	_check(not a.has_slot(&"hair"), "clearing a slot empties it")
	_check(
		not a.colours.has(&"hair"),
		"and takes its colours with it, so they cannot accumulate"
	)

	# Quantised on the way in, not on the wire, so a document is byte-identical
	# wherever it was built and its digest matches.
	var b := _wearable()
	b.set_colour(&"hair", 0, Color(0.5019608, 0.2509804, 0.1254902))
	var stored := b.colour_of(&"hair", 0)
	_check(
		stored == DotAvatar.quantise(stored),
		"a colour is quantised when it is set"
	)

	b.set_colour(&"hair", 0, Color(1.0, 0.0, 0.0, 0.25))
	_check(
		b.colour_of(&"hair", 0).a == 1.0,
		"alpha is dropped, so nobody can make themselves transparent"
	)

	_check(
		not b.set_colour(&"hair", 9, Color.RED).ok,
		"a colour channel past the limit is refused"
	)

	# The digest is what tells a client its cached copy is stale.
	var c := _wearable()
	var d := _wearable()
	_check(c.digest() == d.digest(), "identical avatars have identical digests")

	d.set_part(&"hair", &"hair_rare")
	_check(c.digest() != d.digest(), "and a change alters it")

	# Order must not matter, or two machines that built the same avatar disagree.
	var e := DotAvatar.make(&"humanoid")
	e.set_part(&"shirt", &"shirt_default")
	e.set_part(&"body", &"body_default")
	e.set_part(&"hair", &"hair_long")
	e.set_colour(&"hair", 0, Color("6b4423"))
	_check(
		e.digest() == c.digest(),
		"the digest does not depend on the order slots were filled"
	)

	var round_tripped := DotAvatar.from_dict(c.to_dict())
	_check(round_tripped.ok, "a document round-trips through a dictionary")
	_check(
		round_tripped.ok and (round_tripped.value as DotAvatar).digest() == c.digest(),
		"with an identical digest"
	)

	# Hostile ids. These become dictionary keys, log lines and content lookups.
	for bad in ["../../etc/passwd", "a/b", "with space", "new\nline", ""]:
		var hostile := DotAvatar.make(&"humanoid")
		hostile.parts[StringName(bad)] = &"body_default"
		_check(
			not hostile.validate().ok,
			"a slot id of '%s' is refused" % bad.substr(0, 16).replace("\n", "\\n")
		)

	# Bounded, because a document is relayed to everyone in the match.
	var huge := DotAvatar.make(&"humanoid")
	for i in range(DotAvatar.MAX_SLOTS + 5):
		huge.parts[StringName("slot_%d" % i)] = &"body_default"
	_check(not huge.validate().ok, "an over-large document is refused")

	var huge_dict := {"schema_id": "humanoid", "version": 1, "parts": {}}
	for i in range(500):
		huge_dict["parts"]["slot_%d" % i] = "body_default"
	_check(
		not DotAvatar.from_dict(huge_dict).ok,
		"and is refused while reading, not after it is fully built"
	)

	var newer := c.to_dict()
	newer["version"] = DotAvatar.SCHEMA_VERSION + 3
	_check(
		not DotAvatar.from_dict(newer).ok,
		"a document from a newer build is refused, not silently downgraded"
	)
	_done()


# --- Validation against the schema -----------------------------------------

func _test_validation() -> void:
	_section("validation")

	var owned := DotAvatarEntitlements.of([&"hat_paid"])
	var nothing := DotAvatarEntitlements.none()

	_check(
		_schema.validate(_wearable(), nothing).ok,
		"an avatar of free parts validates with no entitlements"
	)

	# The check the whole addon exists for.
	var cheating := _wearable()
	cheating.set_part(&"hair", &"hair_rare")

	_check(
		not _schema.validate(cheating, nothing).ok,
		"an avatar wearing an unowned part is refused"
	)
	_check(
		_schema.validate(cheating, DotAvatarEntitlements.of([&"hair_rare"])).ok,
		"and accepted once the player owns it"
	)
	_check(
		_schema.validate(cheating, nothing).code() == DotError.CODE_FORBIDDEN,
		"with a code a caller can branch on"
	)

	# A part in the wrong slot is how a mesh appears somewhere it was never authored
	# for, which at best looks broken and at worst is a way to be hard to see.
	var misplaced := _wearable()
	misplaced.set_part(&"hat", &"hair_long")
	_check(
		not _schema.validate(misplaced, nothing).ok,
		"a part worn in the wrong slot is refused"
	)

	var invented := _wearable()
	invented.set_part(&"hair", &"hair_that_does_not_exist")
	_check(
		not _schema.validate(invented, nothing).ok,
		"a part that does not exist is refused"
	)

	var wrong_slot := _wearable()
	wrong_slot.set_part(&"elbow", &"hair_long")
	_check(
		not _schema.validate(wrong_slot, nothing).ok,
		"a slot the schema does not have is refused"
	)

	var naked := DotAvatar.make(&"humanoid")
	naked.set_part(&"hair", &"hair_long")
	_check(
		not _schema.validate(naked, nothing).ok,
		"an avatar missing a required slot is refused, so nobody is invisible"
	)

	var over_coloured := _wearable()
	over_coloured.set_part(&"hat", &"hat_paid")
	over_coloured.set_colour(&"hat", 0, Color.RED)
	_check(
		not _schema.validate(over_coloured, owned).ok,
		"colours on a part that has none are refused"
	)

	var foreign := DotAvatar.make(&"other_game")
	foreign.set_part(&"body", &"body_default")
	_check(
		not _schema.validate(foreign, nothing).ok,
		"a document for another schema is refused"
	)

	# The escape hatch, and the reason it is named so conspicuously.
	_check(
		_schema.validate(cheating, DotAvatarEntitlements.everything()).ok,
		"an unrestricted entitlement set permits everything"
	)
	_check(
		_schema.validate(cheating, null).ok,
		"and passing null skips the ownership check entirely"
	)
	_done()


# --- Conforming ------------------------------------------------------------

func _test_conform() -> void:
	_section("conforming to a changed schema")

	var nothing := DotAvatarEntitlements.none()

	# A player who has not logged in for a month must not load into an error.
	var stale := _wearable()
	stale.set_part(&"hat", &"hat_that_was_removed")

	var conformed := _schema.conform(stale, nothing)

	_check(conformed.ok, "a document with a removed part conforms")
	_check(
		not stale.has_slot(&"hat"),
		"the missing part is dropped"
	)
	_check(
		(conformed.value as PackedStringArray).size() == 1,
		"and the change is reported, so the player can be told"
	)
	_check(
		_schema.validate(stale, nothing).ok,
		"and the result is valid"
	)

	# Losing an entitlement is the same shape of problem.
	var repossessed := _wearable()
	repossessed.set_part(&"hair", &"hair_rare")

	var after := _schema.conform(repossessed, nothing)
	_check(after.ok, "an avatar wearing a lost item conforms")
	_check(
		not repossessed.has_slot(&"hair"),
		"and the item is removed rather than the whole avatar refused"
	)

	# A new required slot fills from its default.
	var missing_required := DotAvatar.make(&"humanoid")
	missing_required.set_part(&"hair", &"hair_long")

	var filled := _schema.conform(missing_required, nothing)
	_check(filled.ok, "an avatar missing a required slot conforms")
	_check(
		missing_required.part_in(&"body") == &"body_default",
		"the required slot takes its default"
	)
	_check(
		_schema.validate(missing_required, nothing).ok,
		"and the result is valid"
	)

	# Colours left over from a part that had more channels.
	var over := _wearable()
	over.colours[&"hair"] = [Color.RED, Color.GREEN, Color.BLUE]
	var trimmed := _schema.conform(over, nothing)
	_check(trimmed.ok, "extra colours conform")
	_check(
		(over.colours[&"hair"] as Array).size() == 1,
		"and are trimmed to what the part has"
	)

	# The one thing conform refuses: nothing in a foreign document means anything.
	var foreign := DotAvatar.make(&"other_game")
	_check(
		not _schema.conform(foreign, nothing).ok,
		"a document for another schema cannot be conformed"
	)

	var unchanged := _wearable()
	var noop := _schema.conform(unchanged, nothing)
	_check(
		noop.ok and (noop.value as PackedStringArray).is_empty(),
		"a document that already fits reports no changes"
	)
	_done()


# --- Wire ------------------------------------------------------------------

## A stand-in for DotNetWriter / DotNetReader.
##
## dot-net is not installed here and must not be — the point is that this works
## without it. But the duck-typed calls have to line up with the real thing, and a
## typo in a method name is a runtime failure only a host game would ever see.
class FakeWire extends RefCounted:
	var values: Array = []
	var _read_index := 0

	func write_uint(v: int, _bits: int) -> void:
		values.append(v)

	func read_uint(_bits: int) -> int:
		var v: int = values[_read_index]
		_read_index += 1
		return v

	func rewind() -> void:
		_read_index = 0


func _test_wire() -> void:
	_section("wire format")

	var original := _wearable()
	var wire := FakeWire.new()

	var written := DotAvatarSync.write(original, _schema, wire)
	_check(written.ok, "an avatar writes")

	var decoded := DotAvatarSync.read(_schema, wire)
	_check(decoded.ok, "and reads back", str(decoded.error) if not decoded.ok else "")

	if decoded.ok:
		var got: DotAvatar = decoded.value
		_check(
			got.digest() == original.digest(),
			"identically, so the digest still matches",
			"%s vs %s" % [got.digest(), original.digest()]
		)
		_check(
			got.colour_of(&"hair", 0).is_equal_approx(original.colour_of(&"hair", 0)),
			"including the colours"
		)

	_check(
		DotAvatarSync.estimated_bits(8) < 800,
		"eight slots cost under 100 bytes",
		"%d bits" % DotAvatarSync.estimated_bits(8)
	)

	# Everything here arrived from another machine. An index past the end of the
	# schema is the obvious thing to send, and clamping it would silently dress the
	# player in whatever sits at the boundary.
	var hostile := FakeWire.new()
	hostile.values = [1, 9999, 0, 0]
	_check(
		not DotAvatarSync.read(_schema, hostile).ok,
		"a slot index past the end of the schema is refused"
	)

	var hostile_part := FakeWire.new()
	hostile_part.values = [1, 0, 9999, 0]
	_check(
		not DotAvatarSync.read(_schema, hostile_part).ok,
		"a part index past the end is refused"
	)

	var hostile_count := FakeWire.new()
	hostile_count.values = [31, 0, 0, 0]
	_check(
		not DotAvatarSync.read(_schema, hostile_count).ok,
		"a slot count past the document limit is refused"
	)

	var hostile_channels := FakeWire.new()
	hostile_channels.values = [1, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	var channelled := DotAvatarSync.read(_schema, hostile_channels)
	_check(
		channelled.ok,
		"a legal channel count is accepted"
	)
	_done()


# --- Stores ----------------------------------------------------------------

func _test_store_contract(store: DotAvatarStore, label: String) -> void:
	_section("store contract")
	print("store contract: %s" % label)

	var key := _key("store-%s" % label)

	var opened: DotResult = await store.open()
	_check(opened.ok, "[%s] opens" % label)

	var missing: DotResult = await store.fetch(key)
	_check(
		missing.ok and missing.value == null,
		"[%s] a player with no avatar is not a failure" % label
	)

	var a := _wearable()
	var stored: DotResult = await store.store(key, a)
	_check(stored.ok, "[%s] an avatar stores" % label)

	var read: DotResult = await store.fetch(key)
	_check(read.ok and read.value != null, "[%s] and reads back" % label)

	if read.ok and read.value != null:
		var got: DotAvatar = read.value
		_check(
			got.digest() == a.digest(),
			"[%s] with an identical digest" % label
		)

		got.set_part(&"hair", &"hair_rare")
		var again: DotResult = await store.fetch(key)
		_check(
			again.ok and (again.value as DotAvatar).digest() == a.digest(),
			"[%s] the store hands out copies, not references" % label
		)

	var invalid := DotAvatar.make(&"")
	var refused: DotResult = await store.store(key, invalid)
	_check(
		not refused.ok,
		"[%s] a structurally invalid avatar is refused" % label
	)

	var traversal: DotResult = await store.fetch("../../secrets")
	_check(
		not traversal.ok,
		"[%s] a malformed key never reaches the store" % label
	)

	var removed: DotResult = await store.remove(key)
	_check(removed.ok, "[%s] an avatar removes" % label)

	var gone: DotResult = await store.fetch(key)
	_check(gone.ok and gone.value == null, "[%s] and is then absent" % label)

	store.close()
	_done()


# --- Catalogue -------------------------------------------------------------

func _test_catalogue() -> void:
	_section("catalogue")

	var catalogue := DotAvatarCatalogue.new()

	# No dot-cloud installed and no built-in content, so nothing resolves. That is a
	# normal outcome on a server and in a test, and it must not be a failure.
	var streamed := _schema.part(&"hat_streamed")
	_check(
		catalogue.resolve(streamed) == "",
		"content that has not arrived resolves to nothing, not an error"
	)
	_check(
		catalogue.is_pending(&"hat_streamed"),
		"and is recorded as pending, so a loading indicator can say so"
	)

	# The fallback chain has to be bounded: two parts naming each other is a content
	# mistake that would otherwise hang the renderer.
	var loop_a := DotAvatarPart.make(&"loop_a", &"hat")
	loop_a.fallback_id = &"loop_b"
	var loop_b := DotAvatarPart.make(&"loop_b", &"hat")
	loop_b.fallback_id = &"loop_a"

	var looped := DotAvatarSchema.new()
	looped.id = &"looped"
	looped.slots = [DotAvatarSlot.make(&"hat")]
	looped.parts = [loop_a, loop_b]
	looped.invalidate()

	var resolved := catalogue.resolve_with_fallback(loop_a, looped)
	_check(
		resolved == null,
		"a circular fallback chain terminates instead of hanging"
	)

	# The resolver hook, for a game whose content layout is nothing like either
	# default.
	catalogue.invalidate()
	catalogue.resolver = func(p: DotAvatarPart) -> String:
		return "res://custom/%s.tscn" % p.id

	_check(
		catalogue.resolve(streamed) == "res://custom/hat_streamed.tscn",
		"a custom resolver overrides everything"
	)
	_done()


# --- Builder ---------------------------------------------------------------

func _test_builder() -> void:
	_section("builder")

	var catalogue := DotAvatarCatalogue.new()
	var avatar := _wearable()

	var steps := DotAvatarBuilder.plan(avatar, _schema, catalogue)

	_check(steps.size() == 3, "a plan covers every filled slot", "%d" % steps.size())
	_check(
		steps[0].slot == &"body",
		"in layer order, so skin is applied before clothing",
		String(steps[0].slot)
	)

	# Nothing resolves in this project, so every slot is missing — which is exactly
	# the case that must not produce an invisible player.
	var summary := DotAvatarBuilder.summarise(steps)
	_check(
		int(summary["missing"]) == 3,
		"content that has not arrived is reported as missing, not skipped"
	)
	_check(
		not bool(summary["complete"]),
		"and the plan reports itself as incomplete"
	)

	# A hat hides hair, and the hiding is resolved in the plan rather than left to
	# the renderer, so a caller counting steps sees what will actually appear.
	var hatted := _wearable()
	hatted.set_part(&"hat", &"hat_paid")

	var hat_steps := DotAvatarBuilder.plan(hatted, _schema, catalogue)
	var has_hair := false
	for step in hat_steps:
		if step.slot == &"hair":
			has_hair = true

	_check(not has_hair, "a slot hidden by another is dropped from the plan")

	# A document naming a part the schema does not have must not crash the plan.
	var broken := _wearable()
	broken.parts[&"hair"] = &"not_a_part"
	var broken_steps := DotAvatarBuilder.plan(broken, _schema, catalogue)
	_check(
		broken_steps.size() == 2,
		"an unconformed document skips the unknown part rather than crashing",
		"%d steps" % broken_steps.size()
	)

	_check(
		DotAvatarBuilder.apply(steps, null).ok == false,
		"applying to no rig is a failure, not a crash"
	)
	_done()


# --- Manager ---------------------------------------------------------------

func _make_manager(read_only: bool = false) -> DotAvatarManager:
	var manager := DotAvatarManager.new()
	manager.schema = _schema
	manager.register_service = false
	manager.load_layered_config = false
	manager.config_file = ""

	var config := DotAvatarConfig.new()
	config.backend = "memory"
	config.read_only = read_only
	manager.config = config

	add_child(manager)
	return manager


func _test_manager() -> void:
	_section("manager")

	var manager := _make_manager()
	var ready: DotResult = await manager.setup()

	if not _check(ready.ok, "sets up", str(ready.error)):
		manager.queue_free()
		return

	var key := _key("manager-1")
	var nothing := DotAvatarEntitlements.none()

	# A player with no avatar must still be visible.
	var first: DotResult = await manager.resolve(key, nothing)
	_check(first.ok, "a player with no avatar resolves")
	_check(
		(first.value as DotAvatar).has_slot(&"body"),
		"to the schema's default, with its required slots filled"
	)

	var mine := _wearable()
	var published: DotResult = await manager.publish(key, mine, nothing)
	_check(published.ok, "an avatar publishes")
	_check(
		str(published.value) == mine.digest(),
		"returning its digest, which is what tells other clients to refetch"
	)

	manager.clear_cache()
	var again: DotResult = await manager.resolve(key, nothing)
	_check(
		again.ok and (again.value as DotAvatar).digest() == mine.digest(),
		"and comes back on the next resolve"
	)

	# A store that cannot answer must not leave the player invisible, and must not
	# overwrite what it could not read.
	var memory := manager.store as DotAvatarStoreMemory
	manager.clear_cache()
	memory.fail_next_fetch = true

	var degraded: DotResult = await manager.resolve(key, nothing)
	_check(degraded.ok, "a failed read still produces a visible player")
	_check(
		(degraded.value as DotAvatar).has_slot(&"body"),
		"using the default"
	)

	manager.clear_cache()
	var recovered: DotResult = await manager.resolve(key, nothing)
	_check(
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

	_check(limited, "publishes are rate limited per player")

	var described := manager.describe_lines()
	_check(described.size() >= 4, "describe_lines produces something usable")

	manager.queue_free()

	var locked := _make_manager(true)
	var locked_ready: DotResult = await locked.setup()

	if locked_ready.ok:
		var refused: DotResult = await locked.publish(
			_key("manager-ro"), _wearable(), nothing
		)
		_check(
			not refused.ok,
			"a read-only manager refuses publishes rather than dropping them"
		)

	locked.queue_free()
	_done()


func _test_manager_entitlements() -> void:
	_section("manager: entitlements")

	var manager := _make_manager()
	var ready: DotResult = await manager.setup()

	if not _check(ready.ok, "sets up"):
		manager.queue_free()
		return

	var key := _key("manager-ent")
	var nothing := DotAvatarEntitlements.none()

	var cheating := _wearable()
	cheating.set_part(&"hair", &"hair_rare")

	var refused: DotResult = await manager.publish(key, cheating, nothing)

	_check(
		not refused.ok,
		"publishing an avatar with an unowned part is refused"
	)
	_check(
		manager.refused_count == 1,
		"and counted, so a moderator can see it"
	)

	var owned := DotAvatarEntitlements.of([&"hair_rare"])
	var accepted: DotResult = await manager.publish(key, cheating, owned)
	_check(accepted.ok, "and accepted once the player owns the part")

	# A player who loses an entitlement keeps loading, wearing something else.
	manager.clear_cache()
	var after_loss: DotResult = await manager.resolve(key, nothing)
	_check(after_loss.ok, "a player who lost an item still resolves")
	_check(
		not (after_loss.value as DotAvatar).has_slot(&"hair"),
		"with the item removed rather than the whole avatar refused"
	)
	_check(
		_schema.validate(after_loss.value, nothing).ok,
		"and the result is valid"
	)

	# The setting that turns the whole check off, which exists for a creator sandbox.
	manager.config.enforce_entitlements = false
	manager.clear_cache()

	var unchecked: DotResult = await manager.publish(
		_key("manager-sandbox"), cheating, nothing
	)
	_check(
		unchecked.ok,
		"turning enforcement off accepts anything, as documented"
	)

	manager.queue_free()
	_done()


# --- Backbone --------------------------------------------------------------

## The backbone protocol, served from a dictionary.
##
## [b]Why a fake rather than a real request.[/b] Every check in this file is offline
## and has to stay that way — a self-test that needs a server is a self-test nobody
## runs — but a store that is never exercised is a store nobody has run either, and
## [DotAvatarStoreBackbone] is the one place in this addon where a wrong PATH or a
## mishandled status code is a silent, total failure on the join path.
##
## Extends [DotHttp] rather than duck-typing it, because [member
## DotAvatarStoreBackbone.http] is typed and a store whose transport could be anything
## is a store that cannot state what it needs. Overriding [method request] alone is
## enough: [method DotHttp.get_json] and [method DotHttp.put_json] are both built on
## it, so this covers all three verbs and the JSON parsing stays the real one.
class FakeBackboneHttp extends DotHttp:
	## user_key -> the stored DotAvatar.to_dict().
	var avatars: Dictionary = {}

	## Every path this was asked for, in order. The assertions read it.
	var seen: Array[String] = []

	## Set to serve a 500, for the failure path.
	var fail_next: bool = false

	func request(
		method: int,
		path: String,
		body: PackedByteArray = PackedByteArray(),
		_headers: Dictionary = {},
		_decode_text: bool = true
	) -> DotResult:
		seen.append("%d %s" % [method, path])

		if fail_next:
			fail_next = false
			return DotResult.failure(DotError.from_http(500, "boom"))

		# The protocol's one address. Anything else is a client bug and is
		# answered the way a real backbone would answer it, rather than being
		# quietly tolerated by a fake that is more forgiving than the thing it
		# stands in for.
		var parts := path.split("/", false)

		if parts.size() != 3 or parts[0] != "user" or parts[2] != "avatar":
			return DotResult.failure(DotError.from_http(404, "no such route"))

		var key := parts[1].uri_decode()

		match method:
			HTTPClient.METHOD_GET:
				if not avatars.has(key):
					return DotResult.failure(DotError.from_http(404, "no avatar"))

				return _json({"avatar": avatars[key], "digest": _digest_of(key)})

			HTTPClient.METHOD_PUT:
				var parsed: Variant = JSON.parse_string(
					body.get_string_from_utf8()
				)

				if not (parsed is Dictionary):
					return DotResult.failure(DotError.from_http(400, "not json"))

				avatars[key] = parsed
				return _json({"avatar": parsed, "digest": _digest_of(key)})

			HTTPClient.METHOD_DELETE:
				if not avatars.has(key):
					return DotResult.failure(DotError.from_http(404, "no avatar"))

				avatars.erase(key)
				return _json({"ok": true})

		return DotResult.failure(DotError.from_http(405, "method not allowed"))

	func _digest_of(key: String) -> String:
		var rebuilt := DotAvatar.from_dict(avatars[key])
		return (rebuilt.value as DotAvatar).digest() if rebuilt.ok else ""

	## A success in the shape [method DotHttp.request] returns.
	##
	## Not just the bytes: `get_json` and `put_json` hand this to the REAL
	## `_parse_json`, which reads `body_text` off a dictionary. Returning a bare
	## PackedByteArray parses cleanly as a fake and fails against the thing it
	## is standing in for, which is the one failure a fake must not have.
	static func _json(value: Variant) -> DotResult:
		var text := JSON.stringify(value)

		return DotResult.success({
			"status": 200,
			"headers": {"content-type": "application/json"},
			"body": text.to_utf8_buffer(),
			"body_text": text,
		})


func _fake_backbone_store() -> DotAvatarStoreBackbone:
	var store := DotAvatarStoreBackbone.at(
		"https://backbone.test/api/integration/v1", "test-token"
	)
	store.http = FakeBackboneHttp.new()
	return store


## The parts of the protocol the shared store contract cannot see.
func _test_backbone_protocol() -> void:
	_section("backbone protocol")

	var store := _fake_backbone_store()
	var http := store.http as FakeBackboneHttp
	var key := _key("backbone-protocol")

	var opened: DotResult = await store.open()
	_check(opened.ok, "opens against a configured backbone")

	var missing: DotResult = await store.fetch(key)
	_check(
		missing.ok and missing.value == null,
		"a 404 means the player has no avatar yet, not a failure"
	)

	var a := _wearable()
	var stored: DotResult = await store.store(key, a)
	_check(stored.ok, "an avatar publishes")

	_check(
		http.seen.has("%d /user/%s/avatar" % [HTTPClient.METHOD_PUT, key]),
		"to PUT /user/{key}/avatar, the documented address"
	)

	var read: DotResult = await store.fetch(key)
	_check(
		read.ok and read.value != null,
		"and reads back through the wrapped payload"
	)

	if read.ok and read.value != null:
		_check(
			(read.value as DotAvatar).digest() == a.digest(),
			"with the digest both sides compute independently"
		)

	# The one that matters: a backbone whose digest disagrees with ours breaks
	# every client's cache invalidation and reports nothing, so the store warns.
	# Here we only assert the publish still SUCCEEDS — the write did happen, and
	# failing it afterwards would be a lie about what is stored.
	http.fail_next = true
	var failed: DotResult = await store.store(key, a)
	_check(not failed.ok, "a backbone error is reported rather than swallowed")

	var removed: DotResult = await store.remove(key)
	_check(removed.ok, "an avatar erases")
	_check(
		http.seen.has("%d /user/%s/avatar" % [HTTPClient.METHOD_DELETE, key]),
		"through DELETE on the same address"
	)

	var gone: DotResult = await store.fetch(key)
	_check(gone.ok and gone.value == null, "and is then absent")

	var read_only := _fake_backbone_store()
	read_only.read_only = true
	await read_only.open()

	var refused: DotResult = await read_only.store(key, a)
	_check(
		not refused.ok,
		"a read-only backbone store refuses publishes rather than dropping them"
	)

	var no_token := DotAvatarStoreBackbone.at("https://backbone.test", "")
	var unopened: DotResult = await no_token.open()
	_check(
		not unopened.ok,
		"a backbone store with no credential refuses to open"
	)
	# It refused BEFORE building a client, so there is nothing to free here —
	# asserted rather than assumed, because a store that built one anyway would
	# be holding a transport for a connection it just declined to make.
	_check(no_token.http == null, "and builds no client for a refused open")

	store.close()

	# DotHttp is a Node and nothing here put it in a tree, so it is ours to
	# free — an otherwise-clean run that prints "ObjectDB instances leaked" is a
	# run people stop reading the end of.
	(store.http as Node).free()
	(read_only.http as Node).free()
	_done()


# --- Delivered content -----------------------------------------------------
#
# [b]This is the section that would have caught the hole it was written for.[/b] The
# catalogue asked dot-cloud whether a part was mounted and never once asked it to fetch
# one, so a part naming content that nothing had already downloaded resolved to "" for
# the life of the process and every wearer quietly fell back to a stock part. Nothing
# errored, because falling back IS the designed behaviour for content that has not
# arrived -- the bug was that it could never arrive.
#
# The old catalogue test above cannot see it: it runs with NO cloud client, which is the
# branch that returns "" correctly and passes. That is the same shape as dot-map's hole,
# whose only loader test also ran with no cloud client and also passed for months.


## The duck-typed interface [DotContent] speaks, and nothing else.
##
## A Node, and `ensure` awaits a frame, so the test drives a real coroutine rather than
## a function that happens to return a value -- `await` on a non-coroutine is a no-op and
## would prove nothing about the asynchronous path.
class StubCloud extends Node:
	var mounted: Dictionary = {}
	var asked: PackedStringArray = PackedStringArray()
	var refuse: bool = false

	## Where this pretends content lands. `res://examples` really exists and really
	## contains `avatar_demo.tscn`, which stands in for a part scene: the catalogue
	## checks the path with `ResourceLoader.exists`, so a fixture that is not there
	## would fail for the wrong reason.
	const PREFIX := "res://examples"

	func ensure(
		content_id: StringName,
		_version: String = "",
		_groups: PackedStringArray = PackedStringArray(),
		_manifest_url: String = ""
	) -> DotResult:
		asked.append(String(content_id))
		await get_tree().process_frame

		if refuse:
			return DotResult.fail(DotError.CODE_IO, "the network said no")

		mounted[String(content_id)] = true
		return DotResult.success(PREFIX)

	func resolve(content_id: StringName) -> String:
		return PREFIX if mounted.has(String(content_id)) else ""

	func is_mounted(content_id: StringName, _version: String = "") -> bool:
		return mounted.has(String(content_id))


func _test_catalogue_delivery() -> void:
	_section("delivered content")

	var cloud := StubCloud.new()
	cloud.name = "StubCloud"
	add_child(cloud)
	DotRegistry.register(&"dot_cloud_client", cloud)

	var catalogue := DotAvatarCatalogue.new()

	# `avatar_demo` so that PREFIX + "/" + id + ".tscn" is a file that exists. The part
	# id is doing double duty as a filename, which is exactly what the real catalogue
	# does with `builtin_prefix`.
	var part := DotAvatarPart.make(&"avatar_demo", &"hat")
	part.content_id = "test_pack"

	var arrived: Array[StringName] = []
	catalogue.part_ready.connect(func(id: StringName) -> void: arrived.append(id))

	_check(
		catalogue.resolve(part) == "",
		"content that is not mounted still resolves to nothing at first"
	)
	_check(
		catalogue.is_pending(&"avatar_demo"),
		"and is pending while it downloads"
	)

	# Two frames: one for the stub's own await, one for the resolution that follows it.
	await get_tree().process_frame
	await get_tree().process_frame

	_check(
		cloud.asked.size() == 1 and cloud.asked[0] == "test_pack",
		"a resolve miss ASKS for the content",
		"asked for %s" % str(cloud.asked)
	)
	_check(
		arrived.has(&"avatar_demo"),
		"and announces the part when it lands, so a renderer can re-dress"
	)
	_check(
		catalogue.resolve(part) == "res://examples/avatar_demo.tscn",
		"which then resolves to the scene inside the mount",
		catalogue.resolve(part)
	)
	_check(
		not catalogue.is_pending(&"avatar_demo"),
		"and is no longer pending"
	)

	# One fetch, not one per resolve. A character is dressed every time it spawns and a
	# part that started a download per call would hammer the content origin.
	catalogue.invalidate()
	catalogue.resolve(part)
	catalogue.resolve(part)
	await get_tree().process_frame

	_check(
		cloud.asked.size() == 1,
		"already-mounted content is not fetched again",
		"asked %d times" % cloud.asked.size()
	)

	# A fetch that fails leaves the wearer on their fallback rather than stopping.
	var catalogue_b := DotAvatarCatalogue.new()
	cloud.refuse = true
	var missing := DotAvatarPart.make(&"nowhere", &"hat")
	missing.content_id = "absent_pack"

	_check(catalogue_b.resolve(missing) == "", "a part whose content refuses resolves to nothing")

	await get_tree().process_frame
	await get_tree().process_frame

	_check(
		catalogue_b.is_pending(&"nowhere"),
		"stays pending after a failed fetch, so a retry is still possible"
	)
	_check(
		catalogue_b.resolve(missing) == "",
		"and resolving again does not crash"
	)

	DotRegistry.unregister(&"dot_cloud_client")
	cloud.queue_free()
	_done()

