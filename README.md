# Downloads Organizer

Tiny macOS utility that sorts new files in `~/Downloads` into typed subfolders
(`Images/`, `PDFs/`, `Videos/`, `Archives/`, ...) as they land. Runs on
file-system change via launchd, with an hourly fallback sweep. Nothing you
downloaded is ever deleted; name collisions are renamed `dup_<epoch>_<orig>`.

Highlights:

- **Config-driven.** Add your own folders and re-route extensions by editing
  one plain-text file. The built-in defaults stay as a base layer.
- **No file left behind.** A file whose type matches no rule gets a folder
  named after its extension, created automatically (`report.stl` lands in
  `STL/`), and every later file of that type follows it.
- **Browser-friendly.** After a file moves, the "Open" and "Show in Finder"
  buttons in Chrome-style download bars still work: a hidden link is left at
  the old path and cleaned up automatically a few days later.
- **Hardened.** Hostile filenames, planted symlinks, and concurrent runs are
  all handled. See `SECURITY.md` for the threat model.

## Install

```bash
git clone <this-repo> ~/Downloads-Organizer    # clone anywhere, install.sh is portable
cd ~/Downloads-Organizer
chmod +x install.sh
./install.sh install
```

`install.sh` will:

- Copy `organize-downloads.sh` to `~/bin/` (0700).
- Seed your personal rules file at `~/.config/organize-downloads/rules.conf`
  (never overwrites an existing one).
- Create a self-signed code-signing identity in your login keychain if one is
  not already there (no Apple Developer account needed; see below for why it
  matters), then build and sign the watcher app into
  `~/Applications/OrganizeDownloads.app` and register it with LaunchServices.
- Render the launchd plist into
  `~/Library/LaunchAgents/local.organize-downloads.plist` with your actual
  `$HOME` substituted, and `launchctl bootstrap` the agent.

### First-run permissions

Open **System Settings -> Privacy & Security -> Full Disk Access**, click
**+**, and add `~/Applications/OrganizeDownloads.app`. This is a one-time step.

Strictly you only need the categories your target folder falls under (Downloads
folder, or removable volumes if you organise an external drive), and macOS will
prompt for those on first run. Full Disk Access simply means it never has to ask
again if you later point it somewhere else.

**Why the app is signed.** macOS records a permission grant alongside the app's
designated requirement. Signed with a stable certificate that requirement is
`identifier "..." and certificate root = H"..."`, which every future rebuild
still satisfies. Signed ad-hoc it is a bare `cdhash`, so each rebuild looks like
a different app and macOS starts prompting all over again. The identity is named
by `$SIGN_IDENTITY`, or `~/.config/organize-downloads/sign-identity`, and should
stay stable once you have installed once. `./install.sh identity` creates it
without doing a full install.

## Use

Drop files in the folder you are organising. They move into the matching
subfolder about ten seconds later: the agent notices the change within 3s, waits
6s for the folder to go quiet (so a still-downloading file is not grabbed
mid-write), then sweeps. A 10-minute full sweep runs as a safety net. Stray
directories are gathered into `Folders/`, files with no extension into `Other/`.

By default the target is `~/Downloads`. To organise somewhere else, write the
path to `~/.config/organize-downloads/target`, or set `$ORGANIZE_DL` for a
single manual run.

```bash
./install.sh run          # manual sweep now
./install.sh status       # is the agent loaded?
tail -f ~/Library/Logs/organize-downloads.log
```

npm wrappers exist for the same things: `npm run setup | teardown | run |
status | logs | load | unload | reload | dashboard`.

## Customize: your own folders and rules

Edit `~/.config/organize-downloads/rules.conf`. It is read on every run, so
changes take effect immediately; no reinstall, no reload.

**Create a folder and attach file endings to it** with one line:

```
ext 3D-Prints stl 3mf gcode obj
```

That single line creates `~/Downloads/3D-Prints/` on first use and routes all
four extensions into it.

**Change where an ending goes** the same way. Your rules override the built-in
defaults (the defaults stay for everything you did not touch):

```
ext Data csv          # csv normally goes to Spreadsheets/
```

**Route by filename prefix** (checked before extensions):

```
prefix Invoices RE-   # RE-2026-001.pdf -> Invoices/
```

**Settings** (all optional):

```
other_to Unsorted        # folder for extensionless files (default Other)
dynamic_folders off      # off = unmatched files go to other_to instead of
                         # auto-created per-extension folders (default on)
compat_links off         # disable the browser-compat links (default on)
compat_link_days 14      # keep compat links longer (default 7)
```

The full commented syntax reference lives in `rules.conf` in this repo, which
is also the template seeded to `~/.config/organize-downloads/rules.conf`.

### Unknown file types

When a file matches no rule and `dynamic_folders` is on (the default), the
organizer creates a folder named after the uppercased extension and moves the
file there: the first `.torrent`-less oddity like `scene.blend` creates
`BLEND/`, and every `.blend` after it lands there too. These auto-created
folders are remembered in `~/.config/organize-downloads/dynamic-categories`
so they are treated as category folders from then on. To give such a type a
nicer home later, add an `ext` rule for it; new files follow the rule, and
you can drag the old folder's contents over whenever you like.

### Browser downloads keep working

Chromium-based browsers (Chrome, Edge, Brave, Arc) remember the download path
and their "Open" / "Show in Finder" buttons break when a file moves. The
organizer therefore leaves a Finder-hidden symlink at the original path
pointing at the file's new location, so those buttons keep working after the
move. The links are invisible in Finder, are removed automatically once the
target disappears or after `compat_link_days` days (default 7), and are the
only thing the organizer ever deletes.

## Dashboard

A read-only status page (category sizes, loose files, agent state, recent
moves):

```bash
python3 dashboard.py      # binds 127.0.0.1:8770
```

## Uninstall

```bash
./install.sh uninstall
```

Your files stay exactly where they landed. `~/.config/organize-downloads/`
and the sorted subfolders are left in place; delete them manually if you do
not want them.

## What it never does

- **Never deletes your files.** Only `mv -n` with a `dup_<epoch>_` prefix on
  collision. The only deletions ever performed are of the hidden
  browser-compat symlinks the organizer itself created.
- **Never touches in-progress downloads** (`.crdownload`, `.part`,
  `.download`, `.tmp`), dotfiles, or files modified in the last 5 seconds.
- **Never follows symlinks.** Symlinked source files or category folders are
  skipped defensively. See `SECURITY.md` for the full threat model.
- **Never runs as root.** User agent only.

## For AI coding agents

See `AGENTS.md`: part 1 is the install runbook, part 2 the full script spec
if you want to rebuild the sorter rather than just install it.
