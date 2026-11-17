# Tabbed panel: CI/CD / Apple / Local Repos

## Context

Harbor's panel is currently one scrolling list mixing git-repo pipeline
cards and TestFlight cards, with a search field and "errors only" toggle
above it. Splitting content into tabs — CI/CD (repo pipelines), Apple
(TestFlight), and a new Local Repos tab (locally-merged branches and
prunable worktrees, read-only) — makes each concern easier to scan and adds
a long-wanted local git-hygiene report without stepping outside the app's
"report, don't act" posture (branch/worktree lifecycle stays user-managed
manually, per standing global policy).

## Goals

- Three tabs in the panel: **CI/CD**, **Apple**, **Local Repos**.
- CI/CD tab = today's repo pipeline list (cards, search, "errors only"),
  unchanged in content and behavior.
- Apple tab = today's TestFlight card list, no search/filter.
- Local Repos tab = new: for each repo in `config.json`, list locally
  merged (non-default) branches and `git worktree`-reported prunable
  worktrees. Strictly read-only — no delete/prune action anywhere in it.
- Local Repos data is computed on demand (when the tab is opened), not
  folded into the existing `poll.sh` / `status.json` / launchd polling
  cycle — it's a local git operation, not a CI fetch, and needs no network
  call or schedule.
- Scan scope for Local Repos = only repos already present in Harbor's
  `config.json` (same watch list CI/CD already uses), not an independent
  filesystem walk.

## Non-goals

- No branch deletion or worktree pruning from the UI, now or as a
  follow-up inside this feature. (See global policy:
  branch/worktree lifecycle is managed externally by the user.)
- No remote/network check for "merged" (e.g. whether the upstream branch
  is gone on the remote) — local `--merged` against the default branch
  only.
- No age-based worktree staleness — only what
  `git worktree list --porcelain` itself reports as `prunable`.
- No per-tab width recomputation — panel width keeps being driven by
  CI/CD repo-name widths as today.

## Architecture

### UI (`ContentView.swift`)

- New `enum HarborTab: String, CaseIterable { case cicd = "CI/CD", apple =
  "Apple", localRepos = "Local Repos" }`.
- `ContentView` gains `@State private var selectedTab: HarborTab = .cicd`
  and a segmented `Picker(selection: $selectedTab)` rendered below the
  "HARBOR" header row, above the search/filter row.
- Body switches on `selectedTab`:
  - `.cicd`: today's search field + "errors only" toggle + repo
    `ForEach`, exactly as now, minus the TestFlight section.
  - `.apple`: TestFlight `ForEach` only, no search/filter row.
  - `.localRepos`: new `LocalReposView` (below).
- `.onChange(of: selectedTab)` calls a new `onLocalReposTabSelected: ()
  -> Void` callback when the new value is `.localRepos`, so AppDelegate
  can kick off the on-demand fetch.

### New view: `LocalReposView`

- Takes `[RepoBranchReport]` (see data model) plus an `isLoading: Bool`.
- Renders one card per repo that has at least one merged branch or
  prunable worktree (repos with nothing to report are omitted — keeps the
  tab quiet when everything's clean).
- Each card: repo name header, then a small list of merged branch names,
  then a small list of prunable worktree paths (with the reason git
  reports, e.g. "gitdir file points to non-existent location").
- Empty state ("Nothing to clean up") when every repo comes back clean.
- Loading state (simple `ProgressView`) while the on-demand fetch is in
  flight.

### Data model (new, `StatusModel.swift` or a new small file)

```swift
struct RepoBranchReport: Codable, Identifiable {
    var id: String { name }
    let name: String
    let mergedBranches: [String]
    let prunableWorktrees: [PrunableWorktree]
}

struct PrunableWorktree: Codable {
    let path: String
    let reason: String
}
```

### New script: `bin/local-repos.sh`

- Reads `config.json`'s repo list (same as `poll.sh`).
- For each repo:
  - Skip (log to `errors.log`, same pattern as `poll.sh`) if the path is
    missing or not a git repo.
  - Determine the default branch locally (`git symbolic-ref
    refs/remotes/origin/HEAD`, falling back to checking for `main`/
    `master`) — no API call, unlike the GitHub/GitLab default-branch
    lookups in `common.sh`.
  - `mergedBranches`: `git branch --format='%(refname:short)' --merged
    origin/<default>`, excluding the default branch itself.
  - `prunableWorktrees`: parse `git worktree list --porcelain` into
    blocks; keep only blocks containing a `prunable <reason>` line,
    emitting `{path, reason}`.
- Emits a JSON array of `{name, mergedBranches, prunableWorktrees}` for
  every configured repo (empty arrays included) — filtering to
  "has something to report" is a UI concern, not this script's.
- No network calls, no auth handling needed (nothing here can hit a
  401/403).

### AppDelegate wiring

- New state: `private var localRepoReports: [RepoBranchReport] = []`,
  `private var isLoadingLocalRepos = false`.
- New `onLocalReposTabSelected` closure passed into both
  `ContentView(...)` construction sites (mirrors how `onRefreshAll` etc.
  are already threaded through), calling a new `loadLocalRepos()`.
- `loadLocalRepos()`: guarded on `repoDir` (same as `refreshAllNow`);
  runs `"$repoDir/bin/local-repos.sh"` via `Process` off the main thread,
  decodes stdout JSON into `[RepoBranchReport]`, logs
  (`harborLog`) on launch failure or non-zero exit / decode failure, then
  re-renders via the existing `refresh()` path.
- Re-fetches every time the tab is (re-)selected — no caching, no manual
  refresh button inside the tab (on-demand already covers "fresh when you
  look").

### Panel sizing

- `targetContentHeight` gains a `localRepoCount` parameter alongside the
  existing `expandedCount`/`collapsedCount`/`testflightCount`, with its
  own row-height constant (single-line-ish rows, similar scale to
  `collapsedCardHeight`).
- The counts callback (`onContentSizeMightHaveChanged`) is extended to
  also report Local Repos' visible row count; since only one tab is ever
  visible, the other counts come through as 0 for that render — the
  existing summation in `targetContentHeight` naturally resolves to
  "whichever tab is active" with no branching needed there.
- `idealContentWidth` is unchanged — still computed from CI/CD repo-name
  widths regardless of active tab (explicitly out of scope above).

## Error handling

- `local-repos.sh`: same posture as `poll.sh` — a bad path or git failure
  for one repo is logged to `errors.log` and skipped; it never aborts the
  whole run or corrupts prior output.
- Swift side: `Process` launch failure, non-zero exit, or JSON decode
  failure on the script's output are all logged via `harborLog` (already
  wired to `~/.harbor/app.log`) and leave `localRepoReports` at its
  previous value rather than clearing the tab to empty.

## Testing

- New `test/local_repos_test.sh`, following the existing hand-rolled
  assertion style (`test/poll_single_repo_test.sh`, `test/common_test.sh`
  — scratch dirs, `assert_eq`-style helpers, no external test framework).
  Builds real scratch git repos to cover:
  - a branch merged into the default branch is reported,
  - the default branch itself is never reported as "merged",
  - an unmerged branch is not reported,
  - a worktree whose directory has been deleted is reported as prunable,
  - a healthy worktree is not reported,
  - a repo path that's missing/not-a-git-repo is skipped without
    aborting the rest of the run (mirrors the existing poll.sh test for
    this).
- No new Swift unit tests planned beyond manual verification (this
  codebase's existing Swift tests cover `StatusModel`/display logic, not
  view rendering) — the implementation plan should call out building +
  running the app via `install/install.sh` and eyeballing all three tabs,
  consistent with this project's "always reload after a change" rule
  (`CLAUDE.md`, local-only).
