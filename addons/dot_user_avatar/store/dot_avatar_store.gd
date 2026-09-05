class_name DotAvatarStore
extends RefCounted

## Where avatar documents live, keyed by the player's scoped id.
##
## Same shape and same two rules as dot-user's profile store, because it is the same
## problem: a per-player record a community running several servers wants to share.
## Loads may be slow and lookups on the join path may not; a failed read keeps
## whatever is in force rather than replacing it with a blank.
##
## Keyed by the [b]scoped[/b] id dot-user derives, never an account id, for the
## same reason profiles are: a file named after an account id lets two operators
## correlate their players by comparing directory listings.

const CHANNEL := "avatar.store"

var _opened: bool = false

var fetch_count: int = 0
var store_count: int = 0
var failure_count: int = 0


# --- Subclass interface ----------------------------------------------------

## Reads one avatar. A successful null means "this player has not made one".
func _fetch(_user_key: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL, "%s does not implement _fetch()." % _store_name()
	)


func _store(_user_key: String, _avatar: DotAvatar) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL, "%s does not implement _store()." % _store_name()
	)


func _remove(_user_key: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INTERNAL, "%s does not implement _remove()." % _store_name()
	)


func _open() -> DotResult:
	return DotResult.success(true)


func _close() -> void:
	pass


func _writable() -> bool:
	return true


func _store_name() -> String:
	return "DotAvatarStore"


# --- Public API ------------------------------------------------------------

func open() -> DotResult:
	if _opened:
		return DotResult.success(true)

	var res := await _open()

	if res.ok:
		_opened = true
	else:
		failure_count += 1

	return res


func close() -> void:
	if _opened:
		_close()
		_opened = false


func is_open() -> bool:
	return _opened


func is_writable() -> bool:
	return _writable()


## Reads an avatar, or null when the player has not made one.
##
## The key is checked before any implementation sees it, so a malformed one can never
## reach a filesystem path or a URL.
func fetch(user_key: String) -> DotResult:
	if not DotAvatarKey.is_usable(user_key):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That is not a usable player key.",
			user_key.substr(0, 64)
		)

	if not _opened:
		var opened := await open()
		if not opened.ok:
			return opened.wrap("The avatar store is not available.")

	fetch_count += 1

	var res: DotResult = await _fetch(user_key)

	if not res.ok:
		failure_count += 1

	return res


## Writes an avatar, validating its structure first.
##
## [b]Structure only, deliberately.[/b] Whether the player is entitled to what they
## are wearing is a schema-and-entitlements question, and the store does not hold
## either. [DotAvatarManager.publish] is where both checks happen together; a store
## that pretended to do the second would be a checkpoint people trusted and should
## not.
func store(user_key: String, avatar: DotAvatar) -> DotResult:
	if avatar == null:
		return DotResult.fail(DotError.CODE_INVALID, "No avatar to store.")

	if not DotAvatarKey.is_usable(user_key):
		return DotResult.fail(
			DotError.CODE_INVALID, "That is not a usable player key."
		)

	if not _writable():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "This avatar store is read-only.", _store_name()
		)

	var valid := avatar.validate()

	if not valid.ok:
		return valid.wrap("Refusing to store an invalid avatar.")

	if not _opened:
		var opened := await open()
		if not opened.ok:
			return opened

	var res: DotResult = await _store(user_key, avatar)

	if res.ok:
		store_count += 1
	else:
		failure_count += 1

	return res


func remove(user_key: String) -> DotResult:
	if not DotAvatarKey.is_usable(user_key):
		return DotResult.fail(
			DotError.CODE_INVALID, "That is not a usable player key."
		)

	if not _writable():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "This avatar store is read-only."
		)

	if not _opened:
		var opened := await open()
		if not opened.ok:
			return opened

	return await _remove(user_key)


func describe() -> Dictionary:
	return {
		"store": _store_name(),
		"open": _opened,
		"writable": _writable(),
		"fetches": fetch_count,
		"stores": store_count,
		"failures": failure_count,
	}


func _to_string() -> String:
	return "%s(%s)" % [_store_name(), "open" if _opened else "closed"]
