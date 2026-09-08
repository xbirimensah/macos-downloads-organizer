#!/bin/bash
# Organizes ~/Downloads by file type. Hardened, config-driven version.
#
# Rules:
#  - Built-in default rules (see load_default_rules below) map filename
#    prefixes and extensions to category folders under ~/Downloads.
#  - Users can add folders and remap extensions WITHOUT editing this script:
#    ~/.config/organize-downloads/rules.conf is read on every run and its
#    rules override the defaults (last match wins). One line per rule:
#        ext    <Folder> <ext1> [ext2 ...]     e.g.  ext 3DPrints stl 3mf gcode
#        prefix <Folder> <literal prefix>      e.g.  prefix Invoices RE-
#    plus settings:
#        other_to <Folder>            where extensionless files go (default Other)
#        dynamic_folders on|off       auto-create per-extension folders (default on)
#        compat_links on|off          browser-compat symlinks (default on)
#        compat_link_days <N>         prune compat links after N days (default 7)
#  - Any file whose extension matches NO rule gets a folder named after its
#    uppercased extension (e.g. report.stl -> STL/), created on the fly and
#    remembered in ~/.config/organize-downloads/dynamic-categories so the
#    stray-folder sweep never mistakes it for a stray directory.
#
# Browser compatibility:
#  - After moving a file, a Finder-hidden RELATIVE symlink is left at the
#    original path (~/Downloads/<name> -> <Category>/<name>) so the
#    "Open" / "Show in Finder" buttons in Chromium-style download UIs keep
#    working after the move. Links are pruned once their target disappears
#    or after compat_link_days days.
#
# Security properties:
#  - All user-controlled filenames are passed after `--` so a name like
#    `-rf` or `-i` can't be interpreted as an option flag by mv / stat / test.
#  - Category destination directories must be real, user-owned, non-symlink
#    directories. A symlinked `~/Downloads/Images` does NOT redirect files.
#  - Source symlinks are never followed or moved (compat links excepted:
#    the script deletes ONLY symlinks it created itself, identified by their
#    relative target inside a known category folder).
#  - rules.conf is only honored if it is a regular, user-owned, non-symlink
#    file; category names are validated before use (no dotfiles, no path
#    separators), extensions are restricted to [a-z0-9].
#  - Globbing is disabled while parsing rule values so a `*` in the conf
#    cannot expand to filenames.
#  - A mkdir-based lock prevents two launchd-triggered runs from racing.
#  - umask 077 on every file/dir the script creates.
#  - Abort if ~/Downloads is missing, a symlink, or not owned by this user.
#
# Never deletes user files. Files move with `mv -n` exclusively; on collision,
# renames with a `dup_<epoch>_` prefix. The only things ever removed are the
# compat symlinks this script itself created, its own abandoned relay temps,
# and the SOURCE of a cross-volume relay once the copy has been verified
# (see "Relay" below).
#
# Relay (optional):
#   A second folder, the inbox, is drained into the target before each
#   sweep. This covers the setup where browsers save straight to an external
#   volume while AirDrop, chat clients and Mail still drop into ~/Downloads:
#   whatever lands in the inbox is moved to the target, then sorted like
#   everything else. Configured by ~/.config/organize-downloads/inbox or
#   $ORGANIZE_INBOX. Same-volume relays are a rename; cross-volume relays
#   copy to a hidden temp name, verify, rename into place, then remove the
#   source.
#
# How it runs:
#   This script is the worker. OrganizeDownloads.app (a persistent launchd
#   agent, see agent/) polls the target and the inbox and runs this script
#   as a child on change and every 10 minutes. Safe to run by hand.
#
# Exit policy:
#   Every failure path exits 0 ("nothing to do" rather than "error"); the job
#   is best-effort and idempotent. Exit 3 is not a failure: some entries were
#   skipped because they were still being written, and the agent polls them
#   back with a short retry instead of waiting for the next sweep.

# Fail on use of unset variables; do NOT abort on individual command errors
# (a single failing mv should skip one file, not kill the whole sweep).
set -u
# Restrict permissions on everything we create (category dirs, lock, state).
umask 077

# The folder we organize. Resolution order, first match wins:
#   1. $ORGANIZE_DL                       - one-off override for a manual run
#   2. ~/.config/organize-downloads/target - the persistent choice
#   3. ~/Downloads                        - default
# Browsers can be pointed at an external volume, so the target is not
# necessarily inside $HOME and must not be assumed to be.
DL_TARGET_FILE="$HOME/.config/organize-downloads/target"
if [ -n "${ORGANIZE_DL:-}" ]; then
  DL="$ORGANIZE_DL"
elif [ -s "$DL_TARGET_FILE" ]; then
  DL="$(tr -d '\r\n' <"$DL_TARGET_FILE")"
else
  DL="$HOME/Downloads"
fi

# The inbox: a second folder whose top-level entries are relayed into $DL
# before the sweep (see the header). Resolution order, first match wins:
#   1. $ORGANIZE_INBOX                     - explicit; "off" or "" disables
#   2. none, when $ORGANIZE_DL is set      - an env-overridden target never
#                                            relays unless told to, so a
#                                            one-off run on ~/Documents cannot
#                                            drain ~/Downloads into it
#   3. ~/.config/organize-downloads/inbox  - the persistent choice
#   4. none
INBOX_FILE="$HOME/.config/organize-downloads/inbox"
if [ -n "${ORGANIZE_INBOX+set}" ]; then
  INBOX="$ORGANIZE_INBOX"
elif [ -n "${ORGANIZE_DL:-}" ]; then
  INBOX=""
elif [ -s "$INBOX_FILE" ]; then
  INBOX="$(tr -d '\r\n' <"$INBOX_FILE")"
else
  INBOX=""
fi
case "$INBOX" in off|none) INBOX="" ;; esac

# ORGANIZE_SKIP_DIRS=1 disables the stray-folder sweep. Needed when pointing
# the worker at a folder that already has a deliberate subfolder layout of its
# own (~/Documents, say), which the sweep would otherwise rake into Folders/.
SKIP_DIRS="${ORGANIZE_SKIP_DIRS:-0}"
LOCK_DIR="$HOME/Library/Caches/organize-downloads.lock" # single-instance lock
UID_ME="$(id -u)"                                       # current user's numeric UID

SETTLE_SECONDS=5            # entries modified more recently than this are left alone
EXIT_DEFERRED=3             # exit status: the settle guard left work for a retry
RELAY_TMP_PREFIX=".relay-"  # in-flight cross-volume copies: .relay-<pid>-<name>
DEFERRED=0                  # set once anything is skipped as still being written
RELAY_SAME_VOLUME=0
RELAY_RESULT=""

CONF_DIR="$HOME/.config/organize-downloads"   # user config + state
CONF="$CONF_DIR/rules.conf"                   # user rule overrides (optional)
DYN_STATE="$CONF_DIR/dynamic-categories"      # folders auto-created for new types

# Logging. The plist's StandardOutPath only captures the applet process, and
# AppleScript's `do shell script` swallows the worker's stdout entirely, so
# relying on launchd redirection leaves the log empty. Instead, when stdout is
# not a terminal (i.e. we run under the applet/launchd), append to the log
# files directly. Manual terminal runs still print to the screen.
LOG_FILE="$HOME/Library/Logs/organize-downloads.log"
ERR_FILE="$HOME/Library/Logs/organize-downloads.err"
if [ ! -t 1 ]; then
  # Rotate our own log once it passes 5 MB (keeps exactly one .old copy).
  if [ -f "$LOG_FILE" ] && [ ! -L "$LOG_FILE" ] \
     && [ "$(stat -f %z -- "$LOG_FILE" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    mv -f -- "$LOG_FILE" "$LOG_FILE.old" 2>/dev/null || true
  fi
  if [ -f "$ERR_FILE" ] && [ ! -L "$ERR_FILE" ] \
     && [ "$(stat -f %z -- "$ERR_FILE" 2>/dev/null || echo 0)" -gt 5242880 ]; then
    mv -f -- "$ERR_FILE" "$ERR_FILE.old" 2>/dev/null || true
  fi
  exec >>"$LOG_FILE" 2>>"$ERR_FILE"
fi

# log MESSAGE...
# Emit a timestamped, PID-tagged line.
log() {
  printf '%s [organize-downloads %d] %s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$*"
}

# ---------------------------------------------------------------------------
# Pre-flight safety checks on ~/Downloads.
if [ -L "$DL" ] || [ ! -d "$DL" ]; then
  log "abort: \$DL ($DL) is missing or is a symlink"
  exit 0
fi
if [ "$(stat -f %u -- "$DL" 2>/dev/null)" != "$UID_ME" ]; then
  log "abort: \$DL not owned by current user"
  exit 0
fi

# ORGANIZE_COMPAT=off skips the browser-compat symlinks for this run. Applied
# after the rules file is read so an explicit env override still wins.
COMPAT_OVERRIDE="${ORGANIZE_COMPAT:-}"

# ---------------------------------------------------------------------------
# Single-instance lock. mkdir is atomic on every POSIX FS, so a successful
# mkdir of LOCK_DIR is the lock acquisition.
mkdir -p "$(dirname -- "$LOCK_DIR")" 2>/dev/null || true
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Lock already held. Treat a lock older than 600s as stale (a previous run
  # was killed before its EXIT trap could clean up) and forcibly reclaim it.
  lock_mtime="$(stat -f %m -- "$LOCK_DIR" 2>/dev/null || echo 0)"
  if [ "$(( $(date +%s) - lock_mtime ))" -gt 600 ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    mkdir "$LOCK_DIR" 2>/dev/null || { log "abort: cannot acquire lock"; exit 0; }
  else
    log "skip: another run is in progress"
    exit 0
  fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

refresh_lock() {
  touch -c -- "$LOCK_DIR" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Rules engine (bash 3.2 compatible: no associative arrays).
#
# EXT_RULES     newline list of "<ext>\t<Category>" lines, lowercase ext.
# PREFIX_RULES  newline list of "<Category>\t<literal prefix>" lines.
# RULE_CATS     space-separated category names seen in any rule.
# Lookups scan ALL lines and keep the LAST match, so rules appended later
# (i.e. from the user conf) override the built-in defaults.
EXT_RULES=""
PREFIX_RULES=""
RULE_CATS=""
OTHER_CAT="Other"       # where extensionless / unnameable files go
DYNAMIC_FOLDERS="on"    # auto-create per-extension folders for unknown types
COMPAT_LINKS="on"       # leave browser-compat symlinks behind after a move
COMPAT_LINK_DAYS=7      # prune compat links after this many days

# valid_category NAME
# True if NAME is safe to use as a folder name directly under ~/Downloads:
# non-empty, no leading dot (also excludes . and ..), and only [A-Za-z0-9._-]
# characters (which excludes /, whitespace, and shell metacharacters).
valid_category() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# add_rule LINE
# Parse one rules line (from the built-in defaults or the user conf).
# Unknown keywords and malformed lines are ignored with a log entry, so a
# typo in rules.conf can never break the sweep.
add_rule() {
  local line="$1" kw rest cat val e
  case "$line" in ''|\#*) return 0 ;; esac
  kw="${line%%[[:space:]]*}"
  rest="${line#"$kw"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"   # ltrim
  rest="${rest%"${rest##*[![:space:]]}"}"   # rtrim
  case "$kw" in
    dynamic_folders)
      case "$rest" in on|off) DYNAMIC_FOLDERS="$rest" ;; *) log "rules: bad dynamic_folders value '$rest'" ;; esac
      return 0 ;;
    compat_links)
      case "$rest" in on|off) COMPAT_LINKS="$rest" ;; *) log "rules: bad compat_links value '$rest'" ;; esac
      return 0 ;;
    compat_link_days)
      case "$rest" in *[!0-9]*|'') log "rules: bad compat_link_days value '$rest'" ;; *) COMPAT_LINK_DAYS="$rest" ;; esac
      return 0 ;;
  esac
  cat="${rest%%[[:space:]]*}"
  val="${rest#"$cat"}"
  val="${val#"${val%%[![:space:]]*}"}"
  if ! valid_category "$cat"; then
    log "rules: ignored line with unsafe category '$cat'"
    return 0
  fi
  case "$kw" in
    ext)
      # Globbing off while word-splitting user input: a `*` in the conf must
      # stay a literal token (and then be rejected), never expand to files.
      set -f
      for e in $val; do
        e="$(printf '%s' "$e" | tr '[:upper:]' '[:lower:]')"
        case "$e" in ''|*[!a-z0-9]*) log "rules: ignored bad extension '$e'"; continue ;; esac
        EXT_RULES="${EXT_RULES}${e}	${cat}
"
      done
      set +f
      RULE_CATS="$RULE_CATS $cat"
      ;;
    prefix)
      [ -n "$val" ] || { log "rules: prefix rule for '$cat' missing a prefix"; return 0; }
      PREFIX_RULES="${PREFIX_RULES}${cat}	${val}
"
      RULE_CATS="$RULE_CATS $cat"
      ;;
    other_to)
      OTHER_CAT="$cat"
      ;;
    *)
      log "rules: ignored unknown keyword '$kw'"
      ;;
  esac
  return 0
}

# Built-in default rules. The user conf is loaded AFTER these, so any
# `ext <Folder> <ext>` line there re-routes that extension.
load_default_rules() {
  local line
  while IFS= read -r line; do add_rule "$line"; done <<'DEFAULT_RULES'
prefix Screenshots Screen Shot
prefix Screenshots Screenshot
prefix WhatsApp WhatsApp
ext Images png jpg jpeg webp gif heic svg bmp tiff tif ico icns avif jfif
ext Images raw cr2 cr3 nef arw dng orf rw2
ext Videos mp4 mov m4v avi mkv webm wmv flv mpg mpeg 3gp
ext Audio mp3 wav m4a flac aac ogg opus aiff aif wma mid midi amr
ext Spreadsheets xlsx xls xlsm csv numbers tsv ods
ext PDFs pdf
ext Documents pptx ppt docx doc md txt rtf pages key odt odp tex log
ext Installers dmg pkg mpkg msi exe apk ipa deb rpm appimage iso
ext Archives zip rar 7z tar gz tgz bz2 tbz2 xz zst jar
ext Code json js mjs ts tsx jsx py sh zsh bash rb go rs java c cc cpp h hpp
ext Code cs php sql css scss less ipynb swift kt lua pl ps1 bat cmd
ext Code yaml yml toml ini cfg conf xml plist
ext Design psd ai sketch fig xd eps indd afdesign afphoto
ext Fonts ttf otf woff woff2
ext Ebooks epub mobi azw azw3 cbz cbr
ext Subtitles srt vtt ass sub
ext HTML html htm xhtml mhtml webarchive
ext Calendar ics vcs
ext Contacts vcf
ext Torrents torrent
ext Certificates pem crt cer csr der p12 pfx
DEFAULT_RULES
}

# Load the user conf, if present and trustworthy (regular file, owned by the
# current user, not a symlink). Its rules override the defaults.
load_user_rules() {
  local line
  [ -e "$CONF" ] || return 0
  if [ -L "$CONF" ] || [ ! -f "$CONF" ]; then
    log "skip conf: $CONF is not a regular file"
    return 0
  fi
  if [ "$(stat -f %u -- "$CONF" 2>/dev/null)" != "$UID_ME" ]; then
    log "skip conf: $CONF not owned by current user"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do add_rule "$line"; done < "$CONF"
}

load_default_rules
load_user_rules

# ---------------------------------------------------------------------------
# Dynamic categories: folders this script auto-created for previously unknown
# extensions. Persisted so future runs keep protecting them from the
# stray-folder sweep even after rules or defaults change.
DYN_CATS=""
if [ -f "$DYN_STATE" ] && [ ! -L "$DYN_STATE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    valid_category "$line" || continue
    DYN_CATS="$DYN_CATS $line"
  done < "$DYN_STATE"
fi

# remember_dynamic NAME
# Record NAME as a script-created category (in memory + on disk, deduped).
remember_dynamic() {
  case " $DYN_CATS " in *" $1 "*) return 0 ;; esac
  DYN_CATS="$DYN_CATS $1"
  mkdir -p -- "$CONF_DIR" 2>/dev/null || true
  printf '%s\n' "$1" >> "$DYN_STATE" 2>/dev/null \
    || log "warn: could not persist dynamic category '$1'"
}

# is_protected NAME
# True if NAME is a category folder (built-in, user-defined, or dynamic).
# Protected folders are move destinations and are never swept into Folders/.
is_protected() {
  local name="$1" p
  for p in $RULE_CATS Folders "$OTHER_CAT" $DYN_CATS; do
    [ "$name" = "$p" ] && return 0
  done
  return 1
}

case "$COMPAT_OVERRIDE" in
  on|off) COMPAT_LINKS="$COMPAT_OVERRIDE" ;;
  '') ;;
  *) log "rules: bad ORGANIZE_COMPAT value '$COMPAT_OVERRIDE'" ;;
esac

log "target: $DL (inbox=${INBOX:-none} skip_dirs=$SKIP_DIRS compat_links=$COMPAT_LINKS)"

cd -- "$DL" || { log "abort: cd $DL failed"; exit 0; }

# dest_ok DIR
# True only if DIR is a safe move target: a real directory (not a symlink)
# owned by the current user. Guards against a planted symlink redirecting
# moves outside ~/Downloads.
dest_ok() {
  local d="$1"
  [ -L "$d" ] && return 1
  [ -d "$d" ] || return 1
  [ "$(stat -f %u -- "$d" 2>/dev/null)" = "$UID_ME" ] || return 1
  return 0
}

# ensure_category DIR
# Create category DIR (0700) if missing, then verify it is a safe target.
ensure_category() {
  local c="$1"
  if [ -L "$c" ]; then
    log "skip: $c is a symlink, refusing to use it (remove manually)"
    return 1
  fi
  if [ ! -e "$c" ]; then
    mkdir -m 0700 -- "$c" 2>/dev/null || { log "mkdir $c failed"; return 1; }
    log "created category: $c"
  fi
  dest_ok "$c" || { log "skip category: $c not a safe destination"; return 1; }
  return 0
}

# Make unmatched globs expand to nothing rather than the literal pattern.
shopt -s nullglob

# ---------------------------------------------------------------------------
# Relay: drain the top level of $INBOX into $DL so the sweep below sorts it
# like anything that landed in $DL directly. On the same volume a relay is a
# rename. Across volumes it is copy -> verify -> rename into place -> remove
# the source, with the copy under a hidden temp name so nothing half-written
# is ever visible under its final name. Removing the source is the one place
# this script deletes a user file, and only ever a verified duplicate.

# is_settled PATH
# True unless PATH (or, for a directory, anything inside it) changed within
# the last SETTLE_SECONDS. An app that writes in place with no temp-name
# convention may still be mid-write; leave it and ask for a retry.
is_settled() {
  local p="$1" mtime
  if [ -d "$p" ]; then
    [ -z "$(find "$p" -mtime "-${SETTLE_SECONDS}s" -print -quit 2>/dev/null)" ] && return 0
  else
    mtime="$(stat -f %m -- "$p" 2>/dev/null || echo 0)"
    [ "$mtime" -gt 0 ] && [ "$(( $(date +%s) - mtime ))" -ge "$SETTLE_SECONDS" ] && return 0
  fi
  DEFERRED=1
  return 1
}

# tree_sig PATH
# "<regular file count> <total bytes>" for a file or a directory tree.
# AppleDouble "._*" sidecars are ignored: exFAT volumes add them on their own
# and they would make every verified copy look different from its source.
tree_sig() {
  if [ -d "$1" ]; then
    find "$1" -type f ! -name '._*' -exec stat -f %z -- {} + 2>/dev/null \
      | awk '{ n++; s += $1 } END { printf "%d %d", n + 0, s + 0 }'
  else
    stat -f '1 %z' -- "$1" 2>/dev/null || printf '0 0'
  fi
}

# free_name NAME
# NAME if nothing in $DL has it, else a dup_<epoch>_ prefixed variant.
free_name() {
  if [ -e "$DL/$1" ] || [ -L "$DL/$1" ]; then
    printf 'dup_%s_%s' "$(date +%s)" "$1"
  else
    printf '%s' "$1"
  fi
}

# prune_relay_temps
# In-flight copies are named .relay-<pid>-<name>. One whose pid is gone was
# abandoned by a run that died mid-copy; its source is still in the inbox,
# so the temp is a partial duplicate and never the only copy.
prune_relay_temps() {
  local t rest pid
  for t in "$DL/$RELAY_TMP_PREFIX"*; do
    [ -e "$t" ] || [ -L "$t" ] || continue
    rest="${t##*/}"
    rest="${rest#"$RELAY_TMP_PREFIX"}"
    pid="${rest%%-*}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && continue
    rm -rf -- "$t" && log "pruned abandoned relay copy: ${t##*/}"
  done
}

# relay_copy NAME DEST
# Cross-volume relay of $INBOX/NAME to $DL/DEST; sets RELAY_RESULT to the
# final name. The lock is refreshed while the copy runs so a large file
# cannot outlive the stale-lock window.
relay_copy() {
  local name="$1" dest="$2" src tmp pid rc
  src="$INBOX/$name"
  tmp="$DL/$RELAY_TMP_PREFIX$$-$dest"
  ditto --norsrc --noextattr --noacl -- "$src" "$tmp" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.25
    refresh_lock
  done
  wait "$pid"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -rf -- "$tmp"
    log "relay copy failed (exit $rc): $name (source kept)"
    return 1
  fi
  if [ "$(tree_sig "$src")" != "$(tree_sig "$tmp")" ]; then
    rm -rf -- "$tmp"
    log "relay verify failed: $name (source kept)"
    return 1
  fi
  dest="$(free_name "$dest")"
  mv -n -- "$tmp" "$DL/$dest" || { rm -rf -- "$tmp"; log "relay rename failed: $name (source kept)"; return 1; }
  if [ -e "$tmp" ] || [ -L "$tmp" ]; then
    rm -rf -- "$tmp"
    log "relay rename declined: $name (source kept)"
    return 1
  fi
  rm -rf -- "$src"
  if [ -e "$src" ] || [ -L "$src" ]; then
    log "warn: relayed $name but its source could not be removed (both copies exist)"
  fi
  RELAY_RESULT="$dest"
  return 0
}

# relay_one NAME
relay_one() {
  local name="$1" dest
  dest="$(free_name "$name")"
  if [ "$RELAY_SAME_VOLUME" = 1 ]; then
    mv -n -- "$INBOX/$name" "$DL/$dest" || { log "relay mv failed: $name"; return 1; }
    if [ -e "$INBOX/$name" ] || [ -L "$INBOX/$name" ]; then
      log "skip: relay move declined for $name"
      return 1
    fi
  else
    RELAY_RESULT=""
    relay_copy "$name" "$dest" || return 1
    dest="$RELAY_RESULT"
  fi
  if [ "$dest" = "$name" ]; then
    log "relayed: $name -> $DL/"
  else
    log "relayed (dup): $name -> $DL/$dest"
  fi
  return 0
}

# relay_inbox
# Pre-flight the inbox with the same suspicion as the target, then relay
# every settled top-level entry. Symlinks are never followed or moved.
relay_inbox() {
  local entry name
  [ -n "$INBOX" ] || return 0
  INBOX="${INBOX%/}"
  case "$INBOX" in /*) ;; *) log "relay: inbox must be an absolute path: $INBOX"; return 0 ;; esac
  if [ "$INBOX" = "$DL" ]; then
    log "relay: inbox is the target, nothing to relay"
    return 0
  fi
  case "$DL/" in "$INBOX"/*) log "relay: refusing, target is inside inbox"; return 0 ;; esac
  case "$INBOX/" in "$DL"/*) log "relay: refusing, inbox is inside target"; return 0 ;; esac
  if [ -L "$INBOX" ] || [ ! -d "$INBOX" ]; then
    log "relay: inbox missing or a symlink: $INBOX"
    return 0
  fi
  if [ "$(stat -f %u -- "$INBOX" 2>/dev/null)" != "$UID_ME" ]; then
    log "relay: inbox not owned by current user: $INBOX"
    return 0
  fi
  if [ "$(stat -f %d -- "$INBOX" 2>/dev/null)" = "$(stat -f %d -- "$DL" 2>/dev/null)" ]; then
    RELAY_SAME_VOLUME=1
  else
    RELAY_SAME_VOLUME=0
  fi
  prune_relay_temps
  for entry in "$INBOX"/*; do
    refresh_lock
    name="${entry##*/}"
    [ -e "$entry" ] || continue
    [ -L "$entry" ] && continue
    case "$name" in *.crdownload|*.part|*.download|*.tmp) continue ;; esac
    is_settled "$entry" || continue
    relay_one "$name"
  done
}
relay_inbox

# ---------------------------------------------------------------------------
# Prune compat symlinks. Only symlinks THIS script plausibly created are
# touched: top-level symlinks whose target is a bare RELATIVE path into a
# protected category folder. Removed once the target is gone (user deleted or
# renamed the file) or after COMPAT_LINK_DAYS days.
prune_compat_links() {
  local l tgt top lm now
  now="$(date +%s)"
  for l in *; do
    [ -L "$l" ] || continue
    tgt="$(readlink -- "$l" 2>/dev/null)" || continue
    case "$tgt" in /*|*../*|../*) continue ;; esac   # absolute or traversal: not ours
    top="${tgt%%/*}"
    [ "$top" = "$tgt" ] && continue                   # no subdir component: not ours
    is_protected "$top" || continue
    if [ ! -e "$l" ]; then
      rm -- "./$l" 2>/dev/null && log "pruned dangling compat link: $l"
      continue
    fi
    lm="$(stat -f %m -- "$l" 2>/dev/null || echo 0)"  # lstat: the link itself
    if [ "$lm" -gt 0 ] && [ "$(( now - lm ))" -gt "$(( COMPAT_LINK_DAYS * 86400 ))" ]; then
      rm -- "./$l" 2>/dev/null && log "pruned expired compat link: $l"
    fi
  done
}
prune_compat_links

# ---------------------------------------------------------------------------
# move_one DEST FILE
# Move FILE into category folder DEST. On a name collision in DEST the file
# is renamed with a `dup_<epoch>_` prefix so nothing is ever overwritten.
# Afterwards (if compat_links is on) a Finder-hidden relative symlink is left
# at the original path so browser "Open" / "Show in Finder" buttons that
# remember the old path still resolve.
move_one() {
  local dest="$1" f="$2" target moved=0
  if [ -e "$dest/$f" ] || [ -L "$dest/$f" ]; then
    target="dup_$(date +%s)_$f"
  else
    target="$f"
  fi
  mv -n -- "$f" "$dest/$target" || { log "mv failed: $f"; return 1; }
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    moved=1
  elif [ "$target" = "$f" ]; then
    target="dup_$(date +%s)_$f"
    mv -n -- "$f" "$dest/$target" || { log "mv retry failed: $f"; return 1; }
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then
      moved=1
    fi
  fi
  if [ "$moved" -ne 1 ]; then
    log "skip: move declined for $f"
    return 1
  fi
  if [ "$target" = "$f" ]; then
    log "moved: $f -> $dest/"
  else
    log "moved (dup): $f -> $dest/"
  fi
  if [ "$COMPAT_LINKS" = "on" ] && [ ! -e "$f" ] && [ ! -L "$f" ]; then
    if ln -s -- "$dest/$target" "$f" 2>/dev/null; then
      chflags -h hidden "./$f" 2>/dev/null || true
      log "compat link: $f -> $dest/$target"
    fi
  fi
  return 0
}

move_dir_one() {
  local dest="$1" name="$2" target moved=0
  if [ -e "$dest/$name" ] || [ -L "$dest/$name" ]; then
    target="dup_$(date +%s)_$name"
  else
    target="$name"
  fi
  mv -n -- "$name" "$dest/$target" || { log "mv dir failed: $name"; return 1; }
  if [ ! -e "$name" ] && [ ! -L "$name" ]; then
    moved=1
  elif [ "$target" = "$name" ]; then
    target="dup_$(date +%s)_$name"
    mv -n -- "$name" "$dest/$target" || { log "mv dir retry failed: $name"; return 1; }
    if [ ! -e "$name" ] && [ ! -L "$name" ]; then
      moved=1
    fi
  fi
  if [ "$moved" -ne 1 ]; then
    log "skip: directory move declined for $name"
    return 1
  fi
  if [ "$target" = "$name" ]; then
    log "moved dir: $name -> $dest/"
  else
    log "moved dir (dup): $name -> $dest/"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# category_for FILE (echoes the category name, or nothing if no rule matched)
category_for_prefix() {
  local f="$1" out="" rcat rpre
  [ -n "$PREFIX_RULES" ] || return 0
  while IFS='	' read -r rcat rpre; do
    [ -n "$rcat" ] || continue
    case "$f" in "$rpre"*) out="$rcat" ;; esac
  done <<EOF
$PREFIX_RULES
EOF
  printf '%s' "$out"
}

category_for_ext() {
  local e="$1" out="" rext rcat
  [ -n "$EXT_RULES" ] || return 0
  while IFS='	' read -r rext rcat; do
    [ "$rext" = "$e" ] && out="$rcat"
  done <<EOF
$EXT_RULES
EOF
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Main sweep: route every top-level regular file.
#   1. prefix rules (e.g. "WhatsApp Image ....jpg" -> WhatsApp/)
#   2. extension rules, matched case-insensitively via lowercasing
#   3. no rule matched: auto-create a folder named after the uppercased
#      extension (report.stl -> STL/), or OTHER_CAT for extensionless files
now_epoch="$(date +%s)"
for f in *; do
  refresh_lock
  [ -e "$f" ] || continue
  [ -L "$f" ] && continue          # compat links and foreign symlinks alike
  [ -f "$f" ] || continue          # directories handled by the sweep below
  case "$f" in
    *.crdownload|*.part|*.download|*.tmp) continue ;;
  esac
  # Grace period: a file modified in the last SETTLE_SECONDS may still be
  # being written by an app that does not use a temp-name convention.
  mtime="$(stat -f %m -- "$f" 2>/dev/null || echo 0)"
  [ "$mtime" -gt 0 ] || continue
  if [ "$(( now_epoch - mtime ))" -lt "$SETTLE_SECONDS" ]; then
    DEFERRED=1
    continue
  fi

  cat="$(category_for_prefix "$f")"
  if [ -z "$cat" ]; then
    ext="${f##*.}"
    if [ "$ext" != "$f" ] && [ -n "$ext" ]; then
      lext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
      cat="$(category_for_ext "$lext")"
      if [ -z "$cat" ] && [ "$DYNAMIC_FOLDERS" = "on" ]; then
        # Unknown type: name a folder after the extension. Strip anything
        # outside [a-z0-9]; bail to OTHER_CAT on empty or absurdly long.
        cat="$(printf '%s' "$lext" | tr -cd 'a-z0-9' | tr '[:lower:]' '[:upper:]')"
        if [ -z "$cat" ] || [ "${#cat}" -gt 12 ]; then cat="$OTHER_CAT"; fi
      fi
      [ -z "$cat" ] && cat="$OTHER_CAT"
    else
      cat="$OTHER_CAT"
    fi
  fi

  ensure_category "$cat" || continue
  is_protected "$cat" || remember_dynamic "$cat"
  move_one "$cat" "$f"
done

# ---------------------------------------------------------------------------
# Stray-folder sweep: move any other top-level directory in ~/Downloads into
# Folders/, except protected category folders (built-in, user-defined, and
# dynamic). Directory symlinks are skipped (never followed).
if [ "$SKIP_DIRS" = "1" ]; then
  log "skip: stray-folder sweep disabled (ORGANIZE_SKIP_DIRS=1)"
elif ensure_category "Folders"; then
  for d in */; do
    refresh_lock
    name="${d%/}"
    is_protected "$name" && continue
    [ -L "$name" ] && { log "skip dir symlink: $name"; continue; }
    mtime="$(stat -f %m -- "$name" 2>/dev/null || echo 0)"
    [ "$mtime" -gt 0 ] || continue
    # Grace period: don't grab a folder modified in the last SETTLE_SECONDS;
    # it may still be mid-extraction (an unzipping archive) and incomplete.
    if [ "$(( $(date +%s) - mtime ))" -lt "$SETTLE_SECONDS" ]; then
      DEFERRED=1
      continue
    fi
    move_dir_one "Folders" "$name"
  done
else
  log "skip: Folders/ not a safe destination"
fi

# ---------------------------------------------------------------------------
# Anything skipped for still being written is reported to the agent through
# the exit status so it can poll back soon instead of waiting for the next
# periodic sweep. Not an error.
if [ "$DEFERRED" = 1 ]; then
  log "deferred: entries still being written were left for a retry"
  exit "$EXIT_DEFERRED"
fi
exit 0
