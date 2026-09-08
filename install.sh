#!/usr/bin/env bash
# Install/uninstall the Downloads Organizer launchd agent + Swift watcher app.
# Portable: detects the repo path it was run from, templates paths into the
# launchd plist, builds and signs the .app, and loads launchd.
#
# Usage: ./install.sh {install|uninstall|status|run|identity}  (default: install)
#
# What `install` puts on disk (all per-user, no sudo/root):
#   ~/bin/organize-downloads.sh ............. copy of the worker script (0700)
#   ~/Applications/OrganizeDownloads.app .... persistent Swift watcher agent
#   ~/Library/LaunchAgents/local.organize-downloads.plist
#                                            ... launchd agent (paths templated)
#   ~/Library/Logs/organize-downloads{,-agent}.log ... created on first run
#
# WHY THE APP IS A SIGNED SWIFT BUNDLE, NOT AN APPLESCRIPT APPLET
# The applet this replaced had no CFBundleIdentifier, so macOS could not map its
# executable back to its bundle ("attributed bundle: (null)" in the tccd log).
# TCC then keyed every grant to the executable's FILE PATH instead of an app
# identity, which meant the Full Disk Access checkbox the user had ticked -
# stored against the .app path - was never consulted, and the app fell back to
# per-folder consent prompts forever. Two properties fix that permanently:
#
#   1. CFBundleIdentifier  -> TCC keys grants to the bundle ID (client_type 0)
#                             rather than a fragile filesystem path.
#   2. A stable signing identity -> the designated requirement becomes
#                             `identifier "..." and certificate root = H"..."`
#                             with NO cdhash, so grants survive every rebuild.
#                             Ad-hoc signing pins a cdhash, so each rebuild
#                             silently invalidated the grant and re-prompted.
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
AGENT_SRC="$REPO/agent"                           # Swift sources + build.sh
BUNDLE_ID="local.organize-downloads"              # must match agent/build.sh
# Name of the code-signing identity in the login keychain. Resolution order:
#   1. $SIGN_IDENTITY
#   2. ~/.config/organize-downloads/sign-identity
#   3. the generic default below
# Keep this stable once an install exists: renaming it makes ensure_identity
# mint a DIFFERENT certificate, which changes the app's designated requirement
# and resets its TCC grants. The config file exists so an existing install can
# keep its original certificate name without that name living in the repo.
SIGN_IDENTITY_FILE="$HOME/.config/organize-downloads/sign-identity"
if [ -z "${SIGN_IDENTITY:-}" ] && [ -s "$SIGN_IDENTITY_FILE" ]; then
  SIGN_IDENTITY="$(tr -d '\r\n' <"$SIGN_IDENTITY_FILE")"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:-Downloads Organizer Local Signing}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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

# ensure_identity
# Make sure a code-signing identity named $SIGN_IDENTITY exists in the login
# keychain, creating a self-signed one if not.
#
# This is the single most important part of the install. TCC records a grant
# together with the app's designated requirement. Signed with a stable cert the
# requirement is `identifier "..." and certificate root = H"..."`, which every
# future rebuild still satisfies. Signed ad-hoc it is a bare cdhash, so every
# rebuild produces a "different app" and macOS starts prompting again.
#
# No Apple Developer account is needed - the cert never leaves this machine and
# is only ever used to give the bundle a stable identity.
ensure_identity() {
  if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    return 0
  fi

  echo "creating self-signed code-signing identity: $SIGN_IDENTITY"
  local tmp
  tmp="$(mktemp -d)"

  cat >"$tmp/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = $SIGN_IDENTITY
O  = Local Development
[ v3 ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

  openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 7300 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/openssl.cnf" >/dev/null 2>&1

  # macOS's PKCS12 reader rejects OpenSSL 3's modern defaults, so force the
  # legacy PBE algorithms it can actually parse.
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/identity.p12" -passout pass:temp -name "$SIGN_IDENTITY" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 >/dev/null 2>&1

  security import "$tmp/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P temp -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null

  # Trust it for code signing at the USER level only; this needs no sudo and no
  # GUI authorization, unlike adding it to the System keychain.
  security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$tmp/cert.pem"

  rm -rf "$tmp"

  security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY" \
    || { echo "failed to create signing identity"; exit 1; }
  echo "identity created"
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
    #
    # DRIFT GUARD. This copy once destroyed uncommitted work: changes had been
    # made directly to the installed copy and never brought back here, so a
    # routine install silently reverted the worker to an older version and it
    # organised the wrong folder for days. Refuse to overwrite an installed
    # worker that differs from this one AND is newer, since that is exactly the
    # shape of "someone edited ~/bin and it was never synced back".
    if [ -f "$BIN" ] && ! cmp -s "$REPO/organize-downloads.sh" "$BIN"; then
      if [ "$BIN" -nt "$REPO/organize-downloads.sh" ] && [ "${FORCE:-0}" != "1" ]; then
        echo "refusing to overwrite a newer installed worker."
        echo
        echo "  installed: $BIN"
        echo "  repo:      $REPO/organize-downloads.sh"
        echo
        echo "The installed copy is newer and differs, so it probably carries"
        echo "edits that were never brought back to the repo. Inspect them:"
        echo
        echo "  diff \"$REPO/organize-downloads.sh\" \"$BIN\""
        echo
        echo "Then either copy them back into the repo, or re-run with FORCE=1"
        echo "to discard the installed copy."
        exit 1
      fi
      echo "replacing installed worker (repo copy is newer)"
    fi
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

    # Build and install the watcher app. Unlike the old applet, rebuilding is
    # cheap and safe: the signing identity is stable, so the designated
    # requirement does not change and the existing TCC grants keep matching.
    ensure_identity
    SIGN_IDENTITY="$SIGN_IDENTITY" "$AGENT_SRC/build.sh" "$AGENT_SRC/build"

    # Stop the running agent before swapping the bundle underneath it.
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

    rm -rf "$APP"
    cp -R "$AGENT_SRC/build/OrganizeDownloads.app" "$APP"

    # Register with LaunchServices so TCC can resolve the executable back to
    # its bundle. Without a registration the attribution falls back to the
    # executable path, which is the exact failure this rewrite removes.
    "$LSREGISTER" -f "$APP"
    echo "installed $APP"

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
    # Seed category folders now rather than waiting for the first file event.
    # Resolve the target the same way the worker does, so an install on a
    # machine pointed at an external volume does not silently seed ~/Downloads.
    TARGET_FILE="$HOME/.config/organize-downloads/target"
    if [ -n "${ORGANIZE_DL:-}" ]; then
      TARGET="$ORGANIZE_DL"
    elif [ -s "$TARGET_FILE" ]; then
      TARGET="$(tr -d '\n' <"$TARGET_FILE")"
    else
      TARGET="$HOME/Downloads"
      [ -e "$TARGET" ] || { mkdir -m 0700 -- "$TARGET"; echo "created $TARGET"; }
    fi
    if [ -d "$TARGET" ] && [ ! -L "$TARGET" ]; then
      ORGANIZE_DL="$TARGET" "$BIN" || true
      echo "bootstrapped category folders in $TARGET"
    else
      echo "target not present, skipping bootstrap: $TARGET"
    fi

    echo
    echo "FIRST INSTALL ONLY: grant Full Disk Access to $APP"
    echo "  System Settings -> Privacy & Security -> Full Disk Access -> +"
    echo "Later rebuilds keep the grant (stable signing identity), so this is"
    echo "a one-time step. If an OLD entry for this app is already listed,"
    echo "remove it with - first: it is bound to a signature that no longer exists."
    INBOX_FILE="$HOME/.config/organize-downloads/inbox"
    if [ -s "$INBOX_FILE" ]; then
      echo "relay: $(tr -d '\n' <"$INBOX_FILE") -> $TARGET (drained into the target before every sweep)"
    else
      echo "relay: off (write a folder path to $INBOX_FILE to drain it into the target)"
    fi
    echo "logs: ~/Library/Logs/organize-downloads.log (worker)"
    echo "      ~/Library/Logs/organize-downloads-agent.log (watcher)"
    ;;
  uninstall)
    # Unload the agent and remove the files install put on disk. Deliberately
    # leaves ~/Downloads and all sorted subfolders in place - uninstall never
    # touches the user's data.
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$DEST" "$BIN"
    rm -rf "$APP"
    "$LSREGISTER" -u "$APP" 2>/dev/null || true
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
  identity)
    # Create the signing identity without doing a full install.
    ensure_identity
    security find-identity -v -p codesigning | grep -F "$SIGN_IDENTITY" || true
    ;;
  *)
    echo "usage: $0 {install|uninstall|status|run|identity}"
    exit 1
    ;;
esac
