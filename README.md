# Harbor

Menu bar pipeline watcher for GitHub Actions and GitLab CI. Shows an aggregate
status badge in the macOS menu bar (a native SwiftUI app, auto-sized to your
watch list) and fires a native notification the moment a watched pipeline
fails.

The panel has three tabs:

- **CI/CD** — repo pipeline status (search + "errors only" filter)
- **Apple** — TestFlight build status
- **Local Repos** — read-only report of locally merged branches and
  prunable `git worktree`s across your configured repos. It only reports —
  nothing here deletes or prunes anything; that stays yours to do by hand.

## Install

```bash
./install/install.sh
```

This creates `~/.harbor/config.json` from the template (edit it to add repos,
or see "Dotfiles-managed config" below), builds and installs the native menu
bar app, and loads the `launchd` polling job.

## Authentication

Harbor never stores or manages credentials itself. Every fetch goes through
the `gh`/`glab` CLI directly (`gh run list`, `glab api ...`), and both
resolve auth from their own stored login — Harbor never reads or passes a
token of its own:

```bash
gh auth login
glab auth login
```

If a repo shows `⚠ Auth`, that platform's CLI login has expired or lost
access to that repo — re-run the matching command above. There's nothing to
fix on Harbor's side; it only detects the failure (by matching `401`/`403`
in the CLI's own error output), it doesn't cause or resolve it.

**`launchd` PATH note:** the poller runs under `launchd`, which gives jobs a
bare `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) with no Homebrew — so both
`install/*.plist.template` files pin `PATH` to include
`/opt/homebrew/bin:/usr/local/bin` so `gh`/`glab`/`jq` are actually found. If
yours live somewhere else (a different package manager, a custom prefix),
every repo will silently show stale/no-op refreshes until you add that path
to the `PATH` entry in both templates, then re-run `install.sh`.

## Config

`~/.harbor/config.json`:

```json
{
  "interval_seconds": 60,
  "repos": [
    { "name": "example-repo", "path": "/Users/you/git-repos/example-repo" }
  ]
}
```

`path` is a local clone of the repo — platform (GitHub/GitLab) and owner/project
are derived from its `git remote get-url origin`, never hardcoded. After adding
a repo, no restart is needed; the next poll picks it up. After changing
`interval_seconds`, re-run `./install/install.sh` to regenerate the `launchd` job.

### Adding a repo from a script

```bash
bin/harbor-add.sh example-repo /Users/you/git-repos/example-repo
```

Adds or updates one entry in the live config by name — safe to call from other
automation (a repo-scaffolding script, a cron job) instead of hand-editing JSON.

### Dotfiles-managed config

If you keep a dotfiles repo, point `HARBOR_DOTFILES_CONFIG` at a path inside it
before installing:

```bash
HARBOR_DOTFILES_CONFIG=~/dotfiles/harbor/config.json ./install/install.sh
```

`~/.harbor/config.json` becomes a symlink to that path, so your watch list is
versioned and backed up the same way as the rest of your dotfiles. Re-running
the installer never overwrites an existing dotfiles-repo config, and backs up
(never silently discards) a pre-existing real `config.json` before linking.

## States

| State | Badge | Meaning |
|---|---|---|
| OK | `✓ OK` | latest run on default branch passed |
| Failed | `✕ Failed` | latest run failed — only this state notifies |
| Running | `● Running` | latest run in progress |
| Stale | `? Stale` | fetch failed or repo unreachable; showing last known state |
| Auth | `⚠ Auth` | `gh`/`glab` auth expired for that repo |
