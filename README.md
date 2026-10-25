<p align="center"><img src="app/icons/agenda-256.png" width="96" alt="Otis icon"></p>

# Otis

A local Windows app with two parts. **Otis** the assistant lives in your Teams notes-to-self chat. It watches your inbox and calendar, posts alerts, reminders, and briefs, and answers your messages. The **dashboard** is a browser window with a To-do tab, a Notes tab with an embedded Claude editor, and a Streams tab for tracking papers and projects.

Everything runs on your own PC. The AI is Claude, used through the Claude Code command-line tool and your own Claude subscription, so there is no API key and no separate billing. Mail and calendar are read through the Microsoft 365 connector in your Claude account. Otis never sends email, never changes your calendar, and never messages anyone but you.

## What it does

- **Mail.** Scans new inbox mail at :00, :15, :30, and :45 during working hours and posts the items that need you as a numbered list. Ask about an item by number ("what does 1 want", "make a todo from 1 by friday"). FYI items arrive in two batches a day, capped at 24 hours, with one line per email chain. Emails you have not answered come back at the noon and 4 PM roundups, at most twice each. Otis checks Sent Items first and skips the ones you answered.
- **Calendar.** A morning brief with the day's meetings and your to-dos for today and this week, a prep prompt 20 to 30 minutes before meetings with other attendees, and event requests that return a pre-filled Outlook-on-the-web link. You review and press Save or Send yourself.
- **To-do.** Add, check off, delete, date, and nest items from chat or the dashboard. The tab groups items into Today, This week, and No due date, and you can drag them between groups. Items made from email keep an Open email button. Vague times in reminders ("before noon", "before COB", "this afternoon") land at a random time inside a fixed window.
- **Notes.** One page per topic. Otis files quick notes and meeting notes here. The Claude panel edits the selection in place, with undo, or brainstorms about the page. Each applied edit backs up the previous page to `data\notes\_removed`.
- **Streams.** Pipeline tracker for papers and projects, with stage, due date, next action, a clickable court badge for who holds the ball, and an activity LED. Click the LED to set Focus, Active, Cooling, Dormant, or Auto. Auto follows the newest file in the item's folder or its latest change. A blue ring means the court is not yours. A sort chip orders items by how close they are to published.
- **Pop-ups.** Teams does not notify you for messages you post to yourself, so Otis shows a Windows pop-up from the tray icon for reminders, meeting prompts, and emails that need you.
- **Commands.** Type `help` in the self-chat for the full list.

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
3. Double-click **Install.cmd**. It asks for your name, a one-line description, your work email, and your organization's email domain, then builds `DailyBriefing.exe`, adds Start menu and desktop shortcuts named Otis, and offers to start with Windows. It is safe to run again after an update. Run it again after any change to `launcher.cs`.
4. Open **Otis**. Otis opens its own Chrome window for Teams. Sign in once and it hides again.

The executable keeps its original file name, `DailyBriefing.exe`. The shortcuts, window title, and tray icon all say Otis.

## Moving to a new PC

Your code is on GitHub. Otis copies your personal data to `OneDrive\Otis backup` once a day, with two weeks of dated copies in `history`. That covers `settings.json`, to-dos, notes, reminders, rules, voice, and state. A backup folder from the earlier name, `Daily Briefing backup`, is renamed on the first run and Install.cmd still finds it.

1. Sign in to OneDrive and let it finish syncing.
2. Install Chrome and Claude Code, sign in to Claude, and confirm the Microsoft 365 connector is on.
3. Clone this repository and run **Install.cmd**. It finds the backup and offers to restore it.
4. Sign in to Teams once in Otis's window.

The Streams tab reads `streams.json` from OneDrive (`<OneDrive>\root\_admin\streams.json` by default). Set `StreamsPath` in `settings.json` to use another location. Each item's `path` is relative to the folder above `_admin`, and the newest file there feeds the LED.

## Settings

Personal values live in `settings.json` (see `settings.example.json`). Restart Otis from the tray menu after changing it.

| Setting | Meaning |
|---|---|
| `UserName`, `UserDescription`, `UserEmail` | How Otis addresses you and gives Claude context |
| `Contacts` | Nicknames, such as `"sam": "sam@example.org"` |
| `SecretaryModel` | Model for chat answers (`haiku` is fastest) |
| `SecretaryThinkModel` | Model for scans, note clean-up, and the Notes editor (`sonnet`) |
| `SecretaryDays`, `SecretaryStart`, `SecretaryEnd` | Working hours for scans, nudges, and alerts |
| `SecretaryMaxCallsPerDay` | Daily cap on Claude calls (250) |
| `StreamsPath` | Full path to `streams.json` |
| `BotEmojiCode` | Custom Teams emoji at the start of Otis's messages, `:otis:` by default. Set `""` for the standard emoji. |
| `ToastAlerts` | `true` shows Windows pop-ups for reminders, meeting prompts, and emails that need you |
| `MinimizeToTray` | `true` hides the window when minimized; the tray icon restores it |
| `Port` | Local port, 8000 by default |

## Everyday use

The tray icon runs the app. Double-click opens Otis. Right-click offers Open Otis, View log, Pause Otis, Show Teams window, Start with Windows, Restart Otis, and Exit. Restart Otis after changing any `.ps1` file. Edits to `Index.html` need only a browser refresh. A second launch while Otis is running exits quietly.

## Privacy

- The server listens on `localhost` only.
- Email and calendar text goes to Claude through your own account when scans, briefs, and questions run. Check that this fits your organization's data policy.
- `data\` and `settings.json` hold personal content and are excluded from Git by `.gitignore`.

## Troubleshooting

- **No replies in Teams:** open `data\server.log` from the tray menu. A sign-in prompt in Otis's Chrome window needs your attention.
- **"Claude's sign-in expired":** open a terminal, run `claude`, then type `/login`. Use the browser profile signed in to the account with your Claude plan. Otis retries every 15 minutes on its own.
- **Mail scan says it failed with a Microsoft sign-in error:** re-authorize the Microsoft 365 connector in your Claude account.
- **"Otis did not start":** check `data\server.log`. Some IT policies block PowerShell scripts.

## Layout

```
Install.cmd / Install.ps1        setup (safe to re-run)
Uninstall.cmd / Uninstall.ps1    removes shortcuts and the .exe
settings.example.json            template for settings.json
app/
  server.ps1                     tray app, local server, notes and streams endpoints
  Index.html                     the dashboard
  lib/common.ps1                 shared helpers, Claude job runner for the Notes editor
  assistant/                     Otis: mail, calendar, to-dos, notes, reminders, commands
  tests/assistant-tests.ps1      offline checks for Otis
  launcher.cs, launch.vbs        launchers
  icons/                         app icons
data/                            created on first run (not in Git)
```
