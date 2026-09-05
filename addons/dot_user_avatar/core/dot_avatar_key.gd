class_name DotAvatarKey
extends RefCounted

## Whether a string is usable as the key an avatar is filed under.
##
## [b]Deliberately not [code]DotAvatarKey.is_usable[/code].[/b] That would make
## dot-user-avatar import dot-user, and the family rule is that only dot-core is a
## hard dependency — a game that wants avatars without profiles, or with its own
## identity system, must not have to install one to get the other.
##
## More to the point, this addon does not need the derivation. It never mints a key
## and never verifies one against an account; it receives one and files a document
## under it. The only thing it has to know is that a key cannot become a directory
## traversal, a URL escape or a log-injection newline on its way to a store. That is a
## structural check, and it is deliberately the same shape as the scoped ids dot-user
## produces so the two interoperate without depending on each other.
##
## [b]It says nothing about whether a key is genuine.[/b] Only whoever holds the
## scope key can answer that, which is the point of the scoping. A server that needs
## the guarantee gets it from the connect ticket, not from here.

## Shortest key accepted. Below this a key is not plausibly an id at all.
const MIN_LENGTH := 8

## Longest key accepted.
##
## Comfortably above the 22 characters dot-user's scoped ids use, so a game
## with its own longer identifier still works, and far below anything that would be a
## problem as a filename.
const MAX_LENGTH := 64


func _init() -> void:
	push_error("DotAvatarKey is a static utility; do not instantiate it.")


## Base64url characters only: letters, digits, dash, underscore.
##
## Narrow on purpose. It admits every id dot-user produces and excludes every
## character that means something to a filesystem, a URL or a log line — the dot is
## excluded too, so a key can never be [code]..[/code].
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
