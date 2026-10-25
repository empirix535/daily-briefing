# Otis commands

Type `help` in your Teams self-chat. The list is generated from the command table in `app\assistant\commands.ps1`, so it always matches what Otis does.

Anything that is not a command goes to Claude, so you can also just say it: add X to my to-dos due Friday, remind me Thursday at 2 to ..., what does 1 want exactly, when am I free Thursday, schedule a check-in with Sophie Tuesday at 10.

Otis reads email and calendar through the Microsoft 365 connector (read-only). It never sends, drafts, or changes anything in Outlook. For a calendar event it posts a pre-filled Outlook on the web link that you edit and send yourself.
