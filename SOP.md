# SOP: Build a Downloads Auto-Organizer with Claude Code

A step-by-step runbook for a human using Claude Code (or a similar coding agent) to set up an app that automatically tidies `~/Downloads` on macOS. No prior coding required - just copy/paste and approve prompts.

**Time needed:** ~10 minutes.
**What you'll get:** Files you download get sorted into `Images/`, `PDFs/`, `Videos/`, etc. automatically. A clickable app in `~/Applications` lets you trigger a cleanup on demand.

---

## Step 1 - Open Claude Code in your home folder

```
cd ~
claude
```

## Step 2 - Paste this prompt

> Clone this repo somewhere, then follow `AGENTS.md` to install. Run `./install.sh install` and verify it's running with `./install.sh status`.

If you'd rather rebuild from scratch instead of using the shipped `install.sh`, part 2 of `AGENTS.md` is the full build spec.

## Step 3 - Approve the file writes

Claude will ask permission to:
- Create `~/bin/organize-downloads.sh`
- Run `osacompile` to build the app
- Create the launchd plist
- Run `launchctl bootstrap` to load the agent

Approve each. Nothing here deletes files - only moves them.

## Step 4 - Grant macOS permissions (one-time)

1. Open the app once manually: `open ~/Applications/OrganizeDownloads.app`.
2. macOS will prompt for access to your Downloads folder - click **OK**.
3. If it doesn't prompt, go to **System Settings → Privacy & Security → Files and Folders**, find `OrganizeDownloads`, and enable **Downloads Folder**.

## Step 5 - Test it

1. Drop a random screenshot, a PDF, and a ZIP into `~/Downloads`.
2. Wait ~10 seconds.
3. Open `~/Downloads` in Finder - the files should now be inside `Images/`, `PDFs/`, and `Archives/`.

If nothing moved, check the log:
```
tail -f ~/Library/Logs/organize-downloads.log
tail -f ~/Library/Logs/organize-downloads.err
```

## How it works (plain English)

- A small shell script looks at `~/Downloads` and moves files into typed subfolders based on extension.
- A macOS launch agent re-runs the script **every time a file appears in Downloads** (and also every 5 minutes as a backup).
- The `.app` is a clickable wrapper so you can run it yourself from Spotlight or the Dock.
- Files still downloading (`.crdownload`, `.part`, etc.) are ignored so nothing gets moved mid-download.
- If a file with the same name already exists in the destination, the new one gets a timestamped prefix (`dup_1712345678_report.pdf`) - **nothing is overwritten or deleted**.

## Daily use

You don't need to do anything. New downloads get sorted within seconds. If you want a manual sweep, double-click `OrganizeDownloads` in `~/Applications` or use Spotlight (`⌘+Space → OrganizeDownloads`).

## Turning it off

```
./install.sh uninstall
```

That removes the launchd agent, the plist, `~/bin/organize-downloads.sh`, and
`~/Applications/OrganizeDownloads.app`. Your Downloads folder is untouched.

## Customizing categories

Open `~/.config/organize-downloads/rules.conf` in any editor. One line makes a folder and attaches file endings to it, and the same syntax re-routes an ending away from its default folder:

```
ext Keynote key          # .key files -> Keynote/ (created automatically)
ext 3D-Prints stl 3mf    # a new folder for two endings at once
prefix Invoices RE-      # route by filename prefix instead
```

Save, and the next run picks up your changes - no reload, no reinstall. Files whose type matches no rule get a folder named after their extension automatically (`report.stl` lands in `STL/`). The full syntax reference is in the comments of that file.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Nothing happens on new downloads | `launchctl print gui/$(id -u)/local.organize-downloads` - if missing, re-run bootstrap. |
| "Operation not permitted" in the error log | Grant Full Disk Access to `OrganizeDownloads.app` in System Settings → Privacy & Security. |
| Files from a specific app aren't sorted | Add that extension to the script (Step "Customizing categories"). |
| Script moved a folder I was working in | Work outside `~/Downloads`, or add a rule for it in `~/.config/organize-downloads/rules.conf`. |

## Sharing with teammates

Send them this `SOP.md` plus `AGENTS.md`. They run Step 1-5 in their own Claude Code session - the agent handles the per-user paths (username, etc.) automatically.
