class_name DotAvatarBuilder
extends RefCounted

## Applies an avatar document to a character rig.
## Split into plan and application: [method plan] is pure logic over ids with no scene, so the self-test exercises it headless;
## [method apply] instantiates scenes and reparents nodes.

const CHANNEL := "avatar.builder"


## One slot's worth of work.
class Step extends RefCounted:
	var slot: StringName
	## The part the document asked for.
	var requested: StringName
	## What will actually be shown: the request, a fallback, or nothing.
	var resolved: DotAvatarPart = null
	var scene_path: String = ""
	var colours: Array = []
	var attach_to: StringName
	var layer: int = 50

	## The requested part was unavailable and something else is standing in.
	var substituted: bool = false

	## Nothing in the fallback chain resolved. The caller shows a placeholder.
	var missing: bool = false

	func describe() -> Dictionary:
		return {
			"slot": String(slot),
			"requested": String(requested),
			"shown": String(resolved.id) if resolved != null else "<placeholder>",
			"substituted": substituted,
			"missing": missing,
		}


## Works out what to build, touching no nodes.
## Slots hidden by another slot's [member DotAvatarSlot.hides] are dropped here so a caller counting steps sees what will appear.
static func plan(
	avatar: DotAvatar,
	schema: DotAvatarSchema,
	catalogue: DotAvatarCatalogue
) -> Array[Step]:
	var steps: Array[Step] = []

	if avatar == null or schema == null:
		return steps

	var hidden := {}

	for slot_id in avatar.filled_slots():
		var slot := schema.slot(slot_id)
		if slot == null:
			continue
		for other in slot.hides:
			hidden[other] = true

	for slot in schema.ordered_slots():
		if hidden.has(slot.id) or not avatar.has_slot(slot.id):
			continue

		var requested_id := avatar.part_in(slot.id)
		var requested := schema.part(requested_id)

		if requested == null:
			# The document named a part the schema does not have. conform() would
			# normally have removed it; reaching here means this was built from an
			# unconformed document, so it is skipped rather than crashing.
			continue

		var step := Step.new()
		step.slot = slot.id
		step.requested = requested_id
		step.attach_to = slot.attachment_name()
		step.layer = slot.layer
		step.colours = avatar.colours.get(slot.id, [])

		var shown := (
			catalogue.resolve_with_fallback(requested, schema)
			if catalogue != null else null
		)

		if shown == null:
			step.missing = true
		else:
			step.resolved = shown
			step.scene_path = catalogue.resolve(shown)
			step.substituted = shown.id != requested_id

		steps.append(step)

	return steps


## Builds the plan under [param rig].
## Every slot's node is cleared and rebuilt, so applying a second avatar to a rig is well defined (the editor does it several times a second).
## Returns how many slots were shown; missing content contributes the placeholder if one is supplied.
static func apply(
	steps: Array[Step],
	rig: Node3D,
	placeholder: PackedScene = null
) -> DotResult:
	if rig == null:
		return DotResult.fail(DotError.CODE_INVALID, "No rig to build on.")

	var shown := 0

	for step in steps:
		var mount := rig.get_node_or_null(NodePath(String(step.attach_to)))

		if mount == null:
			# A slot with nowhere to attach is a mismatch between the schema and the
			# rig, which is a content problem and worth naming rather than skipping.
			DotLog.warn(
				CHANNEL,
				"the rig has no attachment for a slot",
				{"slot": String(step.slot), "expected_node": String(step.attach_to)}
			)
			continue

		for child in mount.get_children():
			child.queue_free()

		var scene: PackedScene = null

		if step.scene_path != "" and ResourceLoader.exists(step.scene_path):
			scene = load(step.scene_path) as PackedScene

		if scene == null:
			scene = placeholder

		if scene == null:
			continue

		var instance := scene.instantiate()
		mount.add_child(instance)

		_tint(instance, step.colours)
		shown += 1

	return DotResult.success(shown)


## Applies a slot's colours to whatever the part instantiated.
## Written to shader parameters, not by swapping materials, so one mesh with three regions needs one material and two wearers do not share (and recolour) a loaded [Resource].
static func _tint(instance: Node, colours: Array) -> void:
	if colours.is_empty():
		return

	for i in range(colours.size()):
		var colour: Color = colours[i]
		_tint_recursive(instance, i, colour)


static func _tint_recursive(node: Node, channel: int, colour: Color) -> void:
	if node is GeometryInstance3D:
		# set_instance_shader_parameter is per-instance, so it cannot leak between
		# two players wearing the same part.
		(node as GeometryInstance3D).set_instance_shader_parameter(
			"dot_avatar_tint_%d" % channel, colour
		)

	for child in node.get_children():
		_tint_recursive(child, channel, colour)


## The same plan as plain dictionaries, for dot-player-char to build.
## The planner stays here so a server validates from ids without a rendering addon; [code]DotPlayerModelBuilder.from_plan[/code] consumes this and neither addon imports the other.
## [method apply] still works for a game with only this addon; usage in docs/integration.md.
static func plan_dicts(steps: Array[Step]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	for step in steps:
		out.append({
			"slot": step.slot,
			"attach_to": String(step.attach_to),
			"requested": step.requested,
			"part": step.resolved.id if step.resolved != null else step.requested,
			"scene_path": step.scene_path,
			"colours": step.colours.duplicate(),
			"layer": step.layer,
			"missing": step.missing,
			"substituted": step.substituted,
		})

	return out


## Summarises a plan for a loading indicator or a bug report.
static func summarise(steps: Array[Step]) -> Dictionary:
	var substituted := 0
	var missing := 0

	for step in steps:
		if step.substituted:
			substituted += 1
		if step.missing:
			missing += 1

	return {
		"slots": steps.size(),
		"substituted": substituted,
		"missing": missing,
		"complete": substituted == 0 and missing == 0,
	}
