---
name: merge
description: >-
  Land the current tatami changes on main in the main checkout at
  /Users/nacho/dev/tatami: commit, rebase onto local main, build and test,
  then fast-forward main. Only invoke when the user has explicitly asked to
  merge or land the changes (for example via Merge Change or /merge), not for
  review, preparation, passing checks, or skill installation.
disable-model-invocation: true
metadata:
  delta-action: land
---

# Merge (tatami)

Invoking this skill is the explicit request to merge, and it is also the
explicit commit instruction required by `docs/DESIGN.md` "Working agreements".
Do not ask again whether to merge or commit, and never reply that you are
waiting for an explicit merge request. Stop only for the blockers named below.
Whenever you stop, report that the changes have **not** merged and why.

## Layout

- Work happens in a worktree of a clone. Its remote `local` is the main repo
  `/Users/nacho/dev/tatami`, and `origin` is GitHub.
- The destination is branch `main` in `/Users/nacho/dev/tatami`. That repo has
  `main` checked out, so pushing to it is refused. Land with a fast-forward
  merge run inside that repo instead.
- Never push to `origin`. The user pushes to GitHub themselves.
- There are no PRs, CI, branch protection or rulesets. The local checks below
  are the required checks.

## 1. Preflight

1. In the worktree, run `git status -sb` and `git diff --stat HEAD`.
2. Work out the scope: all uncommitted and unlanded changes in the worktree. If
   files look unrelated to the change being landed, or the scope is unclear,
   stop and ask which files to include.
3. Note which paths changed (needed for step 4).

## 2. Commit

- Stage the files in scope by path, then commit with `git commit -m ...`. Use
  repeated `-m` flags or `-F <file>` so no editor opens.
- Message style, taken from repo history: an imperative subject that summarizes
  the change; if the change needs it, a blank line, then `- ` bullet lines
  wrapped near 72 columns.
- No AI attribution and no `Co-Authored-By` trailer. Do not sign unless git
  config already does.
- If several local commits already exist and are unlanded, keep them as they
  are.

## 3. Sync with local main

```
git fetch local main
git rebase local/main
```

Conflicts: resolve them automatically when the intended result is clear and
unrelated work on both sides is kept. Then run `git add` on the resolved files
and `GIT_EDITOR=true git rebase --continue`. If the intent is ambiguous or a
resolution would drop someone's work, run `git rebase --abort`, stop, and
report the conflicting files and hunks.

## 4. Required checks (on the rebased commit)

Run these in the worktree after the rebase, so they test the exact commit that
will land.

- Docs-only change (only `*.md`, `LICENSE`, `docs/`, `.agents/`): no build or
  tests needed.
- Otherwise, both must pass (source: README.md "Test"; targets in Package.swift):
  ```
  swift build
  swift test
  ```
- If `Sources/tatami/` or `Sources/tatami-e2e/` changed, also run the e2e suite
  (source: `Sources/tatami-e2e/main.swift` header, docs/DESIGN.md "Testing"):
  ```
  swift run tatami-e2e --no-mouse
  ```
  It moves real windows, needs Accessibility permission, and needs the user's
  own tatami stopped. If it cannot run (tatami is running, permission is
  missing, or there is no GUI session), stop and ask the user. Do not treat it
  as passed.

Any failure, or any result you cannot verify, means stop with "not merged".
Never skip or bypass a check. If you fix a failure, the fix must be part of
the scope; commit it, then rerun every check above.

## 5. Land

```
git -C /Users/nacho/dev/tatami fetch <worktree path> HEAD
git -C /Users/nacho/dev/tatami merge --ff-only FETCH_HEAD
```

- Before running these, confirm `/Users/nacho/dev/tatami` is on branch `main`
  (`git -C /Users/nacho/dev/tatami branch --show-current`). If it is on another
  branch, stop.
- The main checkout may have the user's own uncommitted edits. Never stash,
  reset, checkout or overwrite them. If the fast-forward is refused (because of
  local edits, or because main moved), do not force it. If main moved, go back
  to step 3. If local edits block it, stop and report the files.

## 6. Verify

- `git -C /Users/nacho/dev/tatami rev-parse main` must equal the worktree's
  `HEAD`.
- `git -C /Users/nacho/dev/tatami status -sb` must show the same uncommitted
  files as before the landing.
- Report the landed commit hash and subject, which checks ran, and that nothing
  was pushed to `origin`.
