#!/usr/bin/env bash
# Install/uninstall the Downloads Organizer launchd agent + AppleScript applet.
# Portable: detects the repo path it was run from, templates paths into the
# launchd plist, compiles the .app wrapper with osacompile, and loads launchd.
#
# Usage: ./install.sh {install|uninstall|status|run}   (default: install)
#
# What `install` puts on disk (all per-user, no sudo/root):
#   ~/bin/organize-downloads.sh ............. copy of the worker script (0700)
#   ~/Applications/OrganizeDownloads.app .... AppleScript applet wrapping it
#   ~/Library/LaunchAgents/local.organize-downloads.plist
#                                            ... launchd agent (paths templated)
#   ~/Library/Logs/organize-downloads.{log,err} ... created on first run
#
# IMPORTANT - path baking: the rendered plist hard-codes absolute $HOME paths,
# and ~/bin/organize-downloads.sh is a COPY (not a symlink) of the repo script.
# Editing the repo copy has no effect until you re-run `install`. Moving the
# repo does not break a completed install (the worker was copied into ~/bin),
# but a fresh `install` re-derives REPO from wherever install.sh now lives.
set -euo pipefail

# Absolute path to the repo this script lives in (so install works no matter
# where the repo was cloned and regardless of the caller's cwd).
REPO="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.organize-downloads"          # launchd agent label / plist basename
DEST_DIR="$HOME/Library/LaunchAgents"     # per-user launchd agents live here
DEST="$DEST_DIR/$LABEL.plist"             # rendered (path-substituted) plist
TEMPLATE="$REPO/com.organize-downloads.plist.template"  # source plist w/ __TOKENS__

BIN="$HOME/bin/organize-downloads.sh"             # installed worker copy
APP="$HOME/Applications/OrganizeDownloads.app"    # FDA holder launchd runs (hidden)

# render_plist
# Substitute the __LABEL__/__HOME__/__REPO__ placeholders in the plist template
# and emit the result on stdout (caller redirects it to DEST).
render_plist() {
  local escaped_home escaped_repo
  escaped_home="$(printf '%s' "$HOME" | sed 's/[&|\\]/\\&/g')"
  escaped_repo="$(printf '%s' "$REPO" | sed 's/[&|\\]/\\&/g')"
  sed \
    -e "s|__LABEL__|$LABEL|g" \
    -e "s|__HOME__|$escaped_home|g" \
    -e "s|__REPO__|$escaped_repo|g" \
    "$TEMPLATE"
}

# harden_applet <app-bundle>
# Force the applet's startup screen off. With OSAAppletShowStartupScreen set
# (Script Editor's "Startup Screen" checkbox), every launch pops a modal
# "Press Run to run this script, or Quit to quit" dialog and the applet blocks
# until someone clicks Run - which makes an unattended launchd agent useless.
# Idempotent, and a no-op when the flag is already false so it does not
# needlessly re-sign the bundle (re-signing changes the cdhash, which resets
# the app's Full Disk Access grant and makes macOS re-prompt).
harden_applet() {
  local app="$1" plist="$1/Contents/Info.plist" current
  [ -f "$plist" ] || return 0
  current="$(plutil -extract OSAAppletShowStartupScreen raw "$plist" 2>/dev/null || echo missing)"
  [ "$current" = "false" ] && return 0
  plutil -replace OSAAppletShowStartupScreen -bool false "$plist"
  # The edit invalidates the ad-hoc signature osacompile applied; re-sign so
  # the bundle stays valid on disk and keeps satisfying its designated req.
  codesign --force --sign - "$app" >/dev/null 2>&1 || true
  echo "disabled applet startup screen on $app"
}

# Subcommand dispatch (defaults to "install" when no argument is given).
case "${1:-install}" in
  install)
    # Install (or re-install) the agent. Idempotent: safe to run repeatedly to
    # pick up edits to organize-downloads.sh or the plist template.
    [ -f "$TEMPLATE" ] || { echo "missing template: $TEMPLATE"; exit 1; }
    [ -f "$REPO/organize-downloads.sh" ] || { echo "missing: $REPO/organize-downloads.sh"; exit 1; }

    mkdir -p "$HOME/bin" "$HOME/Applications" "$DEST_DIR" "$HOME/Library/Logs"
    chmod 0700 "$HOME/bin" 2>/dev/null || true

    # Copy the worker into ~/bin (owner-only). This is a COPY: re-run install
    # after editing the repo script for the change to take effect.
    cp "$REPO/organize-downloads.sh" "$BIN"
    chmod 0700 "$BIN"

    # Seed the user rules file (never overwrites an existing one). Users edit
    # ~/.config/organize-downloads/rules.conf to add folders or re-route
    # extensions; no reinstall needed, the worker reads it on every run.
    CONF_DIR="$HOME/.config/organize-downloads"
    if [ ! -e "$CONF_DIR/rules.conf" ] && [ -f "$REPO/rules.conf" ]; then
      mkdir -p "$CONF_DIR"
      chmod 0700 "$CONF_DIR" 2>/dev/null || true
      cp "$REPO/rules.conf" "$CONF_DIR/rules.conf"
      chmod 0600 "$CONF_DIR/rules.conf"
      echo "seeded $CONF_DIR/rules.conf"
    fi

    # Compile a tiny AppleScript applet that wraps the shell script. The .app
    # wrapper exists so macOS can attribute Full Disk / Downloads-folder access
    # to "OrganizeDownloads" instead of "osascript".
    #
    # Only (re)compile when the applet is missing or points elsewhere:
    # replacing the bundle resets its TCC grant and macOS would re-prompt for
    # Downloads access. The applet body never changes otherwise (it is a
    # single `do shell script` line; the worker logic lives in $BIN).
    if [ ! -x "$APP/Contents/MacOS/applet" ] \
       || ! osadecompile "$APP/Contents/Resources/Scripts/main.scpt" 2>/dev/null \
            | grep -qF "do shell script \"$BIN\""; then
      tmpdir="$(mktemp -d)"
      trap 'rm -rf "$tmpdir"' EXIT
      cat >"$tmpdir/OrganizeDownloads.applescript" <<EOF
do shell script "$BIN"
EOF
      rm -rf "$APP"
      osacompile -o "$APP" "$tmpdir/OrganizeDownloads.applescript"
      harden_applet "$APP"
      echo "compiled $APP"
    else
      # Re-assert the no-startup-screen flag even on the keep path: a bundle
      # exported from Script Editor (or an older install) can carry it set, and
      # that turns every unattended launchd run into a blocking "Press Run to
      # run this script" dialog.
      harden_applet "$APP"
      echo "kept existing $APP (already wraps $BIN)"
    fi

    # Render the plist with this machine's paths, then (re)load it into the
    # per-user GUI launchd domain. bootout first so a re-install replaces any
    # already-loaded copy; the leading `|| true` ignores "not currently loaded".
    render_plist >"$DEST"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$DEST"
    echo "loaded $LABEL"

    # Bootstrap: ensure ~/Downloads exists and pre-create category folders so
    # the user sees a fully organized layout immediately, without waiting for
    # the first file event to fire the launchd job.
    if [ ! -e "$HOME/Downloads" ]; then
      mkdir -m 0700 -- "$HOME/Downloads"
      echo "created $HOME/Downloads"
    fi
    if [ -d "$HOME/Downloads" ] && [ ! -L "$HOME/Downloads" ]; then
      "$BIN" || true
      echo "bootstrapped category folders in ~/Downloads"
    fi

    echo
    echo "on first run macOS may prompt for access to your Downloads folder."
    echo "grant it in System Settings -> Privacy & Security -> Files and Folders."
    echo "logs: ~/Library/Logs/organize-downloads.log  /  .err"
    ;;
  uninstall)
    # Unload the agent and remove the files install put on disk. Deliberately
    # leaves ~/Downloads and all sorted subfolders in place - uninstall never
    # touches the user's data.
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$DEST" "$BIN"
    rm -rf "$APP"
    echo "uninstalled $LABEL (the Downloads folder and its subfolders are left untouched)"
    ;;
  status)
    # Show whether launchd currently has the agent loaded (first few lines).
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | head -5 || echo "not running"
    ;;
  run)
    # One-off manual sweep: run the installed worker once, now. Requires a prior
    # `install` (it execs ~/bin/organize-downloads.sh, not the repo copy).
    exec "$BIN"
    ;;
  *)
    echo "usage: $0 {install|uninstall|status|run}"
    exit 1
    ;;
esac
