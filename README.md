[한국어](README.ko.md)

# Claude Peak

A macOS menu bar app that monitors Claude Max subscription usage limits in real time.

## Screenshots

The menu bar displays the current 5-hour utilization (%) and time until reset. Click to see detailed usage.
When tokens are being consumed, a flame icon animates based on activity level.

## Features

- **Menu bar display**: 5-hour utilization %, time until reset (configurable in settings)
- **Real-time flame animation**: Monitors `~/.claude/projects/` JSONL logs and animates flames based on token activity
- **Detailed popover**: 5-hour, 7-day (All models), 7-day (Sonnet) usage + reset timers
- **Settings**: Menu bar display format (% only / time only / both), refresh interval (1min / 5min / 10min)
- **Auto-refresh**: Configurable polling interval (default 5min)
- **OAuth authentication**: Browser-based PKCE auth with automatic refresh token renewal

## Tech Stack

- Swift + SwiftUI
- SPM (Swift Package Manager)
- macOS 13+ (`NSStatusItem` + `NSPopover`)
- OAuth 2.0 PKCE (local HTTP server for callback)

## Project Structure

```
claude-usage-limit/
├── Package.swift
├── Sources/
│   ├── App.swift              # @main, NSStatusItem + NSPopover + flame rendering
│   ├── UsageView.swift        # Popover UI + settings screen
│   ├── UsageService.swift     # Usage API calls + token management
│   ├── OAuthService.swift     # OAuth PKCE flow (browser auth)
│   ├── KeychainHelper.swift   # Token file storage (~/.config/claude-peak/tokens.json)
│   ├── Settings.swift         # App settings (UserDefaults)
│   ├── ActivityMonitor.swift  # JSONL log monitoring → real-time token activity
│   └── Models.swift           # UsageResponse and other API models
├── Formula/
│   └── claude-peak.rb         # Homebrew formula
├── Resources/
│   └── Info.plist             # LSUIElement = true (hide from Dock)
└── build.sh                   # Build .app bundle + install to ~/Applications
```

## Installation

### Homebrew (Recommended)

```bash
brew tap letsur-dev/claude-peak https://github.com/letsur-dev/claude-peak.git
brew install claude-peak

# Launch (auto-links to ~/Applications on first run)
claude-peak
```

### Build from Source

```bash
git clone https://github.com/letsur-dev/claude-peak.git
cd claude-peak
./build.sh

# Launch
open ~/Applications/Claude\ Peak.app
```

## Authentication

On first launch, click "Login with Claude" → sign in with your Claude account in the browser → tokens are saved automatically.

### Auth Flow

1. App starts a local HTTP server (random port, IPv6)
2. Opens `claude.ai/oauth/authorize` in browser (with PKCE code_challenge)
3. After authentication, redirects to `http://localhost:PORT/callback?code=xxx`
4. App exchanges the code for tokens at `platform.claude.com/v1/oauth/token`
5. Tokens saved to `~/.config/claude-peak/tokens.json` (0600 permissions)

### Token Refresh

- Automatically refreshes 5 minutes before access token expiry
- Prompts re-login on refresh failure

## Flame Animation

Scans `~/.claude/projects/**/*.jsonl` files every 2 seconds and calculates token throughput (tokens/sec) over the last 30 seconds.

| Activity | Flame | Animation Speed |
|----------|-------|-----------------|
| 0 tps | (small ember, static) | None |
| > 0 tps | × 1 | 0.5s |
| > 100 tps | × 2 | 0.35s |
| > 500 tps | × 3 | 0.2s |
| > 1000 tps | × 4 | 0.12s |

## API

### Usage Query

```
GET https://api.anthropic.com/api/oauth/usage
Headers:
  Authorization: Bearer {access_token}
  anthropic-beta: oauth-2025-04-20
  User-Agent: claude-code/2.0.32
```

Example response:

```json
{
  "five_hour": { "utilization": 2.0, "resets_at": "2026-01-29T09:59:59Z" },
  "seven_day": { "utilization": 63.0, "resets_at": "2026-01-29T23:59:59Z" },
  "seven_day_sonnet": { "utilization": 0.0, "resets_at": null },
  "extra_usage": { "is_enabled": false }
}
```

- `utilization`: 0–100 (percentage)
- `resets_at`: ISO 8601 timestamp or null

### Token Refresh

```
POST https://platform.claude.com/v1/oauth/token
Content-Type: application/json

{
  "grant_type": "refresh_token",
  "refresh_token": "...",
  "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
  "scope": "user:profile user:inference"
}
```

## Lessons Learned

- **Keychain token expiration**: Claude Code re-authenticates via browser OAuth each session, which can invalidate Keychain refresh tokens. A standalone OAuth flow is needed.
- **`claude setup-token` limitations**: Issues inference-only tokens (`user:inference` scope only), which cannot access the usage API (requires `user:profile`).
- **OAuth redirect URI**: Must be `http://localhost:PORT/callback` exactly. `127.0.0.1` or `/oauth/callback` paths are rejected.
- **IPv6**: On macOS, `localhost` may resolve to `::1` (IPv6), so an IPv6 socket is required.
- **Token exchange**: The `state` parameter is required for both the authorize and token exchange requests.
- **Utilization values**: The API returns utilization as 0–100 integers (not 0–1 decimals).
- **Field naming**: The API response uses `resets_at` (with plural 's').
- **JSONL token logs**: Claude Code creates per-session JSONL files under `~/.claude/projects/`, with token usage recorded in `message.usage` of each line.
