# Morning Briefing

A small macOS tool that sends you a summary of your day every weekday morning: today's **calendar** (Apple, Google and any other account on your Mac), **reminders** that are due, and the **weather** where you are. It keeps the briefing up to date as your calendar changes during the day.

- **No visible app.** It runs invisibly in the background. You get a notification, and clicking it opens the briefing page.
- **No AI and no accounts.** The summary comes from simple rules in the app. There are no API keys and nothing to sign up for.
- **Private.** Calendar and reminder data never leaves your Mac. The only network request is for the weather forecast.
- **Read-only.** It never changes your calendars or reminders.

```
┌──────────────────────────────────────────────────────┐
│ Briefing                                     7:00 AM │
│ Busy morning: 3 meetings before noon · rain from 4 PM │
│ First up: Standup 9:30 AM. Free 12:00 – 3:00 PM.     │
│ 2 reminders (1 overdue). Rain from 4 PM, take an     │
│ umbrella.                                            │
└──────────────────────────────────────────────────────┘
```

Clicking the notification opens a page like [`docs/mockups/briefing.html`](docs/mockups/briefing.html) (sample data). It has the headline, a short summary of your day, the weather, your schedule with free blocks and conflicts, your reminders, and, after any calendar change, a **"Changes since this morning"** section.

## Features

- **7:00 weekday briefing.** If the Mac was asleep or off at 7:00, the briefing runs when it wakes up or when you log in. It never runs twice for the same day.
- **Every calendar on the Mac.** It reads everything in System Settings → Internet Accounts (iCloud, Google, Exchange/Outlook, CalDAV). Duplicate events are merged.
- **Rule-based summary.** You get a headline ("Busy morning", "Packed day", "1 conflict at 3:30 PM"), back-to-back runs, overlaps, your longest free block, reminders that are overdue or due today, and weather advice.
- **Live updates.** When an event is added, moved, renamed or cancelled (on the Mac, iPhone or web), the briefing is rebuilt within about 10 seconds and a "Calendar updated" notification lists the changes.
- **Weather for your current location** from [Open-Meteo](https://open-meteo.com) (free, no key). Location falls back to your last known position, then to an IP-based lookup, then to a city you set.

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain. The **Command Line Tools are enough** (`xcode-select --install`); Xcode isn't needed.

## Install

### 1. Create a code-signing certificate (once)

macOS remembers the Calendar, Reminders and Location permissions **per code signature**. A stable self-signed certificate keeps those permissions when you rebuild.

1. Open **Keychain Access**.
2. From the menu, choose **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Fill in:
   - **Name:** `Briefing Code Signing`
   - **Identity Type:** Self-Signed Root
   - **Certificate Type:** Code Signing
4. Click **Create**.

You can skip this step. The build then uses an ad-hoc signature, and macOS asks for permissions again after every rebuild.

### 2. Build and install

```sh
git clone https://github.com/thakur90/morning-briefing.git
cd morning-briefing
scripts/build-app.sh --install
```

This does four things:
- builds `Briefing.app` and signs it
- copies it to `~/Applications`
- registers the background agent with launchd, so it starts at login and restarts if it crashes
- links the `briefing` command to `~/.local/bin`

The first time it signs, macOS asks whether `codesign` may use the key. Enter your login password and choose **Always Allow**.

### 3. Grant permissions

On its first launch, the agent asks for **Calendars**, **Reminders**, **Location** and **Notifications**. Allow all four, then check:

```sh
briefing status
```

### 4. (Optional) Add Google or Outlook calendars

Go to **System Settings → Internet Accounts → Add Account** and turn on **Calendars**. They show up in the next briefing; nothing else to configure.

## Usage

```sh
briefing today             # build today's briefing now and notify
briefing today --open      # …and open the page
briefing today --dry-run   # print the collected data only (add --json for raw JSON)
briefing open              # open today's briefing page
briefing status            # agent, permissions, schedule, last runs
briefing check             # re-check permissions
briefing uninstall         # remove the agent and app (keeps config, briefings, logs)
```

Briefings are saved in `~/Briefings/` as `YYYY-MM-DD.html` (the page), `.md` (a plain-text copy) and `.context.json` (the raw data).

## Configuration

`~/Library/Application Support/Briefing/config.json` is created with defaults on first run. Edit it by hand. Changes apply within a minute, without restarting. Keys you leave out keep their defaults.

```json
{
  "runAt": "07:00",
  "weekdaysOnly": true,
  "outputDir": "~/Briefings",
  "temperatureUnit": "fahrenheit",
  "day": { "start": "08:00", "end": "18:00", "minFreeMinutes": 30 },
  "location": { "mode": "current", "fallbackCity": "Seattle" },
  "calendars": { "exclude": ["Holidays in United States", "Birthdays", "Siri Suggestions"] },
  "reminders": { "lists": [] },
  "liveUpdates": { "enabled": true, "notifyOnChanges": true },
  "summary": { "rainThreshold": 50, "backToBackGapMinutes": 5, "highlightFreeMinutes": 60 }
}
```

| Key | Meaning |
|---|---|
| `runAt`, `weekdaysOnly` | When the morning briefing runs (local time). `weekdaysOnly: false` runs it every day |
| `outputDir` | Where briefings are saved |
| `temperatureUnit` | `fahrenheit` or `celsius` (defaults from your Mac's region) |
| `day` | Free blocks are only reported between `start` and `end`, if they're at least `minFreeMinutes` long |
| `location.mode` | `current` (default), `ip` (city-level, from your IP), or `fixed` (always use `fallbackCity`) |
| `location.fallbackCity` | Used if no location can be found, or always in `fixed` mode |
| `calendars.exclude` | Calendar titles to ignore (or `"Account/Title"`) |
| `reminders.lists` | Reminder lists to include; empty means all |
| `liveUpdates` | Turn calendar-change refreshes or their notifications off |
| `summary` | Rain chance (%) that triggers rain advice, the gap (min) that counts as back-to-back, and the length (min) of free block worth calling out |

## How it works

```
launchd ──► Briefing.app (invisible, LSUIElement) ── "briefing agent"
              ├─ MorningScheduler   7:00 weekdays, catch-up after sleep/login
              ├─ CalendarWatcher    EKEventStoreChanged → debounce → diff
              └─ CommandListener    requests from the `briefing` CLI
                        │
                        ▼
              DayCollector  (EventKit, Reminders, CoreLocation, Open-Meteo)
                        ▼
              SummaryBuilder (rules) ──► HTML + Markdown ──► notification
```

The terminal command doesn't read your calendars itself. It asks the running agent, because macOS grants those permissions to the app, not to Terminal. The full design, decisions and component details are in [`docs/design.md`](docs/design.md).

## Privacy

| Data | Where it goes |
|---|---|
| Calendar events, reminders | Nowhere. Read and kept on your Mac only |
| Coordinates (rounded to ~1 km) | [Open-Meteo](https://open-meteo.com), for the forecast |
| Your IP address | [ipapi.co](https://ipapi.co), **only** if the current location isn't available |
| `fallbackCity` | Open-Meteo geocoding, only if that fallback is used |

## Development

```sh
swift build                      # build the CLI and core library
swift run briefing-tests         # run the tests (sample data only)
scripts/build-app.sh --install   # rebuild the app and restart the agent
scripts/run-agent-once.sh        # run the installed agent once via launchd and print its output
```

Tests are a plain executable (`Tests/BriefingCoreChecks`), because XCTest and Swift Testing need Xcode's test runner. Logs are in `~/Library/Logs/Briefing/`.

```
Sources/BriefingCore/   Calendars, Services, Summary, Output, Agent, Scheduling, Config
Sources/briefing/       entry point: `agent` mode and CLI commands
Support/Info.plist      bundle Info.plist (LSUIElement, permission descriptions)
scripts/                build-app.sh, run-agent-once.sh
docs/                   design.md, mockups/briefing.html
```

## Troubleshooting

| Problem | Fix |
|---|---|
| Build hangs at `codesign` | A keychain dialog is waiting, possibly behind other windows. Enter your password and choose **Always Allow** |
| `errSecInternalComponent` while signing | The keychain dialog was denied or timed out. Run the build again and approve it |
| Permissions asked again after every rebuild | The app is ad-hoc signed. Create the certificate (Install, step 1) |
| `Bootstrap failed: 5: Input/output error` | The old agent hadn't stopped yet. Run `scripts/build-app.sh --install` again |
| No Google events | Add the account in System Settings → Internet Accounts with **Calendars** on |
| `briefing today --dry-run` shows the location as "approximate, from IP" | Location access is off: System Settings → Privacy & Security → Location Services → Briefing |
| `The background agent isn't running` | Check `~/Library/Logs/Briefing/launchd.log`, then `scripts/build-app.sh --install` |
