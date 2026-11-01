# doc-audit overlay: save-explorer-windows

**Scope**: every tracked file. Prose: `CLAUDE.md`, `DOC.md`, `README.md`, `.claude/rules/script.md`, this file. Comments: the `.ps1` scripts, `Explorer Windows Shared.psm1` and `Tests/Run tests.ps1`. No archives.

**Published**: `master`, pushed to GitHub as `main` (public). The older private history under `refs/archive/master-private` is never pushed (`DOC.md`, *Publishing*). The privacy sweep covers the tracked files and every commit on `origin/main`, its messages and authors included, and the messages of commits not yet pushed.

**Not findings**:
- Made-up paths in the tests and the rule file's stubs (`C:\A`, `C:\Test\...`, `Z:\A B\C`, `C:\Some folder, etc\...`).
- The maintainer's GitHub login and no-reply address in `DOC.md`, *Publishing*: the public identity, there on purpose.
- "The kit's `powershell-scripts.md`": the maintainer's own Claude Code rules, outside this repository. Kept as is at the maintainer's choice.
- "used to be with", "no longer open" and the like in `README.md`: they describe the user's folders, not the program's history.
- Version numbers on compatibility facts (saves from v5.3, restore files before 6.4 or 7.0, upgrading from 6.0/6.1): load-bearing for reading old files.
- Published commits committed by `GitHub <noreply@github.com>` with the maintainer as author: edits the maintainer made in GitHub's web editor.
- The CLSIDs in the rule file and the tests (`ShellWindows`, This PC): Windows' own class IDs, the same on every PC.
- Windows cmdlets named as commands to run (`Set-ScheduledTask`, `Register-ScheduledTask`): not project identifiers.

**Backticked identifiers**: the module defines its variables as `$script:Name`, while the docs write `$Name`; search for the bare name, or every module variable reads as missing.

**Long sentences**: count per line, outside fences, splitting on `.`, `!` or `?` followed by a space. Joining lines first also counts list items that end without a full stop, which are not sentences.

**Queue**: none kept; `_tmp/` is the maintainer's drop folder.

**Last pass**: a commit whose subject starts `Doc audit`.
