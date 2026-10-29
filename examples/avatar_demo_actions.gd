extends RefCounted

## The action keys, the actions loadout and the content cache sections of avatar_demo.
## Counting stays in the host, so every check lands in the one total.

var h: Node = null


func _init(host: Node) -> void:
	h = host


func _test_actions() -> void:
	h._section("actions: loadout")
	var d := DotAvatarActions.defaults()
	h._check(d.equipped(&"emote").size() == 4 and d.equipped(&"pose").size() == 4 and d.equipped(&"gesture").size() == 5,
		"the defaults are the whole starter set, by kind")
	var none := DotAvatarActions.from_backbone(null)
	h._check(none.ok and (none.value as DotAvatarActions).equipped(&"emote").size() == 4, "no actions field reads as the defaults")
	h._check(not DotAvatarActions.from_backbone("x").ok, "a non-object is refused")

	var res := DotAvatarActions.from_backbone({
		"EMOTE": [
			{"builtin": "dance"},
			{"builtin": "wave"},
			{"builtin": "not_yet_shipped"},
			{"builtin": null, "contentId": "action/7/2", "fileUrl": "/file/abc", "clip": "Take", "name": "Moonwalk", "loop": true},
		],
		"POSE": [],
		"GESTURE": [
			{"builtin": null, "contentId": "../../etc/x", "fileUrl": "https://cdn/x", "clip": "a"},
			{"builtin": null, "contentId": "action/8/1", "fileUrl": "//evil.example/x", "clip": "a"},
		],
	})
	if not h._check(res.ok, "a mixed loadout reads"):
		return
	var a: DotAvatarActions = res.value
	var ids := []
	for e: Dictionary in a.equipped(&"emote"):
		ids.append(e["id"])
	h._check(ids == ["dance", "action/7/2"], "built-ins of another kind and unknown ids are dropped", str(ids))
	h._check(a.equipped(&"pose").size() == 4, "an empty kind falls back to its built-ins")
	h._check(a.equipped(&"gesture").size() == 5, "a traversal id and an off-origin url are refused")

	var many := []
	for i in 20:
		many.append({"builtin": "dance"})
	var capped := DotAvatarActions.from_backbone({"EMOTE": many})
	h._check(capped.ok and (capped.value as DotAvatarActions).equipped(&"emote").size() == DotAvatarActions.MAX_EQUIPPED,
		"equipped actions are capped while reading")

	var order := [a.next(&"emote")["id"], a.next(&"emote")["id"], a.next(&"emote")["id"]]
	h._check(order == ["dance", "action/7/2", "dance"], "pressing again cycles", str(order))
	h._check(a.find(&"emote", "wave").is_empty() and a.find(&"gesture", "wave")["builtin"] == true,
		"find answers only within a kind")
	var files := a.files()
	h._check(files.size() == 1 and files[0]["content_id"] == "action/7/2", "only uploaded actions need a file")
	h._check(a.describe_lines().size() == 3, "describe_lines has a line per kind")
	h._done()


class FakeConsole extends RefCounted:
	var commands := {}

	func add_command(name: StringName, _help: String, fn: Callable) -> FakeConsole:
		commands[String(name)] = fn
		return self


func _test_action_input() -> void:
	h._section("actions: keys and commands")
	for kind: StringName in DotAvatarActionInput.BINDINGS:
		var action: StringName = DotAvatarActionInput.BINDINGS[kind]["action"]
		if InputMap.has_action(action):
			InputMap.erase_action(action)
	InputMap.add_action(DotAvatarActionInput.ACTION_POSE)
	var p := InputEventKey.new()
	p.physical_keycode = KEY_P
	InputMap.action_add_event(DotAvatarActionInput.ACTION_POSE, p)
	DotAvatarActionInput.ensure_actions()

	var emote_events := InputMap.action_get_events(DotAvatarActionInput.ACTION_EMOTE)
	h._check(emote_events.size() == 1 and (emote_events[0] as InputEventKey).physical_keycode == KEY_COMMA,
		"the emote key defaults to comma")
	var pose_events := InputMap.action_get_events(DotAvatarActionInput.ACTION_POSE)
	h._check(pose_events.size() == 1 and (pose_events[0] as InputEventKey).physical_keycode == KEY_P,
		"a key bound first is left alone")

	var input := DotAvatarActionInput.new()
	h.add_child(input)
	var got: Array[Dictionary] = []
	input.action_requested.connect(func(e: Dictionary) -> void: got.append(e))
	var press := InputEventKey.new()
	press.physical_keycode = KEY_COMMA
	press.pressed = true
	input._unhandled_input(press)
	h._check(got.size() == 1 and got[0]["id"] == "cheer", "comma plays the first equipped emote")
	var echo := press.duplicate() as InputEventKey
	echo.echo = true
	input._unhandled_input(echo)
	input.enabled = false
	input._unhandled_input(press)
	h._check(got.size() == 1, "a held key and a disabled input play nothing")
	input.enabled = true
	h._check(input.request(&"gesture", "nope").is_empty() and got.size() == 1, "an unknown id plays nothing")

	var console := FakeConsole.new()
	input.register_console(console)
	h._check(console.commands.has("emote") and console.commands.has("pose") and console.commands.has("gesture"),
		"emote, pose and gesture commands are registered")
	var said: Variant = (console.commands["gesture"] as Callable).call(PackedStringArray(["wave"]))
	h._check(said == "gesture wave" and got[-1]["id"] == "wave", "a command plays the action it names")
	var bad: Variant = (console.commands["pose"] as Callable).call(PackedStringArray(["dance"]))
	h._check(bad is DotResult and not (bad as DotResult).ok, "a command naming another kind's action fails")

	input.free()
	for kind: StringName in DotAvatarActionInput.BINDINGS:
		InputMap.erase_action(DotAvatarActionInput.BINDINGS[kind]["action"])
	h._done()


func _test_content_cache() -> void:
	h._section("actions: content cache")
	var cache := DotAvatarContentCache.new()
	cache.directory = "user://test_avatar_content"
	DotPaths.remove_tree(cache.directory)

	h._check(DotAvatarContentCache.is_content_id("avatar/12/3") and DotAvatarContentCache.is_content_id("action/1/1"),
		"site content ids are accepted")
	h._check(not DotAvatarContentCache.is_content_id("avatar/1/../x") and not DotAvatarContentCache.is_content_id("avatar/0/1")
		and not DotAvatarContentCache.is_content_id("../avatar/1/1") and cache.path_for("x/1/1") == "",
		"anything else never becomes a path")

	var root := Node3D.new()
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	root.add_child(mesh)
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	doc.append_from_scene(root, state)
	var glb := doc.generate_buffer(state)
	root.free()

	var row := {"contentId": "avatar/5/1", "size": glb.size(), "sha256": DotHash.sha256_bytes(glb)}
	var wrong_hash := row.duplicate()
	wrong_hash["sha256"] = DotHash.sha256_text("other")
	h._check((cache.store(wrong_hash, glb) as DotResult).error.code == DotError.CODE_INTEGRITY, "a hash mismatch is refused")
	var wrong_size := row.duplicate()
	wrong_size["size"] = glb.size() + 1
	h._check((cache.store(wrong_size, glb) as DotResult).error.code == DotError.CODE_INTEGRITY, "a size mismatch is refused")
	var text := "not a model".to_utf8_buffer()
	var not_glb := {"contentId": "avatar/6/1", "size": text.size(), "sha256": DotHash.sha256_bytes(text)}
	h._check((cache.store(not_glb, text) as DotResult).error.code == DotError.CODE_INVALID, "a file that is not a GLB is refused")
	h._check(not cache.has(row), "nothing is kept after a refusal")

	h._check(cache.store(row, glb).ok and cache.has(row), "a verified GLB is kept")
	var loaded := cache.load_scene("avatar/5/1")
	var has_mesh := loaded.ok and not (loaded.value as Node).find_children("*", "MeshInstance3D", true, false).is_empty()
	h._check(has_mesh, "a kept GLB loads into a scene with its mesh")
	if loaded.ok:
		(loaded.value as Node).free()
	h._check(not cache.load_scene("avatar/9/9").ok, "an id never kept fails to load")

	var tampered := glb.duplicate()
	tampered[tampered.size() - 1] ^= 0xFF
	DotPaths.write_bytes(cache.path_for("avatar/5/1"), tampered)
	h._check(cache.has(row), "a file checked this session is trusted on size alone")
	h._check(not cache.load_scene("avatar/5/1", "0".repeat(64)).ok, "a load with a different hash re-checks and fails")
	DotPaths.write_bytes(cache.path_for("avatar/5/1"), tampered)
	DotAvatarContentCache._verified.clear()
	h._check(not cache.has(row) and not FileAccess.file_exists(cache.path_for("avatar/5/1")),
		"a new session re-hashes a kept file and removes one altered on disk")
	_test_hostile_glbs(cache, glb)

	DotPaths.remove_tree(cache.directory)
	h._done()


## Rebuilds [param glb] with its JSON chunk passed through [param edit].
func _repack(glb: PackedByteArray, edit: Callable) -> PackedByteArray:
	var json_len := int(glb.decode_u32(12))
	var g: Dictionary = JSON.parse_string(glb.slice(20, 20 + json_len).get_string_from_utf8())
	edit.call(g)
	var js := JSON.stringify(g).to_utf8_buffer()
	while js.size() % 4 != 0:
		js.append(0x20)
	var rest := glb.slice(20 + json_len)
	var out := PackedByteArray()
	out.resize(20)
	out.encode_u32(0, 0x46546C67)
	out.encode_u32(4, 2)
	out.encode_u32(8, 20 + js.size() + rest.size())
	out.encode_u32(12, js.size())
	out.encode_u32(16, 0x4E4F534A)
	return out + js + rest


func _test_hostile_glbs(cache: DotAvatarContentCache, glb: PackedByteArray) -> void:
	var refused := func(bytes: PackedByteArray, id: String) -> bool:
		var r := cache.store({"contentId": id, "size": bytes.size(), "sha256": DotHash.sha256_bytes(bytes)}, bytes)
		return not r.ok and r.error.code == DotError.CODE_INVALID and not FileAccess.file_exists(cache.path_for(id))
	h._check(DotAvatarContentCache.check_glb(_repack(glb, func(_g: Dictionary) -> void: pass)).ok, "an untouched repack passes the GLB check")
	h._check(refused.call(_repack(glb, func(g: Dictionary) -> void: g["buffers"][0]["uri"] = "http://evil.test/x.bin"), "avatar/7/1"),
		"a buffer pointing outside the file is refused")
	h._check(refused.call(_repack(glb, func(g: Dictionary) -> void: g["images"] = [{"uri": "file:///etc/passwd"}]), "avatar/7/2"),
		"an image pointing outside the file is refused")
	h._check(refused.call(_repack(glb, func(g: Dictionary) -> void: g["extensionsRequired"] = ["EXT_unknown"]; g["extensionsUsed"] = ["EXT_unknown"]), "avatar/7/3"),
		"an unknown extension is refused")
	var many := func(g: Dictionary) -> void:
		var nodes: Array = g["nodes"]
		for i in DotAvatarContentCache.MAX_NODES:
			nodes.append({})
	h._check(refused.call(_repack(glb, many), "avatar/7/4"), "a node count past the cap is refused")
	h._check(refused.call(_repack(glb, func(g: Dictionary) -> void: g["accessors"][0]["count"] = 900_000_000), "avatar/7/5"),
		"an absurd accessor count is refused")
	h._check(refused.call(glb + PackedByteArray([0, 0, 0, 0]), "avatar/7/6"),
		"a GLB whose header length disagrees with its size is refused")
	var camera := func(g: Dictionary) -> void:
		g["cameras"] = [{"type": "perspective", "perspective": {"yfov": 1.0, "znear": 0.1}}]
		(g["nodes"] as Array).append({"name": "Spy", "camera": 0})
		(g["scenes"][0]["nodes"] as Array).append((g["nodes"] as Array).size() - 1)
	var cam := _repack(glb, camera)
	h._check(refused.call(cam, "wearable/7/7"), "a wearable carrying a camera is refused")
	var cam_row := {"contentId": "avatar/7/8", "size": cam.size(), "sha256": DotHash.sha256_bytes(cam)}
	var kept := cache.store(cam_row, cam)
	var scene := cache.load_scene("avatar/7/8") if kept.ok else kept
	h._check(scene.ok and (scene.value as Node).find_children("*", "Camera3D", true, false).is_empty()
		and not (scene.value as Node).find_children("*", "MeshInstance3D", true, false).is_empty(),
		"an avatar's camera is dropped and its mesh kept")
	if scene.ok:
		(scene.value as Node).free()
