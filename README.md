# Email Triage

A Tinder-style email triage interface for macOS. Process your inbox with single-keystroke actions.

![Demo](docs/demo.gif)

## Features

- **Full-screen UI** - No distractions, just the current email
- **Single-key actions** - `e` archive, `x` delete, `t` task, `s` suppress
- **Instant feedback** - Next email appears immediately (optimistic updates)
- **Undo support** - `←` brings back the last email and reverses the action
- **Label picker** - Press `l` to file emails under Gmail labels
- **Task creation** - Automatically creates Todoist tasks with email links
- **Offline support** - Actions queue when offline and sync later
- **Gamification** - Earn medals as you triage, Spotify track skips every 10 emails

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `e` | Archive (remove from inbox, mark as read) |
| `x` | Delete (move to trash) |
| `t` | Create Todoist task + archive |
| `s` | Suppress (create unsubscribe task + archive) |
| `l` | Open label picker |
| `←` | Undo last action |
| `↑/↓` | Scroll email body |
| `Esc` | Close triage UI |

## Requirements

- macOS
- [Hammerspoon](https://www.hammerspoon.org/) - macOS automation
- [uv](https://github.com/astral-sh/uv) - Python package manager
- Python 3.11+
- Gmail API credentials
- Todoist account (optional, for task creation)

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/charignon/email-triage.git
cd email-triage
```

### 2. Install the files

```bash
# Copy Hammerspoon module
cp email-triage.lua ~/.hammerspoon/

# Copy Python helper
cp email-triage ~/bin/
chmod +x ~/bin/email-triage
```

### 3. Set up Gmail API credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
2. Create a new project (or select existing)
3. Enable the Gmail API
4. Create OAuth 2.0 credentials (Desktop application)
5. Download the JSON file
6. Save it to `~/.config/email-triage/credentials.json`

```bash
mkdir -p ~/.config/email-triage
mv ~/Downloads/client_secret_*.json ~/.config/email-triage/credentials.json
```

### 4. Authenticate with Gmail

```bash
~/bin/email-triage setup
```

This opens a browser window for OAuth consent. The token is saved to `~/.config/email-triage/token.json`.

### 5. Set up Todoist (optional)

Get your Todoist API token from [Todoist Settings](https://todoist.com/app/settings/integrations/developer) and add it to keychain:

```bash
security add-generic-password -s org-todoist -a todoist -w 'YOUR_TODOIST_TOKEN'
```

### 6. Configure Hammerspoon

Add to your `~/.hammerspoon/init.lua`:

```lua
local emailTriage = require("email-triage")
hs.hotkey.bind({"cmd", "shift"}, "E", emailTriage.toggle)
```

Reload Hammerspoon config.

## Usage

1. Press `Cmd+Shift+E` to open the triage UI
2. Make rapid-fire decisions with single keystrokes
3. Press `Esc` to close when done

## Architecture

```
┌─────────────────────────────────────────────┐
│             Hammerspoon (Lua)               │
│  ┌───────────┐  ┌───────────┐  ┌─────────┐  │
│  │  Canvas   │  │  Webview  │  │ Keyboard│  │
│  │   (UI)    │  │  (HTML)   │  │  Events │  │
│  └───────────┘  └───────────┘  └─────────┘  │
└────────────────────┬────────────────────────┘
                     │ hs.task (subprocess)
                     ▼
┌─────────────────────────────────────────────┐
│           Python Helper (uv script)         │
│  ┌───────────┐  ┌───────────┐  ┌─────────┐  │
│  │  Gmail    │  │  Todoist  │  │ SQLite  │  │
│  │   API     │  │    API    │  │   Log   │  │
│  └───────────┘  └───────────┘  └─────────┘  │
└─────────────────────────────────────────────┘
```

## Files

- `email-triage.lua` - Hammerspoon UI module
- `email-triage` - Python helper script (Gmail/Todoist/SQLite)

## Data Storage

- `~/.config/email-triage/credentials.json` - Gmail OAuth credentials
- `~/.config/email-triage/token.json` - Gmail OAuth token
- `~/.email-triage.db` - SQLite database for decision logging
- `~/.email-triage-cache.json` - Email cache for offline use

## Customization

### Change hotkey

Edit your `init.lua`:

```lua
hs.hotkey.bind({"ctrl", "alt"}, "M", emailTriage.toggle)
```

### Change medal thresholds

In `email-triage.lua`:

```lua
local MUSIC_MILESTONE = 10    -- Play music every N emails
local BRONZE_PER_SILVER = 5   -- 5 bronze = 1 silver
local SILVER_PER_GOLD = 2     -- 2 silver = 1 gold
```

### Disable Spotify integration

In `email-triage.lua`, comment out the `playMusicForMilestone` call in `performAction`.

## Troubleshooting

### "Gmail not authenticated"

Run `~/bin/email-triage setup` to re-authenticate.

### "Todoist token not found"

Add your token to keychain:
```bash
security add-generic-password -s org-todoist -a todoist -w 'YOUR_TOKEN'
```

### Emails not loading

Check the helper directly:
```bash
~/bin/email-triage fetch --max 5
```

### UI not appearing

Verify Hammerspoon loaded the module:
```bash
hs -c "require('email-triage')"
```

## License

MIT

## Contributing

PRs welcome! Please ensure no credentials are committed.

## Credits

Built with:
- [Hammerspoon](https://www.hammerspoon.org/)
- [Google Gmail API](https://developers.google.com/gmail/api)
- [Todoist API](https://developer.todoist.com/)
