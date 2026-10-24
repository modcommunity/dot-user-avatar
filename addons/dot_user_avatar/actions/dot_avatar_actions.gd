class_name DotAvatarActions
extends RefCounted

## A player's equipped emotes, poses and gestures, as the backbone's [code]actions[/code] field
## delivers them, plus the built-in starter set every avatar can play without a download.
##
## [codeblock]
## var res := DotAvatarActions.from_backbone(avatar_read["actions"])
## var actions: DotAvatarActions = res.value if res.ok else DotAvatarActions.defaults()
## var entry := actions.next(&"emote")   # the next equipped emote, cycling
## [/codeblock]
##
## Data only: playing an entry is the figure's job (dot-player-char), reached through
## [signal DotAvatarActionInput.action_requested].

const CHANNEL := "avatar.actions"

const EMOTE := &"emote"
const POSE := &"pose"
const GESTURE := &"gesture"
const KINDS: Array[StringName] = [EMOTE, POSE, GESTURE]

## The site's cap per kind (AVATAR_ACTION_EQUIP_MAX); anything past it is dropped while reading.
const MAX_EQUIPPED := 8

## The starter set, by the ids the site's BUILTIN_AVATAR_ACTIONS uses. Add, never rename.
const BUILTIN := {
	"wave": {"kind": GESTURE, "name": "Wave", "loop": false},
	"point": {"kind": GESTURE, "name": "Point", "loop": false},
	"thumbs_up": {"kind": GESTURE, "name": "Thumbs up", "loop": false},
	"nod": {"kind": GESTURE, "name": "Nod", "loop": false},
	"shrug": {"kind": GESTURE, "name": "Shrug", "loop": false},
	"cheer": {"kind": EMOTE, "name": "Cheer", "loop": false},
	"dance": {"kind": EMOTE, "name": "Dance", "loop": true},
	"clap": {"kind": EMOTE, "name": "Clap", "loop": true},
	"bow": {"kind": EMOTE, "name": "Bow", "loop": false},
	"sit": {"kind": POSE, "name": "Sit", "loop": true},
	"salute": {"kind": POSE, "name": "Salute", "loop": true},
	"arms_crossed": {"kind": POSE, "name": "Arms crossed", "loop": true},
	"hands_on_hips": {"kind": POSE, "name": "Hands on hips", "loop": true},
}

const _MAX_NAME := 64
const _MAX_CLIP := 64

var _equipped := {}
var _cursor := {}


func _init() -> void:
	for kind in KINDS:
		_equipped[kind] = []
		_cursor[kind] = 0


## Every built-in, in table order, as the loadout of somebody who equipped nothing.
static func defaults() -> DotAvatarActions:
	var out := DotAvatarActions.new()
	for id: String in BUILTIN:
		var kind: StringName = BUILTIN[id]["kind"]
		out._equipped[kind].append(builtin_entry(id))
	return out


## The entry for a built-in id, or an empty dictionary for an unknown one.
static func builtin_entry(id: String) -> Dictionary:
	if not BUILTIN.has(id):
		return {}
	var row: Dictionary = BUILTIN[id]
	return {
		"id": id, "kind": row["kind"], "name": row["name"], "builtin": true,
		"loop": row["loop"], "clip": "", "url": "", "content_id": "",
	}


## Reads the backbone's [code]{ EMOTE: [...], POSE: [...], GESTURE: [...] }[/code]. A malformed
## entry is dropped rather than failing the whole loadout; a non-dictionary is [code]parse[/code].
## A kind left empty gets the built-ins of that kind, as the site does.
static func from_backbone(actions: Variant) -> DotResult:
	if actions == null:
		return DotResult.success(defaults())
	if not actions is Dictionary:
		return DotResult.fail(DotError.CODE_PARSE, "avatar actions are not an object")

	var out := DotAvatarActions.new()
	var dropped := 0
	for kind in KINDS:
		var rows: Variant = (actions as Dictionary).get(String(kind).to_upper(), [])
		if not rows is Array:
			dropped += 1
			continue
		for row: Variant in rows:
			if out._equipped[kind].size() >= MAX_EQUIPPED:
				dropped += 1
				break
			var entry := _read_entry(row, kind)
			if entry.is_empty():
				dropped += 1
				continue
			out._equipped[kind].append(entry)

	var fallback := defaults()
	for kind in KINDS:
		if out._equipped[kind].is_empty():
			out._equipped[kind] = fallback._equipped[kind].duplicate()
	if dropped > 0:
		DotLog.debug(CHANNEL, "dropped %d unusable action entries" % dropped)
	return DotResult.success(out)


static func _read_entry(row: Variant, kind: StringName) -> Dictionary:
	if not row is Dictionary:
		return {}
	var d: Dictionary = row
	if d.get("builtin") is String:
		# An id this build does not know comes from a newer site; skip it, never guess.
		var entry := builtin_entry(d["builtin"])
		return entry if not entry.is_empty() and entry["kind"] == kind else {}

	var content_id: Variant = d.get("contentId")
	var url: Variant = d.get("fileUrl")
	var clip: Variant = d.get("clip")
	if not (content_id is String and DotAvatarContentCache.is_content_id(content_id)):
		return {}
	if not (url is String and _is_file_url(url)):
		return {}
	if not (clip is String and not (clip as String).is_empty() and (clip as String).length() <= _MAX_CLIP):
		return {}
	var name := String(d.get("name", "")) if d.get("name") is String else ""
	return {
		"id": content_id, "kind": kind, "name": name.substr(0, _MAX_NAME), "builtin": false,
		"loop": d.get("loop") == true, "clip": clip, "url": url, "content_id": content_id,
	}


## A CDN url, or a private file's site-relative path the fetcher resolves against the backbone.
## "//host" is refused: it would leave the backbone's origin.
static func _is_file_url(url: String) -> bool:
	if url.begins_with("https://"):
		return true
	return url.begins_with("/") and not url.begins_with("//") and not url.contains("..")


## The equipped entries of one kind, in key order. A copy.
func equipped(kind: StringName) -> Array:
	return (_equipped.get(kind, []) as Array).duplicate(true)


## The entry the key plays now, advancing so the next press plays the one after. Empty when
## nothing of that kind is equipped.
func next(kind: StringName) -> Dictionary:
	var list: Array = _equipped.get(kind, [])
	if list.is_empty():
		return {}
	var i: int = _cursor[kind] % list.size()
	_cursor[kind] = i + 1
	return list[i]


## An equipped entry of [param kind] by id, else the built-in of that id and kind; empty if neither.
func find(kind: StringName, id: String) -> Dictionary:
	for entry: Dictionary in _equipped.get(kind, []):
		if entry["id"] == id:
			return entry
	var b := builtin_entry(id)
	return b if not b.is_empty() and b["kind"] == kind else {}


## Every file a client must fetch before these can play: one row per distinct content id.
func files() -> Array[Dictionary]:
	var seen := {}
	var out: Array[Dictionary] = []
	for kind in KINDS:
		for entry: Dictionary in _equipped[kind]:
			if entry["builtin"] or seen.has(entry["content_id"]):
				continue
			seen[entry["content_id"]] = true
			out.append({"content_id": entry["content_id"], "url": entry["url"]})
	return out


func describe() -> Dictionary:
	var counts := {}
	for kind in KINDS:
		counts[kind] = _equipped[kind].size()
	return {"equipped": counts, "files": files().size()}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	for kind in KINDS:
		var ids := PackedStringArray()
		for entry: Dictionary in _equipped[kind]:
			ids.append(entry["id"])
		lines.append("%s: %s" % [kind, ", ".join(ids) if not ids.is_empty() else "-"])
	return lines
