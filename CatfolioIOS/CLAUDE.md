# Working on this repository

## Branching (cloud sessions)

Changes are also made locally and pushed to `main` between cloud sessions, so
the branch a session was handed can be behind. Before the first edit:

```sh
git fetch origin main
git checkout -B <session-branch> origin/main   # when the branch has no unmerged work of its own
```

If the branch already carries unmerged commits, rebase them onto `origin/main`
instead of dropping them. Fetch `main` again before pushing and bring in
anything new, so syncing back to the local checkout meets few conflicts.

Local changes on `main` include SDK renames that the cloud has no compiler to
catch (for example `UIViewController.Transition.ZoomOptions` in place of
`UIZoomTransitionOptions`); build on them rather than on older code.
