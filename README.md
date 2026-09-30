> **This branch is the free Mac App Store edition. Do not merge it into `master`.**
> It is a separate product from the MIT open-source agent bridge. See [`APPSTORE.md`](APPSTORE.md).

English | [中文](README.zh-CN.md)

# MacHands

Give your cloud AI agent a pair of hands on your Mac.

**Free. [MIT](LICENSE) licensed. No paid tier. No license to buy.**

- **Website:** <https://machands.pages.dev>
- **Source:** <https://github.com/UnstoppableCurry/MacHands>

This repository is an **agent bridge**: a menu-bar Mac app plus a CLI / MCP server. It is not DataDance, not MacDisk, and not a disk-relocation tool.

---

## What it is

Cloud agents (Claude Code, Codex, Cursor) cannot reach Xcode, simulators, Safari, or notarization on your machine. MacHands lets them use **your** Mac — no rented cloud Mac, no Remote Login, no SSH.

Every command goes through your approval. Dangerous operations are blacklisted. You can pause or revoke access at any time.

## Screenshot and demo

![One-time authorization window](docs/media/authorize.png)

One-time authorization window. Scope, system permissions, and self-checks live on this page. The “cannot reach relay, retrying” line is the app talking to **your self-hosted relay**, not a public default. This repository does not publish a default relay URL.

<video src="docs/media/authorize.mp4" controls muted playsinline width="572">
<a href="docs/media/authorize.mp4">authorize.mp4</a>
</video>

About 9 seconds, the same window. The account email was cropped out.

## How to get it

This repository is the distribution entry. **v0.3.1 is a source release only** — it has no signed Mac app attached.

| You want | How |
|---|---|
| **MacHands.app** | Build from source on a Mac (below). Do not look for a signed installer that is not there. |
| **CLI / MCP** | On the agent machine: `npx -y machands` (npm package [`machands`](https://www.npmjs.com/package/machands)) |

There is no Mac App Store build. The sandbox forbids arbitrary commands, input injection, and capturing other apps — which is the whole product.

## Three steps

1. Self-host a relay (below) and paste the address it prints into MacHands.
2. Open **MacHands.app**. A hand appears in the menu bar. Click **Copy for agent**.
3. Paste that block into your cloud agent. It runs the one-liner inside. The menu bar shows **Connected**.

After pairing, an **authorization page** appears once: pick a scope (Developer / Read-only / Ask every time) → grant Notifications, Screen Recording, and Accessibility → **Authorize & verify**. Seven self-checks should go green.

In Ask mode, each card leads with **what the agent wants to do**; the raw command sits under Details. Commands like `rm -rf /`, `sudo`, and `diskutil erase` are blocked in every mode.

## What it guarantees

- Remote Login / sshd is not required. The app itself runs commands.
- Agent ↔ Mac traffic is end-to-end encrypted (X25519 + ChaCha20-Poly1305). The relay sees ciphertext only.
- Every command and your decision is written to `~/Library/Logs/MacHands/audit.log`.
- Authorization is revocable. Pairing codes last 10 minutes and work once.

## Relay: self-host only

There is no public hosted relay. You must run your own and set that URL in the app.

```bash
sudo sh relay/install.sh
```

Or `npm i -g machands && machands relay start --port 8443`. The process prints the `ws://` / `wss://` address to paste into MacHands. Details: [`relay/README.md`](relay/README.md).

## Repository layout

| Path | What it is |
|---|---|
| [`SPEC.md`](SPEC.md) | Product and protocol contract (source of truth) |
| [`macapp/`](macapp/) | macOS menu-bar app (SwiftPM, AppKit); see [`macapp/BUILD.md`](macapp/BUILD.md) |
| [`agent/`](agent/) | npm package `machands`: CLI + MCP server; see [`agent/README.md`](agent/README.md) |
| [`relay/`](relay/) | Relay (Node + ws); self-host: [`relay/README.md`](relay/README.md) |
| [`shared/`](shared/) | Crypto interop vectors; Node and Swift both must pass |
| [`tools/license/`](tools/license/) | Protocol license-token tools (the product itself is free) |
| [`site/`](site/) | Static site samples, not a signed installer |
| [`docs/RELEASE.md`](docs/RELEASE.md) | Maintainer release notes |
| [`docs/media/`](docs/media/) | Real authorization-window screenshot and short demo |

## Build and test

```bash
node --test relay/test agent/test
cd macapp && swift build && swift test
cd macapp && ./scripts/build-app.sh
```

Signed releases need your own Developer ID. See [`macapp/BUILD.md`](macapp/BUILD.md) and [`docs/RELEASE.md`](docs/RELEASE.md). This repository does not ship a ready-made installer.

## Connect an agent

```
Claude Code:  claude mcp add machands -- npx -y machands mcp
Codex:        ~/.codex/config.toml → [mcp_servers.machands] command="npx" args=["-y","machands","mcp"]
Cursor:       Settings → MCP → Add: npx -y machands mcp
CLI:          machands run -- xcodebuild -version
```

## License

[MIT](LICENSE). Copyright © 2026 UnstoppableCurry.

MacHands is not a product of Apple, Anthropic, OpenAI, or xAI.
