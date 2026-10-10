# History

This addon's reasoning is almost all current and lives in [document.md](document.md) and [integration.md](integration.md). The failures worth recognising:

- **The whole server was one capsule.** Every game drew stock characters by hashing an id and preferred what the platform resolved, and the platform resolved `schema.default_avatar()` for everybody with nothing stored. The variety lasted until dot-platform admitted somebody. Fixed by `default_avatar_fn` ([integration](integration.md#a-player-with-nothing-stored-is-the-games-default-when-it-has-one)).
- **Every member arrived as stock in every game.** The site's avatar is over its own `builtin` schema, and `conform` refuses another schema's document. Fixed by `translate_fn` ([integration](integration.md#the-sites-avatar-is-over-the-sites-schema-and-a-game-translates-it)).
- **Every member who never opened the site's editor translated to the same person**, because the site answers with a default document for them. Fixed by treating `saved: false` as no avatar.
- **The trap tinting avoids:** editing a part's material in place recolours everyone wearing that part, because they share the loaded `Resource`. Only visible with two players in the level; tints are per-instance shader parameters.
