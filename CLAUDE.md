# dot-user-avatar

Player avatars as data, validated by a server that never loads a mesh.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first — no
autoloads, `DotNodeRef` instead of scene paths, `DotResult` for anything fallible,
`Dot`-prefixed class names, layered configuration, `describe()` on anything stateful.
This file is only what is specific to avatars.

## The one idea

**A dedicated server must be able to decide whether an avatar is legal without holding
any of the art.**

That single requirement produced the whole shape. A server checks four things — does
the slot exist, does the part exist and fit that slot, is the player entitled to it,
are the colours within the part's channel count — and all four are answered from ids.
So the document names its parts and the parts name their content, and the resolution
from a part id to an actual scene happens only on a client, only through
`DotAvatarCatalogue`, only via dot-cloud.

The alternative — an avatar that carries or references its meshes — means a server
running a match has to ship every cosmetic anyone owns. That is not a scaling problem
to solve later; it is the difference between a platform and a game.

**`DotAvatarSchema.validate` loads nothing, and it must stay that way.** If a change
here ever needs a `load()`, `ResourceLoader.exists()` or a scene path to decide
whether an avatar is legal, that is the thing to push back on.

## The trust boundary is `DotAvatarManager.publish`

Everything a client sends arrives there. In order: structural validation of the
document, then the schema, then entitlements, then the store. Nothing is written
before all three pass, and the store deliberately re-checks structure because it is
reachable from other call sites.

`DotAvatarStore.store` checks structure and **not** entitlements, on purpose. It does
not hold a schema or an entitlement set, and a store that pretended to check would be
a checkpoint people trusted and should not.

## Why entitlements default to nothing

`DotAvatarEntitlements` owns an empty set unless told otherwise, and a part is
wearable only if it is marked `free` or is in that set.

Defaulting the other way — everything permitted unless denied — means a bug in
whatever supplies the set silently unlocks the whole catalogue, and **nobody reports
that as a bug**. A player wearing something they did not buy does not file a ticket.
The failure is invisible until somebody notices in a screenshot.

`DotAvatarPart.free` defaults to `false` for the same reason: a mis-tagged part is
unwearable, which is a safe failure, rather than wearable by everyone, which is not.

`enforce_entitlements` exists for a creator sandbox and warns at startup when it is
off. `DotAvatarEntitlements.everything()` is named to be conspicuous at the call site.

## Conform before validate, always

Retiring a part, adding a required slot, renaming one, or a player losing an
entitlement all make existing documents invalid. Refusing them means a player who has
not logged in for a month loads into an error instead of a slightly different hat.

So `DotAvatarSchema.conform` repairs — dropping unknown slots and parts, removing what
is no longer owned, filling required slots from their defaults, trimming surplus
colours — and returns the list of changes so a game can tell the player rather than
silently redressing them. `DotAvatarManager.resolve` conforms and then validates.

**`conform` refuses exactly one thing**: a document naming a different schema. Nothing
in it means anything here, so there is nothing to repair.

This is why `validate_schema` forbids a required slot with no default. Such a slot
cannot be repaired, so every document missing it is permanently invalid — better to
fail at startup, once, than per player, forever.

## Bounds, and where they are enforced

A document is relayed to every other player in the match, so an unbounded one is an
amplification vector. Slot count, id length, colour channels and the id character set
are all capped in `DotAvatar.validate`.

**`from_dict` caps while reading, not after.** A document claiming ten thousand slots
would otherwise be fully built in memory before being refused, which is the denial of
service the cap exists to prevent.

Ids are restricted to base64url characters plus `.`, deliberately narrow. They become
dictionary keys, log lines and, on a client, part of a content lookup — a path
separator or a control character in one is never legitimate. Widening the set later is
easy; narrowing it after content has shipped is not.

`DotAvatarKey` is a **separate** structural check from dot-user's
`DotUserScope.is_well_formed`, and that duplication is deliberate: reusing dot-user's
would make this addon import it, and the family rule is that only dot-core is a hard
dependency. This addon never mints or verifies a key — it receives one and files a
document under it — so all it needs is the guard that stops a key becoming a directory
traversal. It is the same shape as dot-user's ids so the two interoperate without
depending on each other.

## Colours are quantised on the way in

`DotAvatar.set_colour` rounds to 8 bits per component immediately, rather than at the
wire.

If quantisation happened at the wire, the document a client validated and the document
a server stored would differ in their low bits, so a digest computed on one machine
would not match one computed on the other — and the digest is the entire mechanism by
which a client knows its cached copy of another player is stale.

Alpha is dropped rather than quantised. A tint with alpha is a transparency setting,
and a player who could make their avatar transparent has the same advantage as one who
is invisible.

## The digest, and why a profile carries it

`DotAvatar.digest()` is sixteen characters over the sorted slots, the part ids and the
quantised colours. dot-user's `DotUserProfile.avatar_id` holds it.

A scoreboard of thirty players therefore carries thirty digests, not thirty documents,
and fetches only the ones it does not already hold. It depends on sorted slot order,
which is why `filled_slots()` sorts — two machines that built the same avatar must
compute the same digest.

## A player who cannot be seen

Two paths lead there and both are closed:

- **Required slots.** A document with no torso is not a stylistic choice. `required`
  slots are filled from defaults by `conform` and their absence is refused by
  `validate`.
- **Content that has not downloaded.** Somebody else's hat is not something you can
  wait for. Parts declare `fallback_id`; `DotAvatarCatalogue.resolve_with_fallback`
  walks the chain **bounded**, because two parts naming each other is a content
  authoring mistake that would otherwise hang the renderer, and content is authored by
  people who are not reading this code. When nothing resolves, `DotAvatarBuilder.plan`
  marks the step `missing` so the caller shows a placeholder.

## Builder: plan and apply are separate

`plan()` works out which parts go where, in what order, with which colours, and which
have fallen back — pure logic over ids, testable headless where a failure has one
cause. `apply()` instantiates scenes and reparents nodes.

Tinting uses `set_instance_shader_parameter`, not material swaps. Two players wearing
the same part share the `Resource` loaded from disk, so editing a material in place
recolours both of them — a bug that only appears with more than one player in the
level.

## The backbone store, and why the wire format is not the packed one

`DotAvatarStoreBackbone` is the third store, and the one that makes an avatar
follow a player between servers. It speaks three addresses —
`GET`/`PUT`/`DELETE /user/{key}/avatar` — with a **server-scoped** credential,
and the full specification lives on the backbone at `docs/api/avatar-protocol.md`.

**It sends `DotAvatar.to_dict()`, not `DotAvatarSync.write`.** The packed format
exists for the match, where a document travels to thirty peers and indices into
the schema turn several hundred bytes into about twenty. A backbone is asked once
per player per join, JSON is what an HTTP API elsewhere can read, and — the
deciding reason — an index-based encoding requires both ends to hold the SAME
schema, which a backbone serving several games does not.

**The key is a scoped derivation, never an account id.** That is the whole reason
`DotAvatarKey` is only a structural check: this addon receives a key and files a
document under it. Whoever mints identities does the scoping, and a server that
could compute it could correlate its players against every other server's.

**`_store` compares the backbone's digest against its own and warns.** A backbone
that canonicalises differently breaks cache invalidation for every client and
reports nothing — so `DotAvatarSync.publish` returns the digest the SERVER
reported when there is one, rather than echoing ours, which would always agree
with itself. The publish still succeeds: the write happened, and failing it
afterwards would be a lie about what is stored.

`FakeBackboneHttp` in the demo serves the protocol from a dictionary, so the
store runs through the shared store contract offline like the other two. It
extends `DotHttp` rather than duck-typing it — the store's transport is typed,
and overriding `request()` alone covers all three verbs because `get_json` and
`put_json` are built on it. **A fake more forgiving than the real client is worse
than no fake**, which is why it answers 404 for an unrecognised path and returns
the real response dictionary rather than bare bytes.

## Exporting for a web editor

`tools/export_avatar_manifest.gd` is an `EditorScript` that walks a schema,
exports every part's scene to `.glb`, and writes the web manifest the website's
editor consumes. It is an editor script because glTF export needs the editor's
own `GLTFDocument` state, which a `--headless --script` run does not have.

Two things it deliberately refuses to guess: the **palette** (a channel count is
not a set of colours, and that is the only choice a member has for such a slot)
and **which parts are free** (entitlements are commerce, and commerce belongs on
a backbone). Both are marked in the output.

## Coupling: nothing is imported

- **dot-cloud** is found through `DotRegistry` as `dot_cloud_client` and duck-typed on
  `resolve(content_id)`. Absent, parts naming content are simply unavailable, which is
  correct: the game did not ship them and nothing can fetch them.
- **dot-user** is found as `dot_user_manager`, and only to keep the profile's avatar
  digest current. Best-effort: an avatar publish must not fail because a profile write
  did.
- **dot-net** is not mentioned anywhere. `DotAvatarSync.write`/`read` take a `Variant`
  writer and call its methods by name, the same way `DotTransportENet` reaches ENet —
  a script that so much as mentions a missing `class_name` fails to parse and takes
  everything referencing it down too. `FakeWire` in the self-test checks that contract
  without the dependency present.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

# 141 checks, all offline. Exits non-zero on any failure.
godot --headless --path . res://examples/avatar_demo.tscn
```

**Run the check-only pass before the scene.** A script that fails to parse makes the
scene fail to load and the process hangs rather than exiting.

`_test_store_contract` runs one sequence against the memory store, the local store and
the backbone store (through `FakeBackboneHttp`) and requires the same answers.
**Add any new store to it.**

**Add a case for any change to `DotAvatarSchema.validate`, `DotAvatarSync.read` or the
entitlement path.** Those are where a bug is a vulnerability rather than a crash — the
wire reader in particular, because every index in it arrived from another machine and
an index past the end of the schema is the obvious thing to send.

## Things deliberately not here

- **The editor UI.** `DotAvatarSchema.choices_for` gives it the list; the layout,
  the art and the camera are a game's own design and no two want the same one.
  The backbone runs one of its own on the web, which is what
  `tools/export_avatar_manifest.gd` feeds.
- **A commerce system.** `DotAvatarEntitlements` takes a set of ids and has no opinion
  about where they came from. Purchases, grants and season passes belong on the
  backbone.
- **Rigging, skinning and morph targets.** `DotAvatarSlot` attaches a scene to a named
  node. Body proportions as continuous sliders would need a rig contract this addon
  deliberately does not impose.
- **Moderation of user-made cosmetics.** Nothing here lets a player upload art, so
  there is nothing to moderate yet. When there is, the review queue belongs on the
  backbone and the part id becomes the thing that is approved.
- **Animation.** An avatar says what a player looks like, not what they are doing.
