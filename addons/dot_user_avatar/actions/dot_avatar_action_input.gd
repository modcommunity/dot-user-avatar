class_name DotAvatarActionInput
extends Node

## The emote, pose and gesture keys (`,` `.` `/` by default) and console commands. Each press asks for
## the next equipped action of that kind; the game plays it from [signal action_requested].

const CHANNEL := "avatar.actions"

const ACTION_EMOTE := &"dot_avatar_emote"
const ACTION_POSE := &"dot_avatar_pose"
const ACTION_GESTURE := &"dot_avatar_gesture"

## Kind to input action and default physical key; the site shows the same keys.
const BINDINGS := {
	DotAvatarActions.EMOTE: {"action": ACTION_EMOTE, "key": KEY_COMMA},
	DotAvatarActions.POSE: {"action": ACTION_POSE, "key": KEY_PERIOD},
	DotAvatarActions.GESTURE: {"action": ACTION_GESTURE, "key": KEY_SLASH},
}

## One entry of [DotAvatarActions] to play: id, kind, name, builtin, loop, clip, content_id.
signal action_requested(entry: Dictionary)

var actions: DotAvatarActions = DotAvatarActions.defaults()

## False while a text field or menu has the keyboard; the game owns that decision.
var enabled := true


## Creates each action on its default key unless something has already defined it.
static func ensure_actions() -> void:
	for kind: StringName in BINDINGS:
		var action: StringName = BINDINGS[kind]["action"]
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var key := InputEventKey.new()
		key.physical_keycode = BINDINGS[kind]["key"]
		InputMap.action_add_event(action, key)


func _unhandled_input(event: InputEvent) -> void:
	if not enabled or event.is_echo():
		return
	for kind: StringName in BINDINGS:
		var action: StringName = BINDINGS[kind]["action"]
		if InputMap.has_action(action) and event.is_action_pressed(action):
			request(kind)
			get_viewport().set_input_as_handled()
			return


## Plays the next equipped action of [param kind], or the one named [param id]. Empty when there
## is nothing to play.
func request(kind: StringName, id: String = "") -> Dictionary:
	if not BINDINGS.has(kind) or actions == null:
		return {}
	var entry := actions.next(kind) if id == "" else actions.find(kind, id)
	if entry.is_empty():
		DotLog.debug(CHANNEL, "no %s to play%s" % [kind, "" if id == "" else " named " + id])
		return {}
	action_requested.emit(entry)
	return entry


## Adds [code]emote[/code], [code]pose[/code] and [code]gesture[/code] to a dot-console local
## (anything with [code]add_command(name, help, fn)[/code]); duck-typed so dot-console stays optional.
func register_console(local: Object) -> void:
	if local == null or not local.has_method(&"add_command"):
		return
	for kind: StringName in BINDINGS:
		local.call(&"add_command", kind, "Play your next %s, or the one named: %s [id]" % [kind, kind],
			func(args: PackedStringArray) -> Variant: return _console(kind, args))


func _console(kind: StringName, args: PackedStringArray) -> Variant:
	var entry := request(kind, args[0] if args.size() > 0 else "")
	if entry.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "no such %s" % kind)
	return "%s %s" % [kind, entry["id"]]


func describe() -> Dictionary:
	var keys := {}
	for kind: StringName in BINDINGS:
		var action: StringName = BINDINGS[kind]["action"]
		var events := InputMap.action_get_events(action) if InputMap.has_action(action) else []
		keys[kind] = events[0].as_text() if not events.is_empty() else "-"
	return {"enabled": enabled, "keys": keys, "actions": actions.describe() if actions else {}}
