@tool
class_name DotAvatarConfig
extends DotConfig

## Everything configurable about avatars. Layered like every [DotConfig]: exported
## defaults, then a JSON file, then [code]DOT_AVATAR_*[/code] environment variables,
## then [code]--avatar-*[/code] arguments.

@export_group("Storage")

## Where avatars live: [code]local[/code], [code]memory[/code] or
## [code]backbone[/code].
@export_enum("local", "memory", "backbone") var backend: String = "local"

## Directory for the [code]local[/code] backend.
@export var directory: String = "user://avatars"

## Base URL for the [code]backbone[/code] backend.
@export var backbone_url: String = ""

## Server token for the [code]backbone[/code] backend. A secret.
@export var backbone_token: String = ""

@export var read_only: bool = false

@export_group("Policy")

## Give a player with no avatar the schema's default and let them play.
##
## Off holds them at the profile stage until they make one, which is the platform
## flow: sign in, no avatar, open the editor. On is what a game with a fixed cast
## wants.
@export var allow_default_avatar: bool = true

## Repair an avatar that no longer fits the schema instead of refusing it.
##
## [b]On is strongly recommended.[/b] Retiring a part or adding a required slot makes
## existing documents invalid, and refusing them means a player who has not logged in
## for a month loads into an error rather than a slightly different hat.
@export var conform_on_load: bool = true

## Check entitlements when validating. [b]Never turn this off on a server.[/b]
##
## It exists for a client previewing its own work and for a creator sandbox. A server
## with it off accepts any avatar wearing anything.
@export var enforce_entitlements: bool = true

@export_group("Limits")

## Avatar publishes allowed per player per minute.
##
## A client in the editor can publish on every slider drag. Without a limit that is a
## store write per frame.
@export_range(1, 240, 1) var publishes_per_minute: int = 10

## Avatars held in memory at once. 0 is unlimited.
@export_range(0, 100000, 64) var max_cached: int = 2048

## Seconds a fetched avatar stays cached after the player leaves.
@export_range(0.0, 3600.0, 5.0) var cache_ttl_sec: float = 300.0


func env_prefix() -> String:
	return "DOT_AVATAR_"


func cli_prefix() -> String:
	return "--avatar-"


func sensitive_keys() -> PackedStringArray:
	return PackedStringArray(["backbone_token"])


func validate() -> DotResult:
	if backend == "backbone":
		if backbone_url.strip_edges() == "":
			return DotResult.fail(
				DotError.CODE_INVALID, "The backbone backend needs backbone_url."
			)

		if backbone_token.strip_edges() == "":
			# Refused here as well as in the store, because this runs at STARTUP
			# and the store does not open until the first player joins — so
			# without it a misconfigured server looks healthy right up until
			# somebody tries to play on it.
			return DotResult.fail(
				DotError.CODE_AUTH,
				"The backbone backend needs backbone_token.",
				"a server-scoped credential from the backbone; never a player's"
			)

	if backend == "local" and directory.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "The local backend needs a directory."
		)

	if not enforce_entitlements:
		# Loud, because it is the one setting here that turns off a security control
		# and the symptom is players wearing things they do not own, which nobody
		# reports as a bug.
		DotLog.warn(
			"avatar.config",
			"enforce_entitlements is off; any avatar will be accepted"
		)

	return DotResult.success(null)


func describe_summary() -> String:
	return "%s%s%s" % [
		backend,
		" read-only" if read_only else "",
		"" if enforce_entitlements else " UNENFORCED",
	]
