# Security - Downloads Organizer

This document records the security model of the auto-organizer, the
mitigations in place, and the tests used to verify them. Update whenever
you change the script or the launchd plist.

## Threat model

The organizer is triggered by launchd every time `~/Downloads/` changes
and processes whatever the user - or *something else* - drops there.
`~/Downloads/` is a hostile input surface: browsers, AirDrop, mail
attachments, torrent clients, and any app that opens a Save dialog can
write there. Assumed adversaries:

1. **A malicious filename** crafted to exploit the shell (`-rf`, `--help`,
   command-substitution markers, newlines).
2. **A malicious symlink** planted in `~/Downloads/` to redirect file
   moves outside the folder.
3. **A malicious category directory** - e.g. if the user (or another
   program) replaces `~/Downloads/Images` with a symlink to an
   attacker-controlled path.
4. **A race between two launchd triggers** operating on the same file.
5. **Log-file information leak** - `~/Library/Logs/organize-downloads.*`
   contain every filename ever processed.
6. **A hostile rules file** - `~/.config/organize-downloads/rules.conf`
   is parsed on every run; a crafted category name or extension token
   must not become a path traversal, glob expansion, or command.
7. **Symlink-deletion trickery** - the compat-link pruner removes
   symlinks; a planted symlink must not trick it into deleting anything
   but a link.

**Out of scope:** arbitrary code running as the user (it already owns
everything we can defend), macOS TCC bypass, physical access.

## Mitigations

### 1. Leading-dash filenames are neutralized
All shell commands that consume a user-controlled filename use the `--`
end-of-options separator (`mv -n --`, `stat -f %m --`, `cd --`,
`readlink --`, `ln -s --`) or a `./` prefix where a tool lacks `--`
support (`rm -- "./$l"`, `chflags -h hidden "./$f"`).

A file named `-rf` or `-i` can therefore not masquerade as an option.
Verified by test: dropping `-rf.stl` into `~/Downloads` results in a
successful move to `STL/-rf.stl` (not a `mv -rf` catastrophe).

### 2. Symlinked category directories are refused
Every category folder (`Images`, `PDFs`, `Folders`, dynamic ones, ...)
is checked with `dest_ok()` before any move:
- must be a real directory (not a symlink)
- must exist
- must be owned by the current user

A symlink attack such as `ln -s /etc ~/Downloads/Images` is logged and
the category is skipped. Files that would have routed to that category
stay in `~/Downloads` untouched. Verified by test.

### 3. Source symlinks are skipped; compat links are the only exception
`[ -L "$f" ]` in both the file and directory loops causes the script to
log-and-skip any symlink in `~/Downloads`. Prevents the organizer from
becoming a vector for shuffling arbitrary FS references around.
Verified by test: a `hosts-link.txt -> /etc/hosts` symlink stays put.

The browser-compat feature CREATES hidden relative symlinks after a
move and later REMOVES symlinks matching its own signature: relative
target, no `..` component, exactly one subdirectory deep, pointing into
a protected category folder, and dangling or older than
`compat_link_days`. Removal is `rm` on the link itself, which never
touches the target. Symlinks with absolute targets or any `..`
component are never touched. Worst case, a foreign symlink that mimics
the signature loses the link itself, never data.

### 4. Single-instance lock
An atomic `mkdir "$LOCK_DIR"` (at `~/Library/Caches/organize-downloads.lock`)
guards against launchd firing two concurrent runs on rapid download
activity. Stale locks older than 10 minutes are broken automatically.
A trap on `EXIT` cleans up on normal termination.

### 5. Tight file-system permissions
- Script (`~/bin/organize-downloads.sh`) - `0700`.
- Category directories created by the script - `0700` via `mkdir -m 0700`.
- User conf dir (`~/.config/organize-downloads`) - `0700`, seeded conf `0600`.
- Log files (`~/Library/Logs/organize-downloads.{log,err}`) - `0600`.
- Any file the launchd-invoked process creates inherits `Umask=63`
  (octal `0077`), configured in the plist.

### 6. Pre-flight sanity checks on `~/Downloads`
The script aborts (exit 0) before doing anything if `~/Downloads` is
missing, is a symlink, or isn't owned by the current user. Prevents the
tool from operating on unexpected targets - e.g. a hostile process
replaces `~/Downloads` with a symlink to `/tmp`.

### 7. Launchd plist is hardened
- `Umask=63` (decimal for `0077`) so any new file is 0600 / new dir 0700.
- `EnvironmentVariables.PATH=/usr/bin:/bin:/usr/sbin:/sbin` - no
  inherited `PATH` from weird shells; binaries resolve to system copies.
- `ProcessType=Background`.
- Runs as the user only. No `UserName`, no `root`.

### 8. `umask 077` set inside the script
Belt-and-suspenders over the plist value - if the script is ever run
manually (not under launchd), new files still inherit tight perms.

### 9. No destructive operations on user data
- Only `mv -n` is used on files. Collisions rename with a
  `dup_<epoch>_` prefix. Nothing is ever overwritten.
- The ONLY `rm` in the script targets the compat symlinks described in
  mitigation 3, plus `rmdir` on the (empty) lock directory. Auditable
  by `grep -nE '\brm(dir)?\b' organize-downloads.sh`.

### 10. Shell hygiene
- `set -u` catches unbound variables.
- All filename expansions are double-quoted.
- No `eval`, no `bash -c "$var"`, no dynamic command construction from
  filenames or rule values.
- Globs use `shopt -s nullglob` so empty matches don't trigger literal
  pattern processing.

### 11. Rules file parsing is constrained
- The conf is only honored if it is a regular file (not a symlink)
  owned by the current user.
- Category names must match `[A-Za-z0-9._-]+` and must not start with a
  dot: no `/`, no whitespace, no `..`, no hidden dirs, no traversal out
  of `~/Downloads`. Invalid names are logged and ignored.
- Extension tokens are lowercased and must match `[a-z0-9]+`.
- Globbing is disabled (`set -f`) while rule values are word-split, so
  a `*` in the conf stays a literal token and is then rejected.
- Numeric settings are digit-checked; enum settings accept only
  `on|off`. Unknown keywords are ignored with a log line, so a typo can
  never change behavior silently or abort a sweep.
- The same validation applies to lines read back from the
  `dynamic-categories` state file.
- Dynamic folder names are derived by stripping the extension to
  `[a-z0-9]` and uppercasing, capped at 12 chars; anything else falls
  back to the `other_to` folder.

## Verification script

Rerun whenever you change the organizer. It creates a sandbox Downloads
dir, plants adversarial inputs, runs the script, and asserts safe
behavior. Note the backdating: the organizer deliberately ignores files
modified in the last 5 seconds.

```bash
SCRIPT=$HOME/bin/organize-downloads.sh
TMP=$(mktemp -d); mkdir -p "$TMP/Downloads" "$TMP/Library/Caches" "$TMP/Library/Logs"
mkdir -p "$TMP/.config/organize-downloads"
printf 'ext Bad../evil pdf\next Sane stl\n' > "$TMP/.config/organize-downloads/rules.conf"
cd "$TMP/Downloads"
touch -- "-rf.stl" "normal.pdf" "photo.png" "WhatsApp Image 2025.jpg" "unknown.zzz"
mkdir "$TMP/evil_target"; ln -s "$TMP/evil_target" Images
ln -s /etc/hosts "hosts-link.txt"
touch -t 202001010000 -- * 2>/dev/null; touch -h -t 202001010000 -- * 2>/dev/null
HOME="$TMP" bash "$SCRIPT" 2>&1 | tail -12

# Assertions:
[ -z "$(ls "$TMP/evil_target")" ]           || { echo "FAIL: redirected via symlink"; exit 1; }
[ -f "$TMP/Downloads/photo.png" ]           || { echo "FAIL: file for symlinked category should stay put"; exit 1; }
[ -f "$TMP/Downloads/Sane/-rf.stl" ]        || { echo "FAIL: dash-filename not moved via conf rule"; exit 1; }
[ -f "$TMP/Downloads/PDFs/normal.pdf" ]     || { echo "FAIL: bad conf category not rejected"; exit 1; }
[ ! -e "$TMP/Downloads/Bad.." ]             || { echo "FAIL: traversal category created"; exit 1; }
[ -f "$TMP/Downloads/ZZZ/unknown.zzz" ]     || { echo "FAIL: dynamic folder not created"; exit 1; }
[ -L "$TMP/Downloads/hosts-link.txt" ]      || { echo "FAIL: source symlink was shuffled"; exit 1; }
[ -L "$TMP/Downloads/Images" ]              || { echo "FAIL: symlinked category was replaced"; exit 1; }
[ -L "$TMP/Downloads/normal.pdf" ]          || { echo "FAIL: compat link missing"; exit 1; }
echo OK
```

## Known residual risks

- **Filenames are logged.** If a download name is itself sensitive
  (`Q4 salary statement.pdf`), it appears in `~/Library/Logs/...`. The
  log is `0600`, but other processes running as you can still read it.
  Accept or rotate/redact.
- **Compat links expose new paths.** The hidden symlink at the old path
  reveals where a file moved to. Same-user visibility only; disable
  with `compat_links off` if that matters.
- **No at-rest encryption** on moved files. FileVault is assumed.
- **No content inspection.** A file named `cute-cat.png` that's actually
  a polyglot executable is still just moved into `Images/`. The
  organizer does not interpret content; it just moves by extension.
- **`mv` is not atomic across filesystems** - if `~/Downloads` and a
  category folder happen to straddle a mount point (unusual), a move
  becomes a copy-then-delete. Still never overwrites, but briefly
  exists in both places.
