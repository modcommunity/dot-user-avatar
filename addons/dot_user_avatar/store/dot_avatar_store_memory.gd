class_name DotAvatarStoreMemory
extends DotAvatarStore

## Avatars in a dictionary, lost on exit. For tests and for a server that keeps
## nothing.
##
## Also the reference the file-backed store is checked against: the self-test runs one
## sequence through both and requires the same answers, so a bug in the file handling
## shows up as a difference rather than as a plausible result.

var _avatars: Dictionary = {}

## Made to fail on the next call, for exercising the recovery paths.
var fail_next_fetch: bool = false
var fail_next_store: bool = false


func _store_name() -> String:
	return "DotAvatarStoreMemory"


func _fetch(user_key: String) -> DotResult:
	if fail_next_fetch:
		fail_next_fetch = false
		return DotResult.fail(DotError.CODE_IO, "Simulated fetch failure.", user_key)

	if not _avatars.has(user_key):
		return DotResult.success(null)

	# Rebuilt rather than handed out by reference, so a caller editing what it got
	# back cannot change the store behind its own API.
	return DotAvatar.from_dict(_avatars[user_key])


func _store(user_key: String, avatar: DotAvatar) -> DotResult:
	if fail_next_store:
		fail_next_store = false
		return DotResult.fail(DotError.CODE_IO, "Simulated store failure.", user_key)

	_avatars[user_key] = avatar.to_dict()
	return DotResult.success(true)


func _remove(user_key: String) -> DotResult:
	_avatars.erase(user_key)
	return DotResult.success(true)


func size() -> int:
	return _avatars.size()


func clear() -> void:
	_avatars.clear()


func describe() -> Dictionary:
	var out := super.describe()
	out["avatars"] = _avatars.size()
	return out
