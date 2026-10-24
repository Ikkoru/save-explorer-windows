# doc-audit overlay: save-explorer-windows

**Scope**: every tracked file. Prose: `CLAUDE.md`, `DOC.md`, `README.md`, `.claude/rules/script.md`, this file. Comments: the `.ps1` scripts, `Explorer Windows Shared.psm1` and `Tests/Run tests.ps1`. No archives.

**Published**: the `public` branch, pushed to GitHub as `main` (public). `master` is never pushed; its history holds private details by design (`DOC.md`, *Publishing*). The privacy sweep covers the tracked files and every commit on `public`, its messages and authors included.

**Not findings**:
- Made-up paths in the tests and the rule file's stubs (`C:\A`, `C:\Test\...`, `Z:\A B\C`, `C:\Some folder, etc\...`).
- The maintainer's GitHub login and no-reply address in `DOC.md`, *Publishing*: the public identity, there on purpose.
- "The kit's `powershell-scripts.md`": the maintainer's own Claude Code rules, outside this repository. Kept as is at the maintainer's choice.
- "used to be with", "no longer open" and the like in `README.md`: they describe the user's folders, not the program's history.
- Version numbers on compatibility facts (saves from v5.3, restore files before 6.4 or 7.0, upgrading from 6.0/6.1): load-bearing for reading old files.

**Long sentences**: count per line, outside fences, splitting on `.`, `!` or `?` followed by a space. Joining lines first also counts list items that end without a full stop, which are not sentences.

**Queue**: none kept; `_tmp/` is the maintainer's drop folder.

**Last pass**: a commit whose subject starts `Doc audit`.
