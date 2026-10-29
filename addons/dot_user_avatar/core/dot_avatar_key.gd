class_name DotAvatarKey
extends RefCounted

## Whether a string is usable as the key an avatar is filed under.
## Not [code]DotAvatarKey.is_usable[/code] from dot-user: only dot-core is a hard dependency.
## Structural only (no traversal, URL escape or log newline); whether a key is genuine comes from the connect ticket.

## Shortest key accepted. Below this a key is not plausibly an id at all.
const MIN_LENGTH := 8

## Longest key accepted.
## Above the 22 characters dot-user's scoped ids use, far below any filename problem.
const MAX_LENGTH := 64


func _init() -> void:
	push_error("DotAvatarKey is a static utility; do not instantiate it.")


## Base64url characters only: letters, digits, dash, underscore.
## Admits every dot-user id and excludes anything meaningful to a filesystem, URL or log line (the dot too, so never [code]..[/code]).
static func is_usable(key: String) -> bool:
	if key.length() < MIN_LENGTH or key.length() > MAX_LENGTH:
		return false

	for i in range(key.length()):
		var c := key.unicode_at(i)
		var ok := (
			(c >= 65 and c <= 90)
			or (c >= 97 and c <= 122)
			or (c >= 48 and c <= 57)
			or c == 45
			or c == 95
		)
		if not ok:
			return false

	return true


## The same check as a [DotResult], for a call site that wants to propagate a reason.
static func check(key: String) -> DotResult:
	if is_usable(key):
		return DotResult.success(key)

	return DotResult.fail(
		DotError.CODE_INVALID,
		"That is not a usable player key.",
		"'%s' (%d characters)" % [key.substr(0, 64), key.length()]
	)
