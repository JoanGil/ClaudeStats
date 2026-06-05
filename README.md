# ClaudeStats

A macOS menu-bar app that reads your local Claude Code session files and shows how much you've used — and what it's costing you.

![ClaudeStats menu bar popup](https://github.com/JoanGil/ClaudeStats/raw/main/screenshot.png)

## Why

Claude Code writes every conversation to JSONL files under `~/.claude/projects/`. The desktop app shows a token count but nothing about cost, streaks, model breakdown, or billing-period spend. ClaudeStats fills that gap — no API key, no network calls, just your local files.

## What it shows

**Overview tab**
- Sessions, messages, total tokens, active days
- Current and longest daily streaks
- Peak coding hour, favourite model
- Activity heatmap (7d / 30d / all-time)
- Fun comparison: how many times your token usage equals *Pride and Prejudice*

**Models tab**
- Per-model token and message breakdown with relative bar chart

**Usage limits panel**
- Estimated spend for the current billing period vs your plan limit
- Days until next reset

## How the cost estimate works

Claude Code doesn't expose billing data locally, so the app estimates spend from raw token counts:

```
cost = Σ (input_tokens × input_price + output_tokens × output_price) / 1,000,000
```

**What's included:** input and output tokens per assistant message.  
**What's excluded:** cache read / cache write tokens — these are charged at heavily discounted rates (≈80× cheaper) and would massively inflate the number.

Default prices (USD per 1M tokens, matching public list prices):

| Model   | Input  | Output |
|---------|--------|--------|
| Opus    | $15    | $75    |
| Sonnet  | $3     | $15    |
| Haiku   | $1     | $5     |

Model is matched by substring (e.g. `claude-sonnet-4-6` → Sonnet price). Unknown models fall back to Sonnet.

### Calibration

Because enterprise plans, credits, and discounts mean list price ≠ real bill, there's a calibration button (⊟ icon in the footer). Enter your actual spend from the Anthropic console and the app computes a correction factor (`real / raw`) that scales all future estimates. The factor is saved to `~/.claude/claude-stats-config.json`.

### Config file

The app auto-creates `~/.claude/claude-stats-config.json` on first launch. You can edit it to match your plan:

```json
{
  "planLabel": "Enterprise",
  "spendLimitUsd": 1500,
  "resetDayOfMonth": 1,
  "resetHour": 2,
  "prices": {
    "opus":   { "input": 15, "output": 75 },
    "sonnet": { "input": 3,  "output": 15 },
    "haiku":  { "input": 1,  "output": 5  }
  }
}
```

## Requirements

- macOS 14 (Sonoma) or later
- Swift toolchain (ships with Xcode or `xcode-select --install`)

## Install

```bash
git clone https://github.com/JoanGil/ClaudeStats.git
cd ClaudeStats
./build-app.sh          # builds and installs to /Applications
open /Applications/ClaudeStats.app
```

To install somewhere else:

```bash
./build-app.sh ~/Applications
```

The script compiles a release binary, assembles the `.app` bundle, generates an `AppIcon.icns`, and ad-hoc signs it so Gatekeeper doesn't block it.

On first launch macOS may show an "unidentified developer" warning. Right-click → Open to bypass it once.

## Usage

Click the menu-bar icon to open the popup. The app reads `~/.claude/projects/**/*.jsonl` on every open.

| Shortcut | Action |
|----------|--------|
| `O`      | Switch to Overview tab |
| `M`      | Switch to Models tab |
| `1` `2` `3` | Switch time window (7d / 30d / All) |
| `Esc`    | Close popup |

Use the time window buttons to scope stats to the last 7 days, 30 days, or all time. Billing-period spend is always calculated from the full history regardless of the selected window.

## Raycast integration

A Raycast Script Command is included in `raycast/claude-stats.sh`. It toggles the ClaudeStats popup from Raycast (or any keyboard shortcut you assign).

**Setup:**

1. Open Raycast → Settings → Extensions → Script Commands → Add Directory
2. Point it at the `raycast/` folder in this repo (or wherever you cloned it)
3. The command "Claude Stats" will appear — assign a hotkey if you want instant access

The script uses the `claudestats://toggle` URL scheme registered by the app. The app must be running (it has no dock icon — launch it once from `/Applications` and it lives in the menu bar).

## License

MIT
