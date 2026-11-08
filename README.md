# BotBar

A little notch at the top of your screen that tells you what every Claude Code session is up to.

![BotBar open at the top of a desktop, listing five sessions](screenshots/monitor-expanded.png)

If you run more than one or two Claude sessions at once, you know the routine: flip through windows to see which one is still working, which one finished ten minutes ago, and which one has been sitting on a permission prompt the whole time. BotBar puts all of that in one place you can glance at, and taps you on the shoulder when something changes.

Each dot is a session:

- **Amber** — it's waiting on you (a permission prompt, a question)
- **Blue** — it's working
- **Green** — it just finished and you haven't looked yet
- **Dim green** — finished, and you've seen it

Most of the time, that row of dots is all you see:

![The collapsed notch sitting at the top of the screen](screenshots/monitor-collapsed.png)

Hover over the notch and it opens into the full list. Click a session to jump straight to it, in the Claude desktop app or in the terminal where the CLI is running.

![A close-up of the open list](screenshots/closeup-expanded.png)
## It speaks up when something happens

When a session finishes or needs you, the notch drops down for a few seconds with what changed and plays a short chime: three rising notes for "done", a two-note doorbell for "needs you". You can go do something else and stop checking.

![An alert: one session needs you, another finished in 9 minutes](screenshots/closeup-alert.png)

The rest of the time it stays out of the way. It hides under fullscreen games and videos (or, if you'd rather, stays on top of them). With nothing going on it shrinks and dims, and after a few quiet minutes it slides up off the screen entirely. Move the mouse to where it was and it comes right back.

## Getting started

You need Windows 10 or 11 and Claude Code. That's it. Nothing to install, no hooks to set up, no config to touch. BotBar reads the status files Claude Code already keeps in `%USERPROFILE%\.claude\sessions`.

1. Clone this repo or download it as a ZIP and unzip it somewhere permanent.
2. Double-click **`BotBar.vbs`**.

The notch appears at the top of your main monitor. To have it start every time you log in, right-click it and tick **Start with Windows**.

> If you downloaded the ZIP and Windows blocks the script, right-click `BotBar.vbs` → Properties → tick **Unblock**, or run `Get-ChildItem | Unblock-File` in the folder.

## Making it yours

**Move it.** Drag the notch anywhere along the top edge of any monitor. It remembers where you left it. Right-click → **Snap to** puts it back at the left, centre or right, and **Lock position** stops accidental drags.

**Right-click for everything else:**

| Option | What it does |
| --- | --- |
| Show completed sessions | Turn off to only see what's running or waiting |
| Two-line rows | Off gives you a denser one-row-per-session list (below) |
| Shrink and dim when idle | Makes the notch tiny and faint when nothing needs you |
| Fullscreen apps | Hide under games and videos, or stay on top of them |
| Slide away when idle | Tuck it off-screen after 5 or 10 quiet minutes, or never |
| Play a sound on alerts | The chimes; **Preview sounds** lets you hear them |
| Mark all as seen | Dims every green dot at once |

![One-line rows](screenshots/closeup-oneline.png)

If you have more than eight sessions going, the dots turn into counts per state so the notch doesn't get silly wide.

Settings live in `BotBar.settings.json` next to the script.

## Good to know

- Works with both the **Claude desktop app** and the **Claude Code CLI**. Clicking a desktop-app session opens it in the app. Clicking a CLI session brings its terminal window to the front (Windows Terminal, a console window, VS Code and so on). If that window has several tabs, BotBar can't pick the tab for you.
- Session names come from Claude Code. CLI sessions you haven't named get a short generated name like `botbar-a4`. Sessions with no name at all show their project folder.
- Only one copy runs at a time, so double-clicking `BotBar.vbs` again does nothing.
- To quit, right-click → **Exit BotBar**. To remove it completely, untick **Start with Windows** first, then delete the folder.

## Hacking on it

It's a single PowerShell script (`BotBar.ps1`) using WPF, so edit it and relaunch. Running it directly shows a console, which is handy for errors:

```powershell
powershell -ExecutionPolicy Bypass -File .\BotBar.ps1
```

Two environment variables help with testing:

- `BOTBAR_SESSIONS` points it at a different folder, so you can feed it fake session files instead of your real ones.
- `BOTBAR_TUCK_SECONDS` shortens the slide-away timer so you don't have to wait five minutes to see it.
