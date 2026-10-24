extends Node

## DotAvatarWearables, offline: slot and bone tables, offset clamping, bone resolution across rigs,
## hanging real GLBs from the content cache, and the backbone read.
## godot --headless --path . res://examples/avatar_wearables.tscn

const SECTIONS := 6
const CHECKS := 54

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0


class FakeHttp extends DotHttp:
	var body: Variant = {}
	var status := 200

	func get_json(_path: String, _headers: Dictionary = {}) -> DotResult:
		if status != 200:
			return DotResult.failure(DotError.from_http(status))
		return DotResult.success(body)


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("dot-user-avatar wearables self-test")
	_test_tables()
	_test_offsets()
	_test_bones()
	await _test_apply()
	_test_cache()
	await _test_read()
	_check(_completed == _entered and _entered == SECTIONS, "every section ran (%d of %d)" % [_completed, SECTIONS])
	_check(_passed + _failed + 1 == CHECKS, "every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS])
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print(title)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		printerr("  FAIL %s %s" % [what, detail])


func _skeleton(names: Array) -> Skeleton3D:
	var s := Skeleton3D.new()
	for n in names:
		var i := s.add_bone(n)
		if i > 0:
			s.set_bone_parent(i, 0)
		s.set_bone_rest(i, Transform3D(Basis.IDENTITY, Vector3(0, 0.1 * i, 0)))
	add_child(s)
	return s


func _cube() -> Node3D:
	var m := MeshInstance3D.new()
	m.name = "Cube"
	m.mesh = BoxMesh.new()
	return m


func _test_tables() -> void:
	_section("slots and bones")
	_check(DotAvatarWearables.SLOT_BONES.size() == 7, "seven slots, as on the site")
	_check(DotAvatarWearables.is_slot("hat") and not DotAvatarWearables.is_slot("tail"), "is_slot")
	_check(DotAvatarWearables.bone_allowed("back", "Spine"), "back may hang on Spine")
	_check(not DotAvatarWearables.bone_allowed("hat", "RightHand"), "a hat may not hang on a hand")
	var r := DotAvatarWearables.check_row({"slot": "neck", "bone": ""})
	_check(r.ok and r.value["bone"] == "Neck", "an empty bone takes the slot's default")
	_check(not DotAvatarWearables.check_row({"slot": "hat", "bone": "LeftHand"}).ok, "a disallowed bone is refused")
	_check(not DotAvatarWearables.check_row("hat").ok, "a non-object row is refused")
	_completed += 1


func _test_offsets() -> void:
	_section("offsets clamp like the site's")
	var o := DotAvatarWearables.clamp_offset({"position": [9, -9, 0.12345678], "rotation": [720, 0, -45], "scale": 50})
	_check(o["position"] == Vector3(0.5, -0.5, 0.1235), "position clamps to 0.5 m and four decimals", str(o["position"]))
	_check(o["rotation"] == Vector3(180, 0, -45), "rotation clamps to 180 degrees", str(o["rotation"]))
	_check(is_equal_approx(o["scale"], 2.0), "scale clamps to 2")
	var d := DotAvatarWearables.clamp_offset(null)
	_check(d["position"] == Vector3.ZERO and d["rotation"] == Vector3.ZERO and d["scale"] == 1.0, "null is the identity")
	var bad := DotAvatarWearables.clamp_offset({"position": ["x", NAN, INF], "scale": "big"})
	_check(bad["position"] == Vector3(0, 0, 0.5) or bad["position"] == Vector3.ZERO, "strings and NaN become 0", str(bad["position"]))
	_check(bad["scale"] == 1.0, "a string scale is 1")
	_check(is_equal_approx(DotAvatarWearables.clamp_offset({"scale": 0.01})["scale"], 0.25), "scale floors at 0.25")
	var t := DotAvatarWearables.offset_transform({"position": [0, 0.1, 0], "rotation": [0, 90, 0], "scale": 2})
	_check(t.origin.is_equal_approx(Vector3(0, 0.1, 0)), "transform origin is the offset")
	_check(is_equal_approx(t.basis.get_scale().x, 2.0), "transform carries the scale")
	_check((t.basis.orthonormalized() * Vector3.FORWARD).is_equal_approx(Vector3.LEFT), "rotation is degrees about Y")
	_completed += 1


func _test_bones() -> void:
	_section("bone resolution across rigs")
	var profile := _skeleton(["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head", "RightHand", "LeftHand"])
	_check(DotAvatarWearables.resolve_bone(profile, "Head") == 5, "profile names resolve directly")
	var figure := _skeleton(["Body", "Hips", "Abdomen", "Torso", "Neck", "Head", "Wrist.R", "Middle1.R", "Middle1.L"])
	_check(figure.get_bone_name(DotAvatarWearables.resolve_bone(figure, "UpperChest")) == "Torso", "UpperChest falls back to Torso")
	_check(figure.get_bone_name(DotAvatarWearables.resolve_bone(figure, "RightHand")) == "Wrist.R", "RightHand prefers Wrist.R over a finger")
	_check(figure.get_bone_name(DotAvatarWearables.resolve_bone(figure, "LeftHand")) == "Middle1.L", "LeftHand falls back to a finger")
	_check(figure.get_bone_name(DotAvatarWearables.resolve_bone(figure, "Hips")) == "Hips", "the profile name beats an alias")
	var prefixed := _skeleton(["mixamorig_Hips", "mixamorig_Head", "mixamorig_RightHand"])
	_check(prefixed.get_bone_name(DotAvatarWearables.resolve_bone(prefixed, "Head")) == "mixamorig_Head", "a rig prefix is ignored")
	_check(prefixed.get_bone_name(DotAvatarWearables.resolve_bone(prefixed, "RightHand")) == "mixamorig_RightHand", "prefixed hand")
	_check(DotAvatarWearables.resolve_bone(prefixed, "Neck") == -1, "a missing bone is -1")
	_check(DotAvatarWearables.resolve_bone(null, "Head") == -1, "no skeleton is -1")
	for s in [profile, figure, prefixed]:
		s.queue_free()
	_completed += 1


func _test_apply() -> void:
	_section("apply hangs one per slot")
	var sk := _skeleton(["Hips", "Spine", "Chest", "UpperChest", "Neck", "Head", "RightHand", "LeftHand"])
	var w := DotAvatarWearables.new()
	var loads := []
	w.scene_fn = func(row: Dictionary) -> DotResult:
		loads.append(row["id"])
		if row["id"] == 99:
			return DotResult.fail(DotError.CODE_INVALID, "not cached")
		return DotResult.success(_cube())
	var rows := [
		{"id": 1, "slot": "hat", "bone": "Head", "offset": {"position": [0, 0.2, 0], "rotation": [0, 0, 0], "scale": 1.5}},
		{"id": 2, "slot": "hat", "bone": "Head"},
		{"id": 3, "slot": "hand_right", "bone": "RightHand"},
		{"id": 4, "slot": "hat", "bone": "LeftHand"},
		{"id": 5, "slot": "tail"},
		{"id": 99, "slot": "back", "bone": "Spine"},
		"junk",
	]
	var res := w.apply(sk, rows)
	_check(res.ok and res.value == 2, "two of seven rows hang", str(res.value))
	var hat := w.mount_for("hat")
	_check(hat != null and hat.get_parent() == sk, "the hat's mount is under the skeleton")
	_check(hat != null and hat.bone_name == "Head", "the hat hangs on Head")
	_check(hat != null and hat.name == "Wearable_hat", "mounts are named by slot")
	var model: Node3D = hat.get_child(0) if hat != null and hat.get_child_count() > 0 else null
	_check(model != null and model.position.is_equal_approx(Vector3(0, 0.2, 0)), "the offset places the model", str(model.position if model else null))
	_check(model != null and is_equal_approx(model.scale.x, 1.5), "the offset scales the model")
	_check(not loads.has(2), "the second hat is never loaded")
	_check(w.mount_for("back") == null, "a load failure hangs nothing")
	_check(w.describe()["worn"].has("hand_right") and w.describe()["source"] == "scene_fn", "describe lists what is worn")
	var again := w.apply(sk, [{"id": 7, "slot": "face", "bone": "Head"}])
	_check(again.ok and again.value == 1 and w.mount_for("hat") == null, "apply replaces what was hung")
	await get_tree().process_frame
	_check(sk.get_children().filter(func(n: Node) -> bool: return n.name.begins_with("Wearable_")).size() == 1, "old mounts are freed")
	var bare := DotAvatarWearables.new()
	_check(bare.apply(sk, [{"id": 8, "slot": "hat"}]).value == 0, "no content source hangs nothing")
	_check(not w.apply(null, rows).ok, "no skeleton fails")
	sk.queue_free()
	_completed += 1


func _test_cache() -> void:
	_section("real GLBs through the content cache")
	_check(DotAvatarContentCache.is_content_id("wearable/12/3"), "wearable content ids are accepted")
	_check(not DotAvatarContentCache.is_content_id("wearable/../3"), "a traversal is refused")
	var index := DotAvatarContentFetcher.index_library({"wearables": [{"contentId": "wearable/1/1", "url": "https://x/a.glb"}]})
	_check(index.has("wearable/1/1"), "the fetcher indexes the library's wearables")

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var src := Node3D.new()
	src.add_child(_cube())
	src.get_child(0).owner = src
	_check(doc.append_from_scene(src, state) == OK, "a cube exports to glTF")
	var bytes := doc.generate_buffer(state)
	src.free()
	var cache := DotAvatarContentCache.new()
	cache.directory = "user://avatar_wearables_test"
	var row := {"contentId": "wearable/5/1", "size": bytes.size(), "sha256": DotHash.sha256_bytes(bytes)}
	_check(cache.store(row, bytes).ok, "the cache keeps a verified wearable")
	var sk := _skeleton(["Hips", "Head"])
	var w := DotAvatarWearables.new()
	w.cache = cache
	var res := w.apply(sk, [{"id": 5, "slot": "hat", "bone": "Head", "contentId": "wearable/5/1"}])
	_check(res.ok and res.value == 1, "a cached GLB hangs on the head")
	var mount := w.mount_for("hat")
	_check(mount != null and mount.get_child(0).find_children("*", "MeshInstance3D", true, false).size() + int(mount.get_child(0) is MeshInstance3D) >= 1, "the hung scene has its mesh")
	_check(w.apply(sk, [{"id": 6, "slot": "hat", "contentId": "wearable/6/1"}]).value == 0, "an uncached id hangs nothing")
	w.clear()
	sk.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(cache.path_for("wearable/5/1")))
	_completed += 1


func _test_read() -> void:
	_section("the backbone read")
	var http := FakeHttp.new()
	add_child(http)
	http.body = {"actions": {}, "wearables": [{"id": 1, "slot": "hat", "bone": "Head", "contentId": "wearable/1/1"}]}
	var res: DotResult = await DotAvatarSync.fetch_wearables(http, "5b487068db25649711f46d")
	_check(res.ok and res.value is Array and res.value.size() == 1, "wearables come back as rows", str(res.value) + (res.error.message if not res.ok else ""))
	http.body = {"actions": {}}
	res = await DotAvatarSync.fetch_wearables(http, "5b487068db25649711f46d")
	_check(res.ok and res.value == [], "an older site without wearables reads as none")
	http.status = 404
	res = await DotAvatarSync.fetch_wearables(http, "5b487068db25649711f46d")
	_check(res.ok and res.value == null, "no player is null")
	http.status = 500
	_check(not (await DotAvatarSync.fetch_wearables(http, "5b487068db25649711f46d")).ok, "a server error fails")
	_check(not (await DotAvatarSync.fetch_wearables(http, "bad key!")).ok, "a bad key is refused")
	http.queue_free()
	_completed += 1
