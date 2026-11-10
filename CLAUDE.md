# Notes for Claude

Most of this repository is written by Claude, an AI model made by Anthropic, at JustEyeTea's direction. Its maintainer
must be able to open any file alone and fix it by hand, so code here is written to be read by a person first.

Before writing code:

1. Read [docs/style-guide.md](docs/style-guide.md) and follow it while you write, not afterwards. It is the one home of
   this project's rules for names, comments, function and file size, the UE4SS Lua threading rules and C++ layout.
2. Read the section of [docs/architecture.md](docs/architecture.md) for the part you are changing, and update it (and
   its "where to look" rows) when the change moves anything.
3. Write the file's opening comment and the function names and one-line descriptions before the bodies.

Before committing:

- Run the tests the style guide names (`tools/ap_tests.sh`, `tools/lua_harness.sh`, and `tools/test_options_page.py`
  after an options or version change) and judge each by its exit code.
- Read the diff with only the file open. Fix anything that needs the conversation to make sense.
- A `readability:` commit changes no behaviour, and the style guide says how to prove it.
- Ids never move, and Pocketpair's data stays out of the repository.
