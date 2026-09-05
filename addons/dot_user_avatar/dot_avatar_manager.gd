@tool
class_name DotAvatarManager
extends Node

## Resolves, validates and publishes avatars. The node a game adds.
##
## [codeblock]
## var avatars := DotAvatarManager.new()
## avatars.schema = preload("res://avatars/humanoid.tres")
## add_child(avatars)
##
## var resolved := await avatars.resolve(user_key, entitlements)
## [/codeblock]
##
## [b]The server-side rule this exists to enforce:[/b] an avatar arriving from a
## client is validated against the schema and the player's entitlements, and the
## server loads nothing to do it. No mesh, no texture, no scene. That is what lets a
## dedicated server run a match full of cosmetics it has never seen.
##
## [b]dot-user is not imported.[/b] The manager takes a scoped key, and finds
## [code]dot_user_manager[/code] through [DotRegistry] only to keep the profile's
## avatar digest current when one is installed. Everything works without it.

const CHANNEL := "avatar"
const SERVICE := &"dot_avatar_manager"

## dot-user's registry name. Looked up, never imported.
const USER_SERVICE := &"dot_user_manager"

## Emitted once an avatar is resolved for a player.
signal avatar_resolved(user_key: String, avatar: DotAvatar)

## Emitted when a player publishes a new one.
signal avatar_published(user_key: String, avatar: DotAvatar)

## Emitted when a stored avatar had to be repaired to fit the current schema.
##
## Carries what changed, so a game can tell the player rather than silently
## redressing them.
signal avatar_conformed(user_key: String, changes: PackedStringArray)

## Emitted when a publish is refused. The hook for a moderation log.
signal avatar_refused(user_key: String, reason: String)

@export_group("Content")

## The schema every avatar here is written against. Required.
@export var schema: DotAvatarSchema = null

@export_group("Configuration")

@export var config: DotAvatarConfig = null

## JSON file layered over the exported defaults. Empty disables the file layer.
@export var config_file: String = "user://dot_avatar.json"

@export var load_layered_config: bool = true

@export_group("Wiring")

## Register in [DotRegistry] under [constant SERVICE].
@export var register_service: bool = true

@export var service_scope: StringName = &""

## Where avatars live. Built from the config when left empty.
var store: DotAvatarStore = null

## Resolves part ids to content. Client-side only; a server never needs one.
var catalogue: DotAvatarCatalogue = null

## user_key -> {avatar, expires_at, active}
var _cache: Dictionary = {}

var _publish_limiter: DotRateLimiter = null
var _registered_name: StringName = &""
var _ready_ok: bool = false

## Publishes refused for entitlement reasons. Watched by an operator.
var refused_count: int = 0


# --- Lifecycle -------------------------------------------------------------

func _ready() -> void:
	if Engine.is_editor_hint():
		return

	var res := await setup()

	if not res.ok:
		DotLog.result(CHANNEL, "avatar manager setup", res)


func setup() -> DotResult:
	if schema == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"An avatar manager needs a schema."
		)

	# Validated once, here, rather than on every join. A broken schema is a content
	# error and belongs at startup, where it is one log line instead of one per
	# player.
	var schema_ok := schema.validate_schema()

	if not schema_ok.ok:
		return schema_ok.wrap("The avatar schema is not usable.")

	if config == null:
		config = DotAvatarConfig.new()

	if load_layered_config or config_file != "":
		var loaded := config.load_layered(config_file)
		if not loaded.ok:
			return loaded.wrap("Avatar configuration is not usable.")
	else:
		var valid := config.validate()
		if not valid.ok:
			return valid.wrap("Avatar configuration is not usable.")

	if store == null:
		var built := _build_store()
		if not built.ok:
			return built
		store = built.value

	var opened := await store.open()

	if not opened.ok:
		DotLog.warn(
			CHANNEL,
			"the avatar store did not open; players will get default avatars",
			{"store": store._store_name(), "error": str(opened.error)}
		)

	_publish_limiter = DotRateLimiter.new(
		float(config.publishes_per_minute) / 60.0,
		float(config.publishes_per_minute)
	)

	if register_service:
		_registered_name = (
			DotRegistry.scoped_name(SERVICE, service_scope)
			if service_scope != &"" else SERVICE
		)
		DotRegistry.register(_registered_name, self)

	_ready_ok = true

	DotLog.info(
		CHANNEL,
		"avatar manager ready",
		{"schema": String(schema.id), "config": config.describe_summary()}
	)

	return DotResult.success(null)


func _build_store() -> DotResult:
	match config.backend:
		"memory":
			return DotResult.success(DotAvatarStoreMemory.new())
		"local":
			return DotResult.success(DotAvatarStoreLocal.at(config.directory))
		"backbone":
			# Built here now that DotAvatarStoreBackbone exists, and it holds the
			# credential from the CONFIG rather than one this addon mints. That
			# was the objection the earlier refusal recorded: a store built with
			# no way to be given a token would have had to invent one.
			#
			# Assigning `store` directly is still supported and is what a host
			# sharing one DotHttp across every backbone call should do.
			var backbone := DotAvatarStoreBackbone.at(
				config.backbone_url, config.backbone_token
			)
			backbone.read_only = config.read_only
			return DotResult.success(backbone)

	return DotResult.fail(
		DotError.CODE_INVALID, "Unknown avatar backend.", config.backend
	)


func _exit_tree() -> void:
	if _registered_name != &"":
		DotRegistry.unregister_instance(_registered_name, self)
		_registered_name = &""

	if store != null:
		store.close()


func is_ready() -> bool:
	return _ready_ok


# --- Resolving -------------------------------------------------------------

## The avatar a player should be shown as.
##
## Conforms a stored document to the current schema when the config allows it, so
## retiring a part does not make a returning player unloadable. Falls back to the
## schema's default rather than to nothing: a player with no avatar must still be
## visible.
func resolve(
	user_key: String,
	entitlements: DotAvatarEntitlements = null
) -> DotResult:
	if not _ready_ok:
		return DotResult.fail(
			DotError.CODE_STATE, "The avatar manager is not ready yet."
		)

	var cached := _cached(user_key)

	if cached != null:
		avatar_resolved.emit(user_key, cached)
		return DotResult.success(cached)

	var fetched: DotResult = await store.fetch(user_key)

	if not fetched.ok:
		# The store could not answer. A default avatar keeps the player visible;
		# publishing over the top of what could not be read is what would lose it, so
		# nothing is written here.
		DotLog.warn(
			CHANNEL,
			"could not read an avatar; using the default",
			{"key": user_key, "error": str(fetched.error)}
		)
		return _default_for(user_key)

	var avatar: DotAvatar = fetched.value

	if avatar == null:
		if not config.allow_default_avatar:
			return DotResult.fail(
				DotError.CODE_STATE,
				"This player has not made an avatar yet.",
				user_key
			)

		return _default_for(user_key)

	if config.conform_on_load:
		var conformed := schema.conform(
			avatar, entitlements if config.enforce_entitlements else null
		)

		if not conformed.ok:
			# Not repairable — a document for another schema entirely. The default is
			# better than refusing the player.
			DotLog.warn(
				CHANNEL,
				"a stored avatar could not be conformed; using the default",
				{"key": user_key, "error": str(conformed.error)}
			)
			return _default_for(user_key)

		var changes: PackedStringArray = conformed.value

		if not changes.is_empty():
			avatar_conformed.emit(user_key, changes)
			DotLog.debug(
				CHANNEL, "conformed a stored avatar",
				{"key": user_key, "changes": ", ".join(changes)}
			)

	var valid := schema.validate(
		avatar, entitlements if config.enforce_entitlements else null
	)

	if not valid.ok:
		DotLog.warn(
			CHANNEL,
			"a stored avatar is not valid; using the default",
			{"key": user_key, "error": str(valid.error)}
		)
		return _default_for(user_key)

	_remember(user_key, avatar, true)
	avatar_resolved.emit(user_key, avatar)

	return DotResult.success(avatar)


func _default_for(user_key: String) -> DotResult:
	var avatar := schema.default_avatar()
	_remember(user_key, avatar, true)
	avatar_resolved.emit(user_key, avatar)
	return DotResult.success(avatar)


# --- Publishing ------------------------------------------------------------

## Accepts an avatar from a player, or refuses it with a reason.
##
## [b]This is the trust boundary.[/b] Everything a client sends arrives here, and
## every check that matters happens before anything is stored: the document's
## structure, the schema, and the player's entitlements. None of it loads an asset.
func publish(
	user_key: String,
	avatar: DotAvatar,
	entitlements: DotAvatarEntitlements = null
) -> DotResult:
	if not _ready_ok:
		return DotResult.fail(
			DotError.CODE_STATE, "The avatar manager is not ready yet."
		)

	if avatar == null:
		return DotResult.fail(DotError.CODE_INVALID, "No avatar.")

	if config.read_only:
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "This server does not store avatars."
		)

	if _publish_limiter != null and not _publish_limiter.allow(user_key):
		var wait := _publish_limiter.retry_after(user_key)
		var error := DotError.make(
			DotError.CODE_RATE_LIMITED,
			"That is too many avatar changes in a row.",
			"retry in %.1fs" % wait
		)
		error.retry_after = wait
		return DotResult.failure(error)

	var valid := schema.validate(
		avatar, entitlements if config.enforce_entitlements else null
	)

	if not valid.ok:
		refused_count += 1
		avatar_refused.emit(user_key, str(valid.error))
		return valid

	var stored: DotResult = await store.store(user_key, avatar)

	if not stored.ok:
		return stored

	_remember(user_key, avatar, true)

	# Keep the profile's digest current, if dot-user is installed. This is what lets
	# every other client tell that its cached copy of this player is stale without
	# fetching the document to find out.
	_update_profile_digest(user_key, avatar)

	avatar_published.emit(user_key, avatar)
	return DotResult.success(avatar.digest())


## Writes the avatar's digest into the player's profile, when dot-user is present.
##
## Best-effort by design: a game with no profiles still has working avatars, and an
## avatar publish must not fail because a profile write did.
func _update_profile_digest(user_key: String, avatar: DotAvatar) -> void:
	var users := DotRegistry.get_service(USER_SERVICE)

	if users == null or not users.has_method("save"):
		return

	var cache: Variant = users.get("_cache")

	if not (cache is Dictionary) or not (cache as Dictionary).has(user_key):
		return

	var entry: Variant = (cache as Dictionary)[user_key]

	if not (entry is Dictionary):
		return

	var profile: Variant = (entry as Dictionary).get("profile")

	if profile == null:
		return

	profile.set("avatar_id", avatar.digest())


# --- Cache -----------------------------------------------------------------

func _cached(user_key: String) -> DotAvatar:
	if not _cache.has(user_key):
		return null

	var entry: Dictionary = _cache[user_key]

	if not bool(entry["active"]) and Time.get_ticks_msec() > int(entry["expires_at"]):
		_cache.erase(user_key)
		return null

	return entry["avatar"]


func _remember(user_key: String, avatar: DotAvatar, active: bool) -> void:
	_cache[user_key] = {
		"avatar": avatar,
		"active": active,
		"expires_at": Time.get_ticks_msec() + int(config.cache_ttl_sec * 1000.0),
	}

	_evict_if_needed()


func _evict_if_needed() -> void:
	if config.max_cached <= 0 or _cache.size() <= config.max_cached:
		return

	var candidates: Array = []

	for key in _cache:
		var entry: Dictionary = _cache[key]
		if not bool(entry["active"]):
			candidates.append([int(entry["expires_at"]), key])

	candidates.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

	var excess := _cache.size() - config.max_cached
	var dropped := 0

	for candidate in candidates:
		if dropped >= excess:
			break
		_cache.erase(candidate[1])
		dropped += 1


## Marks a player as gone, starting their cache expiry.
func release(user_key: String) -> void:
	if not _cache.has(user_key):
		return

	var entry: Dictionary = _cache[user_key]
	entry["active"] = false
	entry["expires_at"] = Time.get_ticks_msec() + int(config.cache_ttl_sec * 1000.0)


func cached_count() -> int:
	return _cache.size()


func clear_cache() -> void:
	_cache.clear()


# --- Diagnostics -----------------------------------------------------------

func describe() -> Dictionary:
	return {
		"ready": _ready_ok,
		"schema": schema.describe() if schema != null else {},
		"config": config.describe_summary() if config != null else "<none>",
		"store": store.describe() if store != null else {},
		"cached": _cache.size(),
		"refused": refused_count,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("avatars      %s" % (
		config.describe_summary() if config != null else "<unconfigured>"
	))
	out.append("schema       %s (%d slots, %d parts)" % [
		schema.id if schema != null else "<none>",
		schema.slots.size() if schema != null else 0,
		schema.parts.size() if schema != null else 0,
	])
	out.append("store        %s" % (
		store._store_name() if store != null else "<none>"
	))
	out.append("cached       %d avatar(s)" % _cache.size())

	if refused_count > 0:
		out.append("refused      %d publish(es)" % refused_count)

	return out
