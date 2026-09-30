# MacHands — free App Store edition

**This branch must never be merged into `master`.**

`master` stays the MIT open-source agent bridge (bundle id `app.machands.MacHands`): menu-bar app + CLI/MCP, user-approved shell, self-hosted relay, no App Sandbox. That product is not this one.

This branch is a **separate, free Mac App Store product**:

| | Open-source `master` | This branch |
|---|---|---|
| Bundle id | `app.machands.MacHands` | `app.machands.MacHands.store` |
| Display name | MacHands | MacHands |
| Version | source release (0.3.x) | **1.0.0 (build 1)** |
| Price | free MIT, not a paid product | free only — no IAP, no $49, no licence server |
| Sandbox | off | **on** |
| `NSAllowsArbitraryLoads` | present | **removed** |
| Hosted relay IP | never ship `134.199.230.126` | never ships any relay address |
| Default UI language | follows settings / system | **English** (Chinese remains as a localization) |

The two apps cannot overwrite each other. They are not the same binary. The full open-source agent bridge is https://github.com/UnstoppableCurry/MacHands.

## Removed versus `master`

These capabilities are **disabled**, not faked. The UI says so.

- Arbitrary shell (`run` / jobs / `Process`)
- `osascript` and Apple Events
- Relay client (no default URL, no connect, no pairing codes)
- CLI / MCP agent bridge
- Screen capture and input injection
- Reading or writing files outside the App Sandbox
- Built-in Developer ID self-update and notarized release (`release.sh` refuses)
- Trial / licence-key UI and any licence server
- In-app purchases

What remains is a menu-bar companion that identifies the edition, lists what the sandbox forbids, and can copy or open the GitHub project.

## Do not

- Merge this branch into `master`
- Upload to App Store Connect from this repository automation
- Notarize or cut a GitHub release from this branch
- Point this binary at DataDance, MacDisk, or a hosted relay
