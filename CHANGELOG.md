# Changelog

## [1.0.0] - 2026-11-23

First release.

- Shelf widget listing the open pull requests that need you, most recently
  updated first: reviews requested from you or your teams, and your own pull
  requests with changes requested, failing checks, merge conflicts, or an
  approval waiting for you to merge.
- Paired layout that counts pull requests by reason and links the latest one.
- Optional pull requests assigned to you, draft pull requests, and every open
  pull request in the repositories you filter to.
- Filters by organization, account or `owner/repo`.
- Notch alert when a new pull request needs you.
- A global shortcut (suggested ⌃⌥⌘G) that opens the shelf on the widget.
- Refreshes every 1 to 30 minutes, with a warning in the header when a refresh
  fails.
- The personal access token is stored in your Keychain, never in preferences.
