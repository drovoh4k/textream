# About this fork

This repository is a fork of [`f/textream`](https://github.com/f/textream) by Fatih Kadir Akın.
Textream itself — the app, the design, the teleprompter engine — is his work; this fork only adds
a few settings, a local build script, and the automation that keeps it in sync with upstream and
publishes builds.

## What this fork adds

**Prompter layout controls** for the fullscreen and external display (Sidecar) prompter, in
Settings → *Teleprompter* tab (Fullscreen section) and → *External* tab:

| Setting | Range | Default |
|---|---|---|
| **Side Margins** | 0–35% of the display width per side | 8% — what used to be hardcoded |
| **Reading Line Height** | 10–95% of the display height | 50% (centered) |
| **Text Size** | 50–200% of the automatic size | 100% |

Two behaviour changes come with them:

- On these two prompters, *Reading Line Height* replaces the *Centered / Near Top* reading
  position, which still governs the notch overlay and the floating window. A build that was set to
  *Near Top* seeds the slider at 15% the first time, so nothing moves under you.
- In classic and voice-activated modes the active line is no longer pinned to the bottom edge: it
  follows the setting. 95% reproduces the previous behaviour.

**Updates from this repository.** `UpdateChecker` reads this fork's releases, not upstream's. When
a newer version exists it offers **Install and Relaunch**: it downloads the release `.zip`, checks
the bundle identifier, swaps the running bundle and reopens the app. If the app cannot rewrite
itself — sandboxed, or installed somewhere read-only — it offers the DMG instead.

**No App Sandbox in these builds.** `build-local.sh` and the release workflow sign ad-hoc with no
entitlements, which is what lets the app replace its own bundle when it updates. Building from
Xcode (⌘R) still uses `Textream.entitlements` and stays sandboxed, like upstream.

## Building locally

```bash
./build-local.sh              # Release arm64 → .app + .dmg + .zip in build/
./build-local.sh --universal  # arm64 + Intel
./build-local.sh --install    # also copies it to /Applications
./build-local.sh --help       # everything else
```

Needs Xcode 16 or newer (the deployment target is macOS 15). To sign with Developer ID instead of
ad-hoc: `SIGNING_IDENTITY="Developer ID Application: … (TEAMID)" ./build-local.sh`.

## Automation

| Workflow | When | What it does |
|---|---|---|
| `.github/workflows/drovo-sync-upstream.yml` | daily at 05:00 UTC, or manually | Merges `f/textream@master` into `master`. A clean merge is pushed and hands the merged commit to the build workflow. A conflicting one leaves `master` untouched and opens (or comments on) an issue labelled `upstream-conflict`. |
| `.github/workflows/drovo-build.yml` | push to `master`, called by the sync, or manually | Builds universal, signs ad-hoc, packages `.dmg` + `.zip` and publishes the release. |

The version is the macOS target's `MARKETING_VERSION` plus the commit count — `1.7.0.167` — and the
tag is `drovo-1.7.0.167`. Deliberately not `v*`: upstream's `release.yml` triggers on `v*` tags and
would fail here without its signing secrets. The commit count is used rather than the run number
because a reusable-workflow call runs in the caller's context, so run numbers would jump between
two unrelated sequences and could publish a version older than the installed one.

### One-time repository setup

1. **Actions** tab → enable workflows. GitHub disables them in every new fork, scheduled ones
   included.
2. **Settings → Actions → General → Workflow permissions** → *Read and write permissions*, or
   pushing to `master` and creating releases fails with 403.

GitHub also disables scheduled workflows in repositories with no activity for 60 days; a manual
`workflow_dispatch` run brings the schedule back.

## Gatekeeper

Releases are ad-hoc signed and not notarized. A DMG downloaded through a browser arrives
quarantined: right click → Open the first time, or
`xattr -dr com.apple.quarantine /Applications/Textream.app`. Updates installed by the app itself
skip that, because the app downloads the archive on its own.
