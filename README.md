This is the **avatar** asset for TMC's **Dot** collection. It makes what a player looks like into something a dedicated server can check, which matters because a server has no business loading meshes.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Avatars as Data
Player avatars as data, so a dedicated server can check one without ever loading a
mesh.

An avatar is a schema id, a set of part ids and a set of colours — a few dozen bytes.
A server validates it against the schema and the player's entitlements. A client
resolves the part ids to real assets through dot-cloud.

Part of the [dot-\*](../) family. Requires [dot-core](../dot-core). Pairs with
[dot-user](../dot-user), [dot-cloud](../dot-cloud), [dot-net](../dot-net) and
[dot-server](../dot-server), and **imports none of them**.

## Install

Copy `addons/dot_user_avatar/` and `addons/dot_core/` into your project and enable
both in *Project → Project Settings → Plugins*.

## Use

```gdscript
var avatars := DotAvatarManager.new()
avatars.schema = preload("res://avatars/humanoid.tres")
add_child(avatars)

# Server: what should this player look like?
var resolved := await avatars.resolve(user_key, entitlements)

# Server: a client sent us a new one.
var published := await avatars.publish(user_key, incoming, entitlements)
if not published.ok:
    print(published.error)   # "You do not have that item."
```

## The idea

The server has to decide whether an avatar is legal — every part exists, the player
owns it, every value is in range — on every join, for thirty players. If that needed
the assets, a server would have to ship every cosmetic anyone owns.

So the avatar names its parts rather than embedding them:

```gdscript
var a := DotAvatar.make(&"humanoid")
a.set_part(&"hair", &"hair_long")
a.set_colour(&"hair", 0, Color("6b4423"))
```

Validation is four questions answered from ids: does the slot exist, does the part
exist and fit that slot, is the player entitled to it, are the colours within the
part's channel count. None of them loads anything.

## What is in the box

| | |
| --- | --- |
| `DotAvatar` | The document. Bounded, versioned, with a stable digest. |
| `DotAvatarSchema` | Slots, parts, and the `validate` / `conform` pair. |
| `DotAvatarSlot` / `DotAvatarPart` | What a game defines. Layers, defaults, fallbacks, entitlement. |
| `DotAvatarEntitlements` | What one player may wear. Owns nothing by default. |
| `DotAvatarCatalogue` | Part id → content, through dot-cloud when it is installed. |
| `DotAvatarBuilder` | Plan (pure) and apply (touches nodes). |
| `DotAvatarSync` | Bit-packed wire format and the backbone endpoints. |
| `DotAvatarStore` | Where documents live: memory, JSON files, or a backbone. |
| `DotAvatarManager` | Resolve, conform, validate, publish, cache, rate-limit. |

## Avatars that follow a player between servers

Set the backend to `backbone` and documents live on a web backbone instead of on
the server's disk, so a player who spent ten minutes in an editor is recognisable
on every server they join.

```gdscript
manager.config.backend = "backbone"
manager.config.backbone_url = "https://themodcommunity.com/api/integration/v1"
manager.config.backbone_token = OS.get_environment("AVATAR_TOKEN")
manager.config.read_only = true    # most servers should read and never publish
```

The protocol is three addresses — `GET`/`PUT`/`DELETE /user/{key}/avatar` — plus
a public `GET /api/avatar/v1/schema`. It is open, specified, and TMC runs one
instance of it rather than being it: **the full spec is published at
[`docs/api/avatar-protocol.md`](https://themodcommunity.com/docs/api/avatar-protocol.md)**
and anyone can implement their own.

Two properties that are the point of the design and are easy to undo:

- **The server holds its own credential, never the player's.** A server that
  could present a player's account token would be a server whose operator can act
  as every one of their players on the whole site.
- **`{key}` is a scoped derivation, not an account id.** The same player is a
  different key on every server, so no two operators can compare logs and
  reconstruct somebody's movements across the platform.

## Two failure modes it is built around

**A player whose cosmetics have not downloaded must still be visible.** An invisible
player is a competitive advantage. Parts declare a `fallback_id`, the catalogue walks
the chain (bounded, so a circular fallback cannot hang the renderer), and the plan
reports what was substituted or missing so the game can show a placeholder rather
than nothing.

**A schema change must not make every saved avatar unloadable.** Retiring a part,
adding a required slot or revoking an entitlement all invalidate existing documents.
`conform()` repairs instead of refusing — dropping what no longer exists, filling
required slots from their defaults — and reports what changed so the player can be
told rather than silently redressed.

## Wearing what you own

`DotAvatarEntitlements` holds a set of part ids and nothing else. Where they came
from — a purchase, a season pass, a site group — is the game's business.

The default is that a player owns **nothing**; a part is wearable only if it is marked
free or is in the set. Defaulting the other way means a bug in whatever supplies the
set silently unlocks everything, and nobody reports that as a bug.

`DotAvatarConfig.enforce_entitlements` turns the check off for a creator sandbox. It
warns loudly at startup, because a server running with it off has no entitlement
system at all.

## Validating

```bash
godot --headless --path . --import
godot --headless --path . res://examples/avatar_demo.tscn     # 118 checks
```

Exits non-zero on failure.

MIT licensed.
