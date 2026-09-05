@tool
extends EditorScript

## Exports a [DotAvatarSchema] as a WEB avatar manifest plus one GLB per part.
##
## [b]Run it from the editor:[/b] open this file and press [b]File → Run[/b].
## It is an [EditorScript] rather than a headless tool because exporting a scene
## to glTF needs the editor's own [GLTFDocument] importer state, which does not
## exist in a `--headless --script` run.
##
## [b]What it is for.[/b] This addon describes an asset set for a SERVER — a flat
## list of parts, each naming its own scene, so a match can decide whether an
## avatar is legal without holding any art. A web editor needs the same set
## described for a BROWSER: which slots a person picks from, what colours are
## offered, and a file it can actually draw. The two are the same content and
## nobody should be maintaining two copies of it, so this derives the second from
## the first.
##
## The mapping it applies is the exact inverse of the one the website applies to
## come back the other way. If you change one, change both:
## [code]docs/avatar-assets.md[/code] and [code]~/types/avatar/godot.ts[/code] on
## the backbone.
##
## [b]Two things it cannot decide for you[/b], and both are marked TODO in the
## output rather than guessed at:
##
## - [b]The palette.[/b] A part says it has one colour channel; it does not say
##   which colours to offer. A default ramp is written and is meant to be edited
##   — it is the only choice a member has for that slot, so it is a design
##   decision and not a derivation.
## - [b]Whether a part is free.[/b] Everything is exported free, because
##   entitlements are a commerce system this addon deliberately does not have.
##   If your backbone sells cosmetics, that belongs there.

# --- Configure -------------------------------------------------------------

## The schema to export.
const SCHEMA_PATH := "res://content/avatar/humanoid.tres"

## Where the manifest and the GLBs are written.
const OUT_DIR := "res://export/avatar"

## Prefix every emitted URL with this.
##
## Leave empty for paths relative to the manifest, which is what a static host
## serving the whole directory wants — the backbone resolves a relative
## `modelUrl` against the manifest's own address.
const BASE_URL := ""

## Geometry belonging to no slot: the head, the hands, the eyes.
##
## Exported as one `base.glb` and named as the manifest's `modelUrl`. A web
## manifest needs a body to hang parts on and the schema has no concept of one,
## because a server never draws anybody.
const BASE_SCENE_PATH := "res://content/avatar/base.tscn"

## Written onto every slot that has colour channels. Edit afterwards.
const DEFAULT_PALETTE := [
	"#1b1d21", "#33373d", "#8a8f98", "#e5e7eb",
	"#2b4c7e", "#0f766e", "#7a1f2b", "#b45309",
]

# ---------------------------------------------------------------------------

func _run() -> void:
	var schema: DotAvatarSchema = load(SCHEMA_PATH)

	if schema == null:
		push_error("export: no schema at %s" % SCHEMA_PATH)
		return

	var checked := schema.validate_schema()

	if not checked.ok:
		# Refused rather than exported, because a schema this addon would not
		# load at startup is one no game can use — exporting it would produce a
		# manifest that works on the website and nowhere else.
		push_error("export: the schema is not valid — %s" % checked.error.message)
		return

	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(OUT_DIR)):
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(OUT_DIR)
		)

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(OUT_DIR.path_join("parts"))
	)

	var model_url := _export_base()
	var slots: Array = []
	var exported := 0
	var skipped: Array[String] = []

	for slot in schema.ordered_slots():
		var options: Array = []

		for candidate in schema.parts_for(slot.id):
			var part := candidate as DotAvatarPart

			# A retired part is content that still has to RESOLVE — existing
			# documents name it — but must not be offered to somebody choosing.
			# The web manifest has no way to say "resolvable but unlisted", so
			# it is left out and the backbone's coercion handles the documents.
			if part.retired:
				continue

			var option := _export_part(schema, slot, part)

			if option.is_empty():
				skipped.append(String(part.id))
				continue

			options.append(option)
			exported += 1

		slots.append(_slot_dict(schema, slot, options))

	var manifest := {
		"key": String(schema.id),
		"version": schema.version,
		"name": String(schema.id).capitalize(),
		"modelUrl": model_url,
		"docsUrl": null,
		"slots": slots,
	}

	var path := OUT_DIR.path_join("manifest.json")
	var file := FileAccess.open(path, FileAccess.WRITE)

	if file == null:
		push_error("export: could not write %s" % path)
		return

	file.store_string(JSON.stringify(manifest, "  "))
	file.close()

	print("export: wrote %s" % path)
	print("export: %d parts in %d slots" % [exported, slots.size()])

	if not skipped.is_empty():
		# Named, not counted. A part missing from the web set is a part members
		# cannot wear on the site while their game shows it, and "3 skipped" is
		# not something anybody can act on.
		push_warning(
			"export: no scene for %s — these parts are absent from the manifest"
			% ", ".join(skipped)
		)


## Exports everything that belongs to no slot as the manifest's own model.
func _export_base() -> String:
	if not ResourceLoader.exists(BASE_SCENE_PATH):
		push_warning(
			"export: no base scene at %s; the manifest names one anyway, because "
			% BASE_SCENE_PATH
			+ "a manifest with no model is a manifest that renders nothing"
		)
		return _url("base.glb")

	var scene: PackedScene = load(BASE_SCENE_PATH)

	if _write_glb(scene, OUT_DIR.path_join("base.glb")):
		print("export: base.glb")

	return _url("base.glb")


## Exports one part, returning its manifest option — or `{}` if it has no scene.
func _export_part(
	schema: DotAvatarSchema,
	slot: DotAvatarSlot,
	part: DotAvatarPart
) -> Dictionary:
	var option_key := _option_key(slot, part)
	var scene_path := _scene_for(part)

	if scene_path == "":
		return {}

	var scene: PackedScene = load(scene_path)

	if scene == null:
		return {}

	var file_name := "parts/%s.%s.glb" % [String(slot.id), option_key]

	if not _write_glb(scene, OUT_DIR.path_join(file_name)):
		return {}

	return {
		"key": option_key,
		"label": part.display_name if part.display_name != "" else option_key,
		# Empty: the whole file IS this option. That is the shape a one-scene-
		# per-part set has, and it is what stops the manifest having to
		# enumerate the meshes inside somebody's hat.
		"nodes": [],
		"model": _url(file_name),
		"content": part.content_id,
	}


func _slot_dict(
	schema: DotAvatarSchema,
	slot: DotAvatarSlot,
	options: Array
) -> Dictionary:
	var channels := 0

	for candidate in schema.parts_for(slot.id):
		channels = maxi(channels, (candidate as DotAvatarPart).colour_channels)

	var default_option := ""

	if slot.default_part != &"":
		var default_part := schema.part(slot.default_part)
		if default_part != null:
			default_option = _option_key(slot, default_part)

	return {
		"key": String(slot.id),
		"label": (
			slot.display_name if slot.display_name != ""
			else String(slot.id).capitalize()
		),
		"options": options,
		"colorNodes": [],
		# TODO: edit this. See the class documentation — a channel count is not
		# a palette, and the palette is the only choice a member has here.
		"palette": DEFAULT_PALETTE if channels > 0 else [],
		"defOption": default_option if default_option != "" else null,
		"defColor": DEFAULT_PALETTE[0] if channels > 0 else null,
		# The web manifest's `optional` is the inverse of `required`: it asks
		# whether "None" is offered, which is the question the editor renders.
		"optional": not slot.required,
		"layer": slot.layer,
		"attach": String(slot.attachment_name()),
	}


## The option key for a part, which is its id minus the `slot.` prefix.
##
## The backbone builds part ids as `<slot>.<option>`, so stripping the prefix
## here is what makes a round trip land back on the id you started with. A part
## id that does not carry it is used whole, which still round-trips — the
## backbone hashes anything that will not fit and keeps a map either way.
static func _option_key(slot: DotAvatarSlot, part: DotAvatarPart) -> String:
	var id := String(part.id)
	var prefix := "%s." % slot.id

	return id.substr(prefix.length()) if id.begins_with(prefix) else id


## Where a part's scene lives.
##
## `content_id` is an address for dot-cloud, not a `res://` path, so it is only
## usable here when it happens to be one. Otherwise the convention is
## `res://content/avatar/parts/<part id>.tscn`, and a part with neither is
## reported rather than silently dropped.
static func _scene_for(part: DotAvatarPart) -> String:
	if part.content_id.begins_with("res://") and ResourceLoader.exists(part.content_id):
		return part.content_id

	var guess := "res://content/avatar/parts/%s.tscn" % part.id

	return guess if ResourceLoader.exists(guess) else ""


func _write_glb(scene: PackedScene, path: String) -> bool:
	var root := scene.instantiate()

	if root == null:
		return false

	var doc := GLTFDocument.new()
	var state := GLTFState.new()

	var err := doc.append_from_scene(root, state)

	# Freed either way: an EditorScript run leaves its objects in the editor's
	# process, so an early return that skipped this would leak one node per
	# failed part, every run, for as long as the editor is open.
	root.queue_free()

	if err != OK:
		push_error("export: could not read %s (%d)" % [path, err])
		return false

	err = doc.write_to_filesystem(state, path)

	if err != OK:
		push_error("export: could not write %s (%d)" % [path, err])
		return false

	return true


static func _url(file_name: String) -> String:
	return file_name if BASE_URL == "" else "%s/%s" % [BASE_URL.rstrip("/"), file_name]
