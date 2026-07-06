# AGENTS.md - Downloads Organizer

Instructions for AI coding agents (Claude Code, OpenCode, Codex, etc.):
part 1 covers installing this repo on a user's Mac, part 2 is the full build
spec for reproducing the organizer from scratch without the reference
implementation.

All paths derive from `$HOME` and the repo's own location; **never** hardcode
`/Users/<someone>/...`. Target OS: macOS 12+. Shell: bash (3.2 compatible).
No third-party deps.

## What this is

Automatically sorts new files in `~/Downloads` into typed subfolders. Runs on
file-system change (via `launchd` WatchPaths) and every 5 minutes as a safety
net. Config-driven: users add folders and re-route extensions in
`~/.config/organize-downloads/rules.conf`. A clickable `.app` also allows
manual runs.

Deliverables on disk after install:

1. `~/bin/organize-downloads.sh` - the sorter script (the worker).
2. `~/Applications/OrganizeDownloads.app` - AppleScript applet wrapping the
   worker (manual trigger + TCC attribution).
3. `~/Library/LaunchAgents/local.organize-downloads.plist` - launchd agent
   (rendered from `com.organize-downloads.plist.template`).
4. `~/.config/organize-downloads/rules.conf` - user rules (seeded from the
   repo's `rules.conf`, never overwritten).
5. Log files at `~/Library/Logs/organize-downloads.log` and `.err`.

---

# Part 1: Install this repo

## Preconditions to verify

1. The user is on macOS and has write access to `~/Library/LaunchAgents/`,
   `~/bin/`, and `~/Applications/`.
2. The repo is already a working copy at some absolute path - let
   `REPO=$(pwd)` after `cd`-ing into it.
3. `osacompile` and `launchctl` are on `PATH` (both ship with macOS).

## Install (happy path)

```bash
cd <path-to-this-repo>
chmod +x ./install.sh
./install.sh install
```

`install.sh` will:

1. Copy `organize-downloads.sh` -> `~/bin/organize-downloads.sh` (0700).
2. Seed `~/.config/organize-downloads/rules.conf` from the repo's
   `rules.conf` if none exists.
3. `osacompile` a one-line AppleScript into
   `~/Applications/OrganizeDownloads.app` that runs the worker. An existing
   applet that already wraps `~/bin/organize-downloads.sh` is KEPT: replacing
   the bundle resets its TCC grant and macOS would re-prompt for Downloads
   access.
4. Render `com.organize-downloads.plist.template` into
   `~/Library/LaunchAgents/local.organize-downloads.plist`, substituting
   `__LABEL__` / `__HOME__` / `__REPO__`.
5. `launchctl bootstrap gui/$(id -u)` the plist.

## Verify the install

```bash
./install.sh status                   # should not print "not running"
./install.sh run                      # one-off manual sweep
ls ~/Downloads                        # sorted layout
tail ~/Library/Logs/organize-downloads.log
```

Drop a test file (any `.pdf` / `.png`) into `~/Downloads` and watch the log;
the file should move into the matching subfolder within ~10s. Note the worker
ignores files modified in the last 5 seconds, so a just-created test file is
picked up on the next trigger.

## Permission prompt walkthrough (tell the user)

First touch of `~/Downloads` triggers macOS's file-access prompt attributed
to "OrganizeDownloads". If the user dismisses it, guide them to
**System Settings -> Privacy & Security -> Files and Folders ->
OrganizeDownloads -> Downloads Folder: ON**.

## Uninstall

```bash
./install.sh uninstall
```

Removes the launchd agent, the plist, `~/bin/organize-downloads.sh`, and the
`.app` wrapper. The user's `~/Downloads` folder, its contents, and
`~/.config/organize-downloads/` are untouched.

---

# Part 2: Build spec (`organize-downloads.sh`)

The script is a config-driven rules engine (bash 3.2 compatible, so no
associative arrays). See the reference implementation for the exact shape.

- **Logging.** When stdout is not a terminal, the worker appends directly to
  `~/Library/Logs/organize-downloads.log` / `.err` (AppleScript's
  `do shell script` swallows stdout, so launchd's StandardOutPath never sees
  worker output). Self-rotates at 5 MB to a single `.old` copy. Manual
  terminal runs print to the screen.
- **Rules.** Built-in defaults (a heredoc of `prefix <Folder> <literal>` and
  `ext <Folder> <ext...>` lines) are parsed first, then the user conf at
  `~/.config/organize-downloads/rules.conf` through the SAME parser. Lookups
  keep the LAST match, so user rules override defaults. The conf is honored
  only if it is a regular, user-owned, non-symlink file. Category names are
  validated (`[A-Za-z0-9._-]`, no leading dot); extensions are restricted to
  `[a-z0-9]` after lowercasing. Globbing is disabled (`set -f`) while
  word-splitting rule values.
- **Routing order per file:** prefix rules, then extension rules matched
  case-insensitively via lowercasing, then the dynamic fallback.
- **Dynamic fallback.** A file matching no rule gets a folder named after its
  uppercased extension (`report.stl` -> `STL/`), created `0700` on the fly.
  Names longer than 12 chars after sanitizing to `[A-Z0-9]`, or empty, fall
  back to the `other_to` folder (default `Other/`), as do extensionless
  files. Auto-created folder names persist in
  `~/.config/organize-downloads/dynamic-categories` so later runs keep
  protecting them from the stray-folder sweep. Settings `dynamic_folders
  on|off` and `other_to <Folder>` control this.
- **Browser-compat links.** After each move, leave a Finder-hidden
  (`chflags -h hidden`) RELATIVE symlink at the original path pointing to
  `<Folder>/<name>` so Chromium "Open"/"Show in Finder" buttons survive the
  move. At sweep start, prune ONLY symlinks that look self-created (relative
  target, one subdir deep, into a protected category) when the target is
  gone or the link is older than `compat_link_days` (default 7). Settings:
  `compat_links on|off`.
- Skip in-progress downloads (`*.crdownload`, `*.part`, `*.download`,
  `*.tmp`), dotfiles, symlinks, and files modified in the last 5 seconds.
- On name collision, rename to `dup_<epoch>_<orig>` (never overwrite; `mv -n`).
- Folders are created on demand (`mkdir -m 0700`), not pre-created.
- After file routing, move any remaining top-level **directory** into
  `Folders/`, except protected category folders (built-in, user-defined, and
  dynamic). Skip directories modified in the last 5 seconds.
- Use `shopt -s nullglob` so empty globs don't error; pass every filename
  after `--`; take a `mkdir`-based single-instance lock with a 600s stale
  break; `set -u`; `umask 077`; every failure path exits 0.

## launchd plist

- `Label`: `local.organize-downloads`
- `ProgramArguments`: `__HOME__/Applications/OrganizeDownloads.app/Contents/MacOS/applet`
  (so the AppleScript -> shell chain runs with proper TCC prompts).
- `WatchPaths`: `["$HOME/Downloads"]` (substitute `__HOME__` at install time)
- `ThrottleInterval`: `10` (seconds between triggers)
- `StartInterval`: `300` (5-minute fallback sweep)
- `StandardOutPath` / `StandardErrorPath`:
  `~/Library/Logs/organize-downloads.log` / `.err` (backstop only; the worker
  writes the log itself, see Logging above)
- `Umask`: `63` (octal 0077), `ProcessType`: `Background`, pinned system `PATH`.
- Load with `launchctl bootstrap gui/$(id -u) <rendered-plist>`.

## AppleScript applet

Single line: `do shell script "$HOME/bin/organize-downloads.sh"` (resolved at
install time). Save as Application via
`osacompile -o ~/Applications/OrganizeDownloads.app`. User grants Downloads
folder access (or Full Disk Access) on first run.

## Verification steps for the agent

1. `chmod +x ~/bin/organize-downloads.sh` and run it once manually; confirm
   no errors on an empty `~/Downloads`.
2. Drop a test `.png`, `.pdf`, `WhatsApp Image 2025.jpg`, an unknown type
   like `test.zzz`, and a dummy folder into `~/Downloads`; backdate them
   (`touch -t`) past the 5s grace; rerun; confirm each lands in the right
   subfolder and `ZZZ/` was auto-created.
3. Add `ext Sane zzz` to `~/.config/organize-downloads/rules.conf`; rerun
   with a new `.zzz` file; confirm it lands in `Sane/`.
4. Bootstrap the launch agent;
   `launchctl print gui/$(id -u)/local.organize-downloads` should show the
   service.
5. Add a file to `~/Downloads`; within ~10s the log should record the run.
6. Run the adversarial verification script in `SECURITY.md`.

## Constraints

- Do NOT delete user files, ever. Only move (`mv -n`). The single exception:
  the script may remove the hidden browser-compat symlinks it created itself
  (and rotate its own log). Anything beyond that is a regression, tested for
  in `SECURITY.md`.
- Do NOT touch files matching in-progress-download patterns or dotfiles.
- Do NOT recurse into existing subfolders; operate only on the top level of
  `~/Downloads`.
- Do NOT hardcode any username anywhere - use `$HOME`, `$USER`, or the
  `__HOME__` / `__LABEL__` placeholders substituted by `install.sh`.
- Do NOT commit `~/Library/Logs/organize-downloads.*`; they're not in the
  repo, and `.DS_Store` is gitignored.

## Reference

- `SOP.md` - human-facing setup guide. Useful to paraphrase for the user.
- `SECURITY.md` - threat model, mitigations, verification script.
- `rules.conf` - user-facing rule syntax reference (seeded to
  `~/.config/organize-downloads/rules.conf` at install).
- `organize-downloads.sh` - reference implementation. Match its ordering and
  dup-handling exactly if you rewrite it.
