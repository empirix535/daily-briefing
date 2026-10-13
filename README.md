<p align="center"><img src="app/icons/agenda-256.png" width="96" alt="Daily Briefing icon"></p>

# Daily Briefing

A local Windows app with two parts. The **assistant** lives in your Teams notes-to-self chat. It watches your inbox and calendar, posts alerts, reminders, and briefs, and answers your messages. The **dashboard** is a browser window with a To-do tab, a Notes tab with an embedded Claude editor, and a Streams tab for tracking papers and projects.

Everything runs on your own PC. The AI is Claude, used through the Claude Code command-line tool and your own Claude subscription, so there is no API key and no separate billing. Mail and calendar are read through the Microsoft 365 connector in your Claude account. The assistant never sends email, never changes your calendar, and never messages anyone but you.

## What it does

- **Mail.** Scans new inbox mail at :00, :15, :30, and :45 during working hours and posts the items that need you as a numbered list. Ask about an item by number ("what does 1 want", "make a todo from 1 by friday"). FYI items arrive in two batches a day.
- **Calendar.** A morning brief with the day's meetings and to-dos, a prep prompt 20 to 30 minutes before meetings with other attendees, and event requests that return a pre-filled Outlook-on-the-web link. You review and press Save or Send yourself.
- **To-do.** Add, check off, delete, and date items from chat or the dashboard. Items made from email keep an Open email button.
- **Notes.** One page per topic. The assistant files quick notes and meeting notes here. The Ask Claude panel edits the selection in place, with undo, or brainstorms about the page. Each applied edit backs up the previous page to `data\notes\_removed`.
- **Streams.** Pipeline tracker for papers and projects, with stage, due date, next action, and a clickable court badge for who holds the ball.
- **Reminders and commands.** Type `help` in the self-chat for the full list.

## Requirements

- Windows 10 or 11 and PowerShell 5.1 (included in Windows)
- Google Chrome or Microsoft Edge
- **Claude Code**, signed in with a Claude account whose plan includes it
- The **Microsoft 365 connector** enabled in that Claude account (claude.ai, Settings, Connectors). Read access is enough.
- Teams access to your own self-chat

Outlook the desktop app is not needed. Classic and new Outlook both work, because the app never touches them.

## Install

1. Install Claude Code in PowerShell, then run `claude` once to sign in and type `/exit`:
   ```powershell
   irm https://claude.ai/install.ps1 | iex
   claude
   ```
2. Clone or download this repository to a permanent folder, for example `C:\Users\you\daily-briefing`.
3. Double-click **Install.cmd**. It asks for your name, a one-line description, your work email, and your organization's email domain, then builds `DailyBriefing.exe`, adds Start menu and desktop shortcuts, and offers to start with Windows. It is safe to run again after an update.
4. Open **Daily Briefing**. The assistant opens its own Chrome window for Teams. Sign in once and it hides again.

## Moving to a new PC

Your code is on GitHub. The assistant copies your personal data to `OneDrive\Daily Briefing backup` once a day, with two weeks of dated copies in `history`. That covers `settings.json`, to-dos, notes, reminders, rules, voice, and assistant state.

1. Sign in to OneDrive and let it finish syncing.
2. Install Chrome and Claude Code, sign in to Claude, and confirm the Microsoft 365 connector is on.
3. Clone this repository and run **Install.cmd**. It finds the backup and offers to restore it.
4. Sign in to Teams once in the assistant's window.

The Streams tab reads `streams.json` from OneDrive (`<OneDrive>\root\_admin\streams.json` by default). Set `StreamsPath` in `settings.json` to use another location.

## Settings

Personal values live in `settings.json` (see `settings.example.json`). Restart the server from the tray menu after changing it.

| Setting | Meaning |
|---|---|
| `UserName`, `UserDescription`, `UserEmail` | How the assistant addresses you and gives Claude context |
| `Contacts` | Nicknames, such as `"sam": "sam@example.org"` |
| `SecretaryModel` | Model for chat answers (`haiku` is fastest) |
| `SecretaryThinkModel` | Model for scans, note clean-up, and the Notes editor (`sonnet`) |
| `SecretaryDays`, `SecretaryStart`, `SecretaryEnd` | Working hours for scans, nudges, and alerts |
| `SecretaryMaxCallsPerDay` | Daily cap on assistant Claude calls (250) |
| `StreamsPath` | Full path to `streams.json` |
| `Port` | Local port, 8000 by default |

## Everyday use

The tray icon runs the app. Double-click opens the dashboard. Right-click offers Open Dashboard, View Log, Pause assistant, Start with Windows, Restart Server, and Exit. Restart the server after changing any `.ps1` file. Edits to `Index.html` need only a browser refresh.

## Privacy

- The server listens on `localhost` only.
- Email and calendar text goes to Claude through your own account when scans, briefs, and questions run. Check that this fits your organization's data policy.
- `data\` and `settings.json` hold personal content and are excluded from Git by `.gitignore`.

## Troubleshooting

- **No replies in Teams:** open `data\server.log` from the tray menu. A sign-in prompt in the assistant's Chrome window needs your attention.
- **Mail scan says it failed:** the assistant posts the Microsoft sign-in error once. Re-authorize the Microsoft 365 connector in your Claude account.
- **"The server did not start":** check `data\server.log`. Some IT policies block PowerShell scripts.

## Layout

```
Install.cmd / Install.ps1        setup (safe to re-run)
Uninstall.cmd / Uninstall.ps1    removes shortcuts and the .exe
settings.example.json            template for settings.json
app/
  server.ps1                     tray app, local server, notes and streams endpoints
  Index.html                     the dashboard
  lib/common.ps1                 shared helpers, Claude job runner for the Notes editor
  assistant/                     Teams assistant: mail, calendar, to-dos, notes, reminders, commands
  tests/assistant-tests.ps1      offline checks for the assistant
  launcher.cs, launch.vbs        launchers
  icons/                         app icons
data/                            created on first run (not in Git)
```
