class_name DotAvatarStoreLocal
extends DotAvatarStore

## Avatars as JSON files under a directory. The default, and it works unconfigured.
##
## One file per player, for the reason dot-user's profile store gives: a single file
## is rewritten in full on every change and loses everything rather than one record
## when a write is interrupted.

const LOCAL_CHANNEL := "avatar.store.local"

var directory: String = "user://avatars"

## Write through a temporary file and rename over the target.
##
## Passed to [method DotPaths.write_json], which already does the temporary file, the
## rename and the browser's IndexedDB flush.
var atomic_writes: bool = true


static func at(path: String) -> DotAvatarStoreLocal:
	var s := DotAvatarStoreLocal.new()
	s.directory = path
	return s


func _store_name() -> String:
	return "DotAvatarStoreLocal"


func _open() -> DotResult:
	var made := DotPaths.ensure_dir(directory)

	if not made.ok:
		return made.wrap("Could not open the avatar directory.")

	DotLog.debug(LOCAL_CHANNEL, "avatar store open", {"directory": directory})
	return DotResult.success(true)


func _path_for(user_key: String) -> DotResult:
	var relative := DotPaths.safe_relative("%s.json" % user_key)

	if not relative.ok:
		return relative.wrap("That key is not a usable filename.")

	return DotResult.success("%s/%s" % [directory, relative.value])


func _fetch(user_key: String) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	if not FileAccess.file_exists(path.value):
		return DotResult.success(null)

	var read := DotPaths.read_json(path.value)

	if not read.ok:
		# A file that exists and will not parse is a failure, never an absence.
		# Reporting it as "no avatar" would make the manager write a default over
		# whatever could still have been recovered by hand.
		return read.wrap("A stored avatar could not be read.")

	if not (read.value is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE, "A stored avatar is not an object.", path.value
		)

	return DotAvatar.from_dict(read.value as Dictionary)


func _store(user_key: String, avatar: DotAvatar) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	var written := DotPaths.write_json(
		path.value, avatar.to_dict(), true, atomic_writes
	)

	if not written.ok:
		return written.wrap("Could not write the avatar.")

	return DotResult.success(true)


func _remove(user_key: String) -> DotResult:
	var path := _path_for(user_key)

	if not path.ok:
		return path

	if not FileAccess.file_exists(path.value):
		return DotResult.success(true)

	var dir := DirAccess.open(directory)

	if dir == null:
		return DotResult.fail(
			DotError.CODE_IO, "Could not open the avatar directory.", directory
		)

	var removed := dir.remove(String(path.value).get_file())

	if removed != OK:
		return DotResult.failure(
			DotError.from_engine(removed, "Removing the avatar")
		)

	# DotPaths flushes on write; a deletion goes through DirAccess directly, so on a
	# web build it has to be flushed here or the file returns on the next load.
	DotWeb.sync_filesystem()
	return DotResult.success(true)


func describe() -> Dictionary:
	var out := super.describe()
	out["directory"] = directory
	return out
