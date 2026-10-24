class_name DotAvatarWearables
extends RefCounted

## Hangs a player's equipped wearables (rigid GLBs from the site) on their figure's bones, one
## [BoneAttachment3D] per slot under the [Skeleton3D].
##
## [codeblock]
## var wearables := DotAvatarWearables.new()
## wearables.cache = content_cache            # the files the fetcher verified before connecting
## var res := wearables.apply(skeleton, rows) # rows: the backbone read's "wearables"
## [/codeblock]
##
## Rows are untrusted: slot, bone and offset are checked against the same tables the site uses
## ([code]src/types/avatar/wearables.ts[/code]), so a hand-edited row cannot hang a 50 m hat.

const CHANNEL := "avatar.wearables"

## Slot to the bones it may hang on, the default first. Humanoid profile names, as on the site.
const SLOT_BONES := {
	"hat": ["Head"],
	"face": ["Head"],
	"neck": ["Neck", "UpperChest"],
	"back": ["UpperChest", "Chest", "Spine"],
	"waist": ["Hips"],
	"hand_right": ["RightHand"],
	"hand_left": ["LeftHand"],
}

const POSITION_LIMIT := 0.5
const ROTATION_LIMIT := 180.0
const SCALE_MIN := 0.25
const SCALE_MAX := 2.0

## Names other rigs use for a humanoid bone, tried in order after the profile name itself.
## The built-in figure's names come first after it.
const BONE_ALIASES := {
	"Head": ["head"],
	"Neck": ["neck"],
	"UpperChest": ["Torso", "Spine2", "Chest", "spine_03"],
	"Chest": ["Torso", "Spine1", "spine_02"],
	"Spine": ["Abdomen", "spine_01"],
	"Hips": ["Body", "pelvis", "Root"],
	"RightHand": ["Hand.R", "hand.R", "Wrist.R", "hand_r", "Middle1.R"],
	"LeftHand": ["Hand.L", "hand.L", "Wrist.L", "hand_l", "Middle1.L"],
}

const NODE_PREFIX := "Wearable_"

## Where the files come from: a [DotAvatarContentCache] (anything with [code]load_scene(id)[/code]).
var cache: Object = null
## Overrides [member cache]: [code]func(row: Dictionary) -> DotResult[/code] of a [Node3D].
var scene_fn: Callable

var _applied := {}


static func is_slot(slot: String) -> bool:
	return SLOT_BONES.has(slot)


static func bone_allowed(slot: String, bone: String) -> bool:
	return SLOT_BONES.has(slot) and (SLOT_BONES[slot] as Array).has(bone)


## Any offset made safe: finite, within the site's limits. Never fails, like the site's ClampWearableOffset.
static func clamp_offset(raw: Variant) -> Dictionary:
	var o: Dictionary = raw if raw is Dictionary else {}
	return {
		"position": _vec(o.get("position"), POSITION_LIMIT),
		"rotation": _vec(o.get("rotation"), ROTATION_LIMIT),
		"scale": _num(o.get("scale"), SCALE_MIN, SCALE_MAX, 1.0),
	}


## The offset as a transform relative to the bone; rotation is degrees, XYZ Euler.
static func offset_transform(offset: Dictionary) -> Transform3D:
	var o := clamp_offset(offset)
	var r: Vector3 = o["rotation"]
	var basis := Basis.from_euler(Vector3(deg_to_rad(r.x), deg_to_rad(r.y), deg_to_rad(r.z))).scaled(Vector3.ONE * float(o["scale"]))
	return Transform3D(basis, o["position"])


## The index of [param bone] in [param skeleton]: the profile name, then [constant BONE_ALIASES],
## each also matched case-insensitively, with or without a rig prefix ([code]mixamorig_Head[/code]). -1 when none fits.
static func resolve_bone(skeleton: Skeleton3D, bone: String) -> int:
	if skeleton == null:
		return -1
	var names: Array = [bone]
	names.append_array(BONE_ALIASES.get(bone, []))
	for n in names:
		var i := skeleton.find_bone(n)
		if i >= 0:
			return i
	var wanted := {}
	for n in names:
		wanted[String(n).to_lower()] = true
	for i in skeleton.get_bone_count():
		var full := skeleton.get_bone_name(i).to_lower()
		if wanted.has(full) or (full.contains("_") and wanted.has(full.substr(full.find("_") + 1))):
			return i
	return -1


## Checks one wire row; the returned row has a known slot, an allowed bone and a clamped offset.
static func check_row(row: Variant) -> DotResult:
	if not row is Dictionary:
		return DotResult.fail(DotError.CODE_INVALID, "wearable row is not an object")
	var slot := String(row.get("slot", ""))
	if not is_slot(slot):
		return DotResult.fail(DotError.CODE_INVALID, "unknown wearable slot", slot)
	var bone := String(row.get("bone", ""))
	if bone == "":
		bone = SLOT_BONES[slot][0]
	if not bone_allowed(slot, bone):
		return DotResult.fail(DotError.CODE_INVALID, "bone not allowed for slot %s" % slot, bone)
	var out: Dictionary = (row as Dictionary).duplicate()
	out["slot"] = slot
	out["bone"] = bone
	out["offset"] = clamp_offset(row.get("offset"))
	return DotResult.success(out)


## Replaces whatever this hung before with [param rows], at most one per slot (the first wins).
## Succeeds with the number hung; a row that cannot be hung is skipped and logged, never fatal.
func apply(skeleton: Skeleton3D, rows: Array) -> DotResult:
	clear()
	if skeleton == null or not is_instance_valid(skeleton):
		return DotResult.fail(DotError.CODE_STATE, "no skeleton to hang wearables on")
	for raw in rows:
		var checked := check_row(raw)
		if not checked.ok:
			DotLog.warn(CHANNEL, "skipped a wearable: %s" % checked.error.message)
			continue
		var row: Dictionary = checked.value
		if _applied.has(row["slot"]):
			continue
		var index := resolve_bone(skeleton, row["bone"])
		if index < 0:
			DotLog.debug(CHANNEL, "skeleton has no %s bone; %s not worn" % [row["bone"], row["slot"]])
			continue
		var scene := _scene_for(row)
		if not scene.ok:
			DotLog.warn(CHANNEL, "wearable %s not loaded: %s" % [row.get("contentId", "?"), scene.error.message])
			continue
		var mount := BoneAttachment3D.new()
		mount.name = NODE_PREFIX + String(row["slot"])
		skeleton.add_child(mount)
		mount.bone_name = skeleton.get_bone_name(index)
		var model: Node3D = scene.value
		model.transform = offset_transform(row["offset"])
		mount.add_child(model)
		_applied[row["slot"]] = {"mount": mount, "id": row.get("id"), "bone": mount.bone_name}
	DotLog.debug(CHANNEL, "hung %d wearable(s)" % _applied.size())
	return DotResult.success(_applied.size())


## Removes everything [method apply] hung.
func clear() -> void:
	for slot in _applied:
		var mount: Node = _applied[slot]["mount"]
		if is_instance_valid(mount):
			mount.get_parent().remove_child(mount)
			mount.queue_free()
	_applied.clear()


## The mount for [param slot], or null.
func mount_for(slot: String) -> BoneAttachment3D:
	var entry: Variant = _applied.get(slot)
	if entry == null or not is_instance_valid(entry["mount"]):
		return null
	return entry["mount"]


func describe() -> Dictionary:
	var worn := {}
	for slot in _applied:
		worn[slot] = {"id": _applied[slot]["id"], "bone": _applied[slot]["bone"]}
	return {"worn": worn, "source": "scene_fn" if scene_fn.is_valid() else ("cache" if cache != null else "none")}


func _scene_for(row: Dictionary) -> DotResult:
	var res: Variant = null
	if scene_fn.is_valid():
		res = scene_fn.call(row)
	elif cache != null and cache.has_method("load_scene"):
		res = cache.call("load_scene", String(row.get("contentId", "")))
	else:
		return DotResult.fail(DotError.CODE_STATE, "no content source")
	if not res is DotResult:
		return DotResult.fail(DotError.CODE_STATE, "content source returned no result")
	if res.ok and not res.value is Node3D:
		if res.value is Node:
			res.value.free()
		return DotResult.fail(DotError.CODE_INVALID, "wearable content is not a 3D scene")
	return res


static func _num(v: Variant, lo: float, hi: float, dflt: float) -> float:
	var n: float = float(v) if (v is float or v is int) else dflt
	if is_nan(n) or is_inf(n):
		n = dflt
	return snappedf(clampf(n, lo, hi), 0.0001)


static func _vec(v: Variant, lim: float) -> Vector3:
	var a: Array = [v.x, v.y, v.z] if v is Vector3 else (v if v is Array else [])
	return Vector3(
		_num(a[0] if a.size() > 0 else 0.0, -lim, lim, 0.0),
		_num(a[1] if a.size() > 1 else 0.0, -lim, lim, 0.0),
		_num(a[2] if a.size() > 2 else 0.0, -lim, lim, 0.0))
