# ClaudeUsageBar

A tiny macOS menu bar app that shows how much of your Claude plan you've used, so you don't have to type `/status` in Claude Code.

```
✦ C 27% · W 28%
```

- **C** is your current session: a rolling 5-hour window.
- **W** is your current week.
- The text turns orange at 80% and red at 95% (whichever of the two is fuller).
- Click it to see when each limit resets and how old the reading is.

## How it works

The app gets your numbers from two places and shows whichever is newer:

1. **Anthropic's usage endpoint.** Every 60 seconds it asks `api.anthropic.com/api/oauth/usage` for your usage, using the login Claude Code already saved in your Keychain (item `Claude Code-credentials`). The token is used only for that request and is never written anywhere.
2. **Claude Code's status line.** Claude Code can run a small script each time it redraws its status line and hand it your usage on stdin. `statusline.sh` saves that to `~/.claude/usage-bar/rate-limits.json`, and the app re-reads it every 15 seconds.

If the endpoint says "slow down" (HTTP 429), the app keeps showing the last numbers and waits as long as the server asks.

## Requirements

- macOS with the Swift command line tools (`xcode-select --install`)
- `jq` (`brew install jq`), used by `statusline.sh`
- Claude Code logged in with a Pro or Max plan

## Install

```sh
git clone git@github.com:rishikeshydv/claude-usage-bar.git
cd claude-usage-bar
./build.sh
```

`build.sh` compiles the app, installs it to `~/Applications/ClaudeUsageBar.app`, and sets it to start at login. The first time it reads your login, macOS may ask about the Keychain item; choose **Always Allow**.

Optional but recommended: add the status line so Claude Code feeds the app directly. In `~/.claude/settings.json`, add (using the real path to your copy):

```json
"statusLine": {
  "type": "command",
  "command": "/path/to/claude-usage-bar/statusline.sh"
}
```

## Good to know

- The usage endpoint is **not a documented public API**. It could change or stop working without notice, and it rate limits if called too often. If the bar shows `✦ …` or the dropdown mentions a problem, that's the first place to look.
- The status line data only updates while Claude Code is being used.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.rishikesh.claudeusagebar
rm -r ~/Applications/ClaudeUsageBar.app ~/Library/LaunchAgents/com.rishikesh.claudeusagebar.plist
rm -r ~/.claude/usage-bar
```

Then remove the `statusLine` entry from `~/.claude/settings.json` if you added it.
