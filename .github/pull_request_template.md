## What this changes

## How it was tested
<!-- In game: which build, what you saw. Say plainly what wasn't tested. -->

## Checklist
<!-- Tick what applies; strike out (~~...~~) what does not, and say why. CONTRIBUTING.md has the commands. -->
- [ ] The tests pass, judged by their exit codes: `tools/ap_tests.sh`, `tools/lua_harness.sh`,
      `tools/test_options_page.py`, `tools/cpp_tests.sh`.
- [ ] Generated files are made again from their generators, not edited: `Scripts/ap_data.lua` by
      `tools/gen_lua_data.py` after a change to `data.py`; `docs/options/options.json` by `tools/gen_options_page.py`
      after a change to the options or the APWorld's version; any other in `docs/architecture.md`'s Generated files.
- [ ] `docs/architecture.md` (and its "Where to look" rows) describes the code as it now is.
- [ ] "Untested in game" marks are added for what is new and untested, and removed for what a playtest confirmed.
- [ ] For a release: `VERSION` in `main.lua` and `world_version` in `archipelago.json` set to the release, and its
      section in `CHANGELOG.md`.
- [ ] No game art or data: nothing of Pocketpair's (textures, maps, models, table dumps) is in the change.

## Notes
<!-- Anything a player or a later change should know. Say which parts an AI wrote, and which model. -->
