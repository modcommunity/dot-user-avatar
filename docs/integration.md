# Integration

How a player's avatar is resolved, stored on the backbone, exported for the web editor and built into nodes, and how this addon meets the others without importing any. The document itself is [document.md](document.md).

## A player with nothing stored is the GAME's default, when it has one

`resolve` hands a player with no stored avatar `schema.default_avatar()`: one document, so everybody without an avatar is the same person. Every game draws its stock characters by hashing an id and rightly prefers what the platform resolved to its own fallback, so without a hook the variety lasts exactly until dot-platform admits somebody, and then the whole server is one capsule.

`DotAvatarManager.default_avatar_fn(user_key) -> DotAvatar` is the game's stock look, asked with the scoped key (so a player is the same person on every visit) and validated like anything stored.

- One that does not fit the schema falls back to the schema's default with a WARN, because a stock look is never a reason to leave somebody undrawn.
- One that answers null falls back with no line at all: null is "no opinion", which is what `DotPlatformIdentity`'s wrapper says for a game that set no stock function, and a WARN per first-time player of such a game would be a warning about a configuration nobody got wrong.

dot-platform's `DotPlatformIdentity` wires the game's `stock_avatar_fn` into it.

## The site's avatar is over the site's schema, and a game translates it

A member has one avatar on the site, over its `builtin` schema (the Kenney kit's eighteen painted skins, chosen per face, top and legs), and every game has its own schema. `conform` rightly refuses a document for another schema, so without a translation every member arrives as stock in every game.

`DotAvatarManager.translate_fn(foreign) -> DotAvatar` is the game saying what the site's choices mean in its own terms ("their torso skin is my body"), and runs before conform and validate, so what it returns is held to this schema and its entitlements like anything stored. No function, or null, is the default with a DEBUG line: a document this game cannot read is a person it draws as stock, not an error. A game may still keep its own per-game choices; the translation is only the default path.

**Unsaved is no avatar.** The site answers every member, and one who never opened its editor gets the default document with `saved: false`. `DotAvatarSync.fetch` returns null for it, so the game's own per-player stock look applies instead of every such member translating to the same person.

## The backbone store, and why the wire format is not the packed one

`DotAvatarStoreBackbone` is the third store, and the one that makes an avatar follow a player between servers. It speaks three addresses (`GET`/`PUT`/`DELETE /user/{key}/avatar`) with a **server-scoped** credential; the full specification lives on the backbone at `docs/api/avatar-protocol.md`.

**It sends `DotAvatar.to_dict()`, not `DotAvatarSync.write`.** The packed format exists for the match, where a document travels to thirty peers and indices into the schema turn several hundred bytes into about twenty. A backbone is asked once per player per join, JSON is what an HTTP API elsewhere can read, and (the deciding reason) an index-based encoding requires both ends to hold the SAME schema, which a backbone serving several games does not.

**The key is a scoped derivation, never an account id.** That is the whole reason `DotAvatarKey` is only a structural check: this addon receives a key and files a document under it. Whoever mints identities does the scoping, and a server that could compute it could correlate its players against every other server's.

**`_store` compares the backbone's digest against its own and warns.** A backbone that canonicalises differently breaks cache invalidation for every client and reports nothing, so `DotAvatarSync.publish` returns the digest the SERVER reported when there is one, rather than echoing ours, which would always agree with itself. The publish still succeeds: the write happened, and failing it afterwards would be a lie about what is stored.

**Its HTTP client is parented to the root on `open` and freed on `close`.** `DotHttp` is a Node that sends through `HTTPRequest` children, which refuse with engine error 3 (Unconfigured) outside the tree, and the store is a RefCounted with no tree of its own. `_open` adds a client it built to the root deferred (open may run inside somebody's `_ready`) and awaits a frame so the first request finds it there; `_close` frees only a client it built, never one a host supplied. Because `_open` suspends, `DotAvatarStore.open()` lets one attempt run at a time and a second caller waits for it: a manager's `_ready` and its host's `setup()` both open the store.

`FakeBackboneHttp` in the demo serves the protocol from a dictionary, so the store runs through the shared store contract offline like the other two. It extends `DotHttp` rather than duck-typing it (the store's transport is typed), and overriding `request()` alone covers all three verbs because `get_json` and `put_json` are built on it. **A fake more forgiving than the real client is worse than no fake**, which is why it answers 404 for an unrecognised path, returns the real response dictionary rather than bare bytes, and refuses outside the tree as `HTTPRequest` does. The "backbone store transport" section drives the real `DotHttp` against a closed loopback port, because a fake that overrides `request()` cannot see the transport at all.

## Exporting for a web editor

`tools/export_avatar_manifest.gd` is an `EditorScript` that walks a schema, exports every part's scene to `.glb`, and writes the web manifest the website's editor consumes. It is an editor script because glTF export needs the editor's own `GLTFDocument` state, which a `--headless --script` run does not have.

Two things it deliberately refuses to guess: the **palette** (a channel count is not a set of colours, and that is the only choice a member has for such a slot) and **which parts are free** (entitlements are commerce, and commerce belongs on a backbone). Both are marked in the output.

## Building nodes: plan here, apply in dot-player-char

`DotAvatarBuilder.plan()` works out which parts go where, in what order, with which colours, and which have fallen back: pure logic over ids, testable headless where a failure has one cause. It has to stay here, because a planner living in a rendering addon would be one a server had to install a rendering addon to run.

The *general* version of applying a plan (clearing a mount, instantiating a part, writing per-instance tints) lives in dot-player-char as `DotPlayerModelBuilder`, written against a plain-dictionary plan, so a character's own customisation document, a class's model and a loadout's view model all share it. `plan_dicts()` is the seam and `DotPlayerModelBuilder.from_plan` is the other side of it. **Neither addon imports the other**, and `apply()` here still works and is still tested, for a game that installs only this one.

Tinting uses `set_instance_shader_parameter`, not material swaps. Two players wearing the same part share the `Resource` loaded from disk, so editing a material in place recolours both of them: a bug that only appears with more than one player in the level.

## Coupling: nothing is imported

- **dot-cloud** is found through `DotRegistry` as `dot_cloud_client` and duck-typed on `resolve(content_id)`. Absent, parts naming content are simply unavailable, which is correct: the game did not ship them and nothing can fetch them.
- **dot-user** is found as `dot_user_manager`, and only to keep the profile's avatar digest current. Best-effort: an avatar publish must not fail because a profile write did.
- **dot-net** is not mentioned anywhere. `DotAvatarSync.write`/`read` take a `Variant` writer and call its methods by name, the same way `DotTransportENet` reaches ENet, because a script that so much as mentions a missing `class_name` fails to parse and takes everything referencing it down too. `FakeWire` in the demo checks that contract without the dependency present.

## Using the plan with dot-player-char

```gdscript
var steps := DotPlayerModelBuilder.from_plan(DotAvatarBuilder.plan_dicts(plan))
DotPlayerModelBuilder.apply(steps, rig, placeholder)
```
