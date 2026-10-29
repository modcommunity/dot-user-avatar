class_name DotAvatarStore
extends RefCounted

## Where avatar documents live, keyed by the player's scoped id.
## Same shape and rules as dot-user's profile store: loads may be slow, join-path lookups may not, and a failed read keeps what is in force.
## Keyed by the scoped id, never an account id, so two operators cannot correlate players by directory listing.

const CHANNEL := "avatar.store"

var _opened: bool = false

## Emitted when an attempt [method open] started finishes, for callers that arrived
## while it was in flight.
signal _open_finished(res: DotResult)

var _opening: bool = false

var fetch_count: int = 0
var store_count: int = 0
var failure_count: int = 0


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


func open() -> DotResult:
	if _opened:
		return DotResult.success(true)

		# One attempt at a time; a second caller waits. _open can suspend and both a manager's _ready and
		# setup() open the store; overlapping attempts queued the same client onto the root twice.
	if _opening:
		var shared: DotResult = await _open_finished
		return shared

	_opening = true
	var res := await _open()
	_opening = false

	if res.ok:
		_opened = true
	else:
		failure_count += 1

	_open_finished.emit(res)
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
## The key is checked before any implementation sees it, so a malformed one never reaches a path or URL.
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
## Structure only: entitlements need the schema, which the store lacks; [DotAvatarManager.publish] checks both, and a store pretending to would be a trusted false checkpoint.
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
		_report_write_failure("an avatar was not saved", user_key, res)

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

	var res: DotResult = await _remove(user_key)

	if not res.ok:
		failure_count += 1
		_report_write_failure("an avatar was not removed", user_key, res)

	return res


## Logged in the base because every backend's write passes through it, so none can forget it.
## ERROR because the avatar had passed validation: this is a player's avatar not persisting. Only write paths; the manager logs failed opens and fetches.
func _report_write_failure(what: String, user_key: String, res: DotResult) -> void:
	DotLog.error(CHANNEL, what, {
		"store": _store_name(),
		"key": user_key,
		"code": res.code(),
		"error": res.error.message if res.error != null else "",
	})


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
