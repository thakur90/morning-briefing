# Morning Briefing — Design Doc

**Status:** Draft v6 · **Author:** thakur90 · **Date:** 2026-10-27

## 1. Goal

A Mac tool, written in Swift, that **runs invisibly in the background**. It has no window, no Dock icon and no menu-bar icon. Every weekday at 7:00 it sends me a **notification** with a short summary of my day. Clicking it opens the full briefing.

The briefing covers:
- **Weather** for today, at my current location
- **How the day looks**: events from **Apple (iCloud) and Google calendars**, built so that more calendars (e.g. **Outlook**) can be added later
- **Reminders** that are due today or overdue (Apple Reminders)

**It stays up to date during the day.** When an event is added, moved or cancelled (from the Mac, iPhone or the web), the briefing refreshes automatically and a notification says what changed.

**How I interact with it:**
- **Notifications:** the morning briefing and change alerts. This is the main way I use it.
- **The briefing page:** a formatted HTML page that opens in the browser when I click a notification (§7.1). A Markdown copy is saved too.
- **The `briefing` terminal command:** install, status, run it now, debug.

### Non-goals

- Any visible app UI: windows, menu bar, Dock
- Email, or notifications from other apps (macOS doesn't allow reading them)
- News headlines
- Creating, editing or deleting events. The tool **only reads** calendars
- iPhone app

## 2. Platform & tooling

| | Choice | Why |
|---|---|---|
| Language | **Swift 6** | Native, safe concurrency |
| Minimum macOS | **14 (Sonoma)** | Needed for EventKit "full access" permissions. This Mac runs macOS 26.5 |
| Build | **Swift Package Manager** + `scripts/build-app.sh` to assemble `Briefing.app` | **No Xcode**: it can't be installed on this macOS version. The Command Line Tools have everything needed (EventKit, CoreLocation, UserNotifications) |
| CLI parsing | `swift-argument-parser` | Apple's standard library for command-line tools |
| Signing | Self-signed code-signing certificate (Keychain Access) | Keeps permissions across rebuilds (A.6). A paid developer account isn't needed for my own Mac |

## 3. Architecture

**One executable, two modes**, shipped inside an invisible app bundle:

```
~/Applications/Briefing.app            (LSUIElement: no Dock icon, no UI)
└── Contents/MacOS/briefing
       │
       ├── briefing agent      ← started at login by launchd, keeps running
       │     the only process that touches Calendars, Reminders, Location
       │
       └── briefing <command>  ← me, in Terminal (via ~/.local/bin/briefing symlink)
             install · uninstall · status · today · open · check
             asks the agent to do the work (§3.2)
```

### 3.1 The agent

```
 launchd (login, KeepAlive)
        │
        ▼
 ┌──────────────────────────────────────────────────────────────┐
 │ briefing agent                                               │
 │                                                              │
 │  MorningScheduler ──(7:00 Mon–Fri, catch-up)──┐              │
 │  CalendarWatcher ───(event changed)───────────┤              │
 │  CommandListener ───(from CLI)────────────────┤              │
 │                                               ▼              │
 │                                      BriefingPipeline        │
 │   CalendarProvider(s) ─┐                      │              │
 │   RemindersService ────┼─► DayContext ─► Summarizer ─► Claude│
 │   LocationService ─────┤                      │              │
 │   WeatherService ──────┘                      ▼              │
 │                                  OutputWriter · Notifier     │
 │                                  (~/Briefings, notification) │
 └──────────────────────────────────────────────────────────────┘
```

All the logic lives in `BriefingCore`. The executable is a thin shell: it either starts the agent or runs a CLI command.

**Key decision: fetch first, then make one model call.** Plain code collects the data the same way every time, and a single Claude call writes a prioritized summary that points out conflicts, back-to-back meetings and free blocks. Claude has no tools and can't change anything.

### 3.2 How CLI commands reach the agent

macOS permissions belong to the **app**. If I run a command in Terminal, macOS would attribute it to Terminal, and Terminal can't get location (milestone 1 finding). So CLI commands that need data **ask the running agent** instead of fetching data themselves:

- The CLI posts a request through `DistributedNotificationCenter` (`com.thakur90.briefing.request`, carrying a request ID and the command).
- The agent runs it and writes the result to `~/Library/Application Support/Briefing/responses/<id>.json`.
- The CLI waits for that file (30 s timeout). If the agent isn't running, it says so and suggests `briefing install`.

Commands that only manage files or launchd (`install`, `uninstall`, `status`, `open`) don't need the agent.

## 4. Calendars

### 4.1 Apple, Google and Outlook through EventKit

EventKit combines every account added under **System Settings → Internet Accounts** (iCloud, Google, Microsoft Exchange/Outlook, CalDAV). Everything is read through one API, with no Google or Microsoft login code in this project, and the same API **tells us when anything changes** (§4.3). **Adding Outlook later is a settings change**, and its calendars then show up in `briefing status`.

### 4.2 Provider protocol (extensibility)

```swift
protocol CalendarProvider: Sendable {
    var id: String { get }                       // "eventkit", "google", "msgraph"
    func calendars() async throws -> [CalendarInfo]
    func events(in range: DateInterval) async throws -> [Event]
    /// Emits when the provider's data *may* have changed. Coarse: callers re-fetch and diff.
    func changes() -> AsyncStream<Void>
}
```

| Provider | When |
|---|---|
| `EventKitProvider` | **The default.** Covers every account in Internet Accounts |
| `GoogleCalendarProvider` (REST + OAuth) | Later, only if a Google-only feature is needed. `changes()` would poll (e.g. every 5 min), since push needs a public server |
| `MicrosoftGraphProvider` (REST + OAuth) | Later, for work Outlook accounts that block Internet Accounts |

Events that come from more than one provider are de-duplicated by start time, end time and title.

### 4.3 Live updates

When an event is added, moved or cancelled, today's briefing updates on its own. That covers changes made in Calendar on the Mac, on the iPhone, on the web, or by an invite arriving, as soon as the change syncs to this Mac.

**How it works** (`CalendarWatcher`):

1. **Listen:** EventKit posts `EKEventStoreChanged` whenever anything in any calendar or reminder list changes, including changes that arrive by sync.
2. **Debounce (10 s):** a sync usually fires several notifications in a row. The watcher waits until things settle.
3. **Re-fetch and diff:** read the rest of today's events and compare them with the last snapshot. Events are matched by their EventKit identifier and compared on start/end time, title, location and calendar. The result is `added` / `moved` / `cancelled` / `renamed`. Changes outside today, or edits only to notes, are ignored.
4. **Refresh in two steps:**
   - **Schedule section: updated instantly** from EventKit data. Plain code, no Claude call, no cost.
   - **AI summary: regenerated** after a meaningful change, **at most once every 15 min** and **at most 6 times a day** (both configurable).
5. **Save and notify:** rewrite today's briefing atomically with an "Updated 2:14 PM" stamp and a **"Changes since this morning"** section. Then send a notification: *"New: Dentist at 3:00 PM (Home)"*, *"Moved: 1:1 with Priya → 4:30 PM"*, *"Cancelled: Team lunch"*. Several changes together are grouped into one notification.

**Rules:**
- It only updates **today's existing briefing.** Before the 7:00 run or on weekends, changes just update the snapshot and are picked up by the next run.
- Reminders share the same change notification, so the reminders section refreshes too. Notifications are sent only for calendar changes.
- While the Mac sleeps nothing runs. On wake, EventKit syncs, the notification fires, and the briefing catches up.

## 5. Other data sources

| Service | Source | Notes |
|---|---|---|
| Reminders | EventKit | Due today, overdue, and flagged; optionally filtered by list |
| Location | CoreLocation, in the agent | Current location, refreshed before each briefing; the last fix is cached. If it fails, falls back to an IP-based lookup, then to a city in config |
| Weather | [Open-Meteo](https://open-meteo.com) | Free, no API key. (Apple WeatherKit would need the paid developer account) |

Each service returns data or an error. **If one source fails, the briefing still appears** and notes what's missing.

## 6. Summarizer (Claude API)

- **No official Anthropic Swift SDK exists**, so `ClaudeClient` is a small `URLSession` + `Codable` wrapper around `POST /v1/messages`. Request and response types are written from the API reference.
- **Model:** `claude-opus-5-5`, adaptive thinking, `output_config.effort = "medium"`.
- **Refusal fallback:** `fallbacks: "default"` with the `anthropic-beta: server-side-fallback-2026-07-01` header. Always check `stop_reason`.
- **Structured output** via `output_config.format` (JSON schema), decoded into a `Briefing` struct:
  `headline` · `schedule` (events + notes) · `reminders` (ranked) · `weatherNote` · `notificationText` (no more than about 200 characters)
- **Prompt caching:** not used. Runs are at least 15 min apart, so the cache would have expired.
- **API key:** stored in the macOS **Keychain**; only the agent reads it.

**Estimated cost:** ~$0.07 per summary. Morning run + a typical 1–2 refreshes/day ≈ **$3–5/month**; the 6-per-day cap limits the worst case to ~$0.50/day.

## 7. Notifications & output

| | |
|---|---|
| Morning notification | Title: the headline ("Busy morning, 3 meetings before noon"). Body: `notificationText`. **Clicking it opens today's briefing** |
| Change notification | "New / Moved / Cancelled: …". Clicking it opens the briefing at "Changes since this morning" |
| Framework | `UserNotifications`, posted by the agent (permission is asked once) |
| Files | `~/Briefings/YYYY-MM-DD.html` (opened on click), `.md` (plain-text copy), `.context.json` (raw data, for debugging) |
| Quiet when needed | Respects Focus / Do Not Disturb (standard macOS behaviour). `liveUpdates.notifyOnChanges` turns change alerts off |

### 7.1 The briefing page

Clicking any notification opens `~/Briefings/YYYY-MM-DD.html` in the default browser. The approved layout is in **[`docs/mockups/briefing.html`](mockups/briefing.html)** (sample data). Sections, top to bottom:

| # | Section | Content |
|---|---|---|
| 1 | Header | Date, Claude's headline, "Generated 7:00 AM · Updated 2:14 PM" |
| 2 | Changes since this morning | Only shown after a change: **New** / **Moved** / **Cancelled** tags. Change notifications link here (`#changes`) |
| 3 | Your day | Claude's short paragraph: priorities, prep, free time, weather advice |
| 4 | Weather | Location, current temp, high/low, one-line note, hourly strip (temp + rain chance) |
| 5 | Schedule | Each event: time, calendar colour, calendar · account, location. Notes: back-to-back, conflicts, moved/added. Free blocks highlighted; cancelled events struck through |
| 6 | Reminders | Due today; overdue highlighted |
| 7 | Footer | Sources used, and any that failed |

- A single self-contained file: inline CSS, no JavaScript, no external requests. It follows the Mac's light/dark mode.
- Rendered by `HTMLRenderer` from the same `Briefing` model as the Markdown copy. Event titles and other calendar text are HTML-escaped.
- The "leave by 2:40" travel-time note in the mockup is a **future idea** (§16); v1 doesn't calculate travel time.

Scheduling and the agent's lifecycle are covered in detail in **Appendix A**.

## 8. Permissions

All permissions are granted to **`Briefing.app`** (bundle ID `com.thakur90.briefing`), and only the agent uses them:

| Permission | Info.plist key | Used for |
|---|---|---|
| Calendars (full access) | `NSCalendarsFullAccessUsageDescription` | Reading events (macOS has no read-only option) |
| Reminders (full access) | `NSRemindersFullAccessUsageDescription` | Reading due reminders |
| Location | `NSLocationWhenInUseUsageDescription`, `NSLocationUsageDescription` | Weather |
| Notifications | (none needed) | Briefing and change alerts |

**Milestone 1 findings:** a bare CLI binary with an embedded Info.plist **gets Calendars and Reminders**, but **never gets a Location prompt**, whether run from Terminal or launchd. `Briefing.app` (an `LSUIElement` bundle) started by launchd **gets all four permissions**. That confirms the app bundle + background agent design.

## 9. Security & privacy

- Sent to Claude: event titles, times and locations; reminder titles; and weather. Calendars or lists marked private in config are never sent.
- Event titles from invites are written by other people. The summarizer has no tools, and the prompt treats that data as content, not instructions. The tool never writes to calendars.
- The API key is kept only in the Keychain. Config holds no secrets.
- The CLI → agent channel (§3.2) only accepts a fixed set of commands. Responses are written to my own Application Support folder.

## 10. Configuration

`~/Library/Application Support/Briefing/config.json`, edited by hand. The agent picks up changes automatically.

```json
{
  "runAt": "07:00",
  "weekdaysOnly": true,
  "outputDir": "~/Briefings",
  "location": { "mode": "current", "fallbackCity": "San Francisco" },
  "calendars": {
    "providers": ["eventkit"],
    "exclude": ["Holidays in United States"]
  },
  "reminders": { "lists": [] },
  "liveUpdates": {
    "enabled": true,
    "notifyOnChanges": true,
    "minMinutesBetweenSummaries": 15,
    "maxSummariesPerDay": 6
  },
  "model": { "name": "claude-opus-5-5", "effort": "medium" }
}
```

## 11. Project layout

```
pet-projects/
├── Package.swift                  # BriefingCore + briefing executable
├── Sources/
│   ├── BriefingCore/
│   │   ├── Agent/                 # Agent, MorningScheduler, CommandListener
│   │   ├── Calendars/             # CalendarProvider, EventKitProvider, CalendarWatcher, diff, dedupe
│   │   ├── Services/              # Reminders, Location, Weather
│   │   ├── Claude/                # ClaudeClient, Summarizer
│   │   ├── Models/                # Event, EventChange, Reminder, DayContext, Briefing
│   │   ├── Output/                # HTMLRenderer, MarkdownRenderer, OutputWriter, Notifier
│   │   ├── Scheduling/            # ScheduleGuard, RunLock, RunStateStore, LaunchAgentInstaller
│   │   └── Config/                # config.json + Keychain
│   └── briefing/                  # entry point: `agent` mode + CLI commands
├── Support/Info.plist             # bundle Info.plist (LSUIElement, usage descriptions)
├── scripts/build-app.sh           # swift build → Briefing.app → sign → ~/Applications
├── Tests/BriefingCoreTests/
└── docs/
    ├── design.md
    └── mockups/briefing.html      # approved layout of the briefing page
```

## 12. Error handling

| Failure | Behaviour |
|---|---|
| A data source fails | Briefing still appears; the missing section is noted |
| Permission denied | The notification says which permission is missing and opens System Settings → Privacy & Security when clicked |
| Claude API error or refusal | Retry, then server-side fallback, then a **plain summary** (schedule, reminders and weather without the AI write-up) |
| Burst of calendar changes | Debounced (10 s); AI refresh limited to once every 15 min and 6 times a day; the schedule section is always current |
| Agent crashes | launchd restarts it (`KeepAlive`, 30 s throttle); on start it runs the catch-up check |
| Agent not running when the CLI is used | The CLI says so and suggests `briefing install` or `briefing status` |

## 13. Testing

- Swift Testing for normalization, dedupe, the Markdown output, and decoding Claude JSON (from fixtures).
- **Watcher:** diff cases (added / moved / cancelled / renamed / notes-only ignored / other day ignored), debounce, and the AI refresh limits.
- **Scheduler:** next-run calculation, weekend skip, catch-up after sleep or login, time-zone change.
- Protocol-based fakes for EventKit, location, network and the clock, so tests never touch real calendars or wait in real time.
- `briefing today --dry-run`: the agent builds the DayContext and the CLI prints it (no Claude call, no files written).
- Manual: add, move and delete an event in Calendar (Mac and iPhone) → check that the briefing and notification update.

## 14. Milestones

1. **Permissions test:** ✅ the CLI binary gets Calendars and Reminders, ❌ but not Location. ✅ `Briefing.app` (built by `scripts/build-app.sh`, ad-hoc signed) started by launchd gets **all four**: Calendars, Reminders, Location, Notifications (2026-10-27). ✅ Signed with the self-signed "Briefing Code Signing" certificate, permissions **survive a rebuild** (new CDHash, no new prompts). **Done.**
2. **Read path:** EventKitProvider, Reminders, Location (+ IP fallback), Weather, DayContext, CLI → agent requests, `briefing today --dry-run`.
3. **Summarizer & output:** ClaudeClient, structured output, plain-summary fallback, HTML page (matching the mockup) + Markdown, notification that opens the page.
4. **Morning schedule:** MorningScheduler (7:00 weekdays, catch-up), `briefing install / uninstall / status`.
5. **Live updates:** CalendarWatcher (listen → debounce → diff), instant schedule refresh, limited AI refresh, change notifications.
6. **Polish:** tune the prompt using real briefings.

## 15. Decisions log

| Date | Decision |
|---|---|
| 2026-10-22 | Mac only, Swift; Gmail and news dropped; reminders kept |
| 2026-10-23 | Read-only: live updates on calendar changes instead of adding events |
| 2026-10-23 | No visible UI: background agent + notifications (no menu bar, no window) |
| 2026-10-23 | Built without Xcode (it can't be installed on this macOS version) |
| 2026-10-27 | Notification click opens an HTML briefing page; layout approved (`docs/mockups/briefing.html`) |

## 16. Future ideas

- Travel time to events with a location ("leave by 2:40"), e.g. via MapKit
- Direct Google / Microsoft Graph providers (§4.2)
- Evening wrap-up and tomorrow preview

---

## Appendix A — The background agent and scheduling

The agent is one long-running process, started by launchd at login and kept alive. It **schedules the 7:00 run itself**, watches calendars, and answers CLI requests. A separate launchd calendar job isn't needed: the agent has to run all day anyway for live updates and location, and a job that launchd starts separately couldn't get location (§8).

### A.1 Components

```
 briefing install / uninstall / status            (CLI)
        │
        ▼
 ┌────────────────────────┐   writes + loads   ┌──────────────────────────────────────┐
 │ LaunchAgentInstaller   │──────────────────► │ ~/Library/LaunchAgents/              │
 │  • AppInstaller        │                    │   com.thakur90.briefing.plist        │
 │  • PlistBuilder        │                    └──────────────────┬───────────────────┘
 │  • LaunchctlClient     │                                       │ login / crash restart
 └────────────────────────┘                                       ▼
 ┌──────────────────────────────────────────────────────────────────────────────────┐
 │ Agent  (Briefing.app/Contents/MacOS/briefing agent)                              │
 │                                                                                  │
 │  Triggers:  MorningScheduler · CalendarWatcher · CommandListener                 │
 │                     │                │                 │                         │
 │                     ▼                ▼                 ▼                         │
 │  RunCoordinator ─► ScheduleGuard ─► RunLock ─► NetworkWaiter ─► BriefingPipeline │
 │                                                                       │          │
 │                                     OutputWriter · Notifier · RunStateStore · Log│
 └──────────────────────────────────────────────────────────────────────────────────┘
```

Every component sits behind a protocol, so tests can swap in fakes (clock, filesystem, launchctl, network, EventKit).

| Component | Responsibility | Key details |
|---|---|---|
| **AppInstaller** | Installs the app | Copies the built `Briefing.app` to `~/Applications`, signs it (A.6), and symlinks `~/.local/bin/briefing` → the executable inside it |
| **PlistBuilder** | Generates the agent plist | Deterministic output, validated with `plutil -lint` |
| **LaunchctlClient** | Wraps `launchctl` | `bootstrap` / `bootout` / `kickstart -k` (restart) / `print` (status), run via `Process`, with typed errors |
| **LaunchAgentInstaller** | Puts the above together | `install`: app → plist → bootout old → bootstrap new. Safe to run again. `uninstall` reverses it and keeps briefings, logs and config |
| **Agent** | Process lifecycle | Starts the three triggers, requests permissions on first launch, reloads config when the file changes, shuts down cleanly on `SIGTERM` |
| **MorningScheduler** | Fires the 7:00 weekday run | See A.3 |
| **CalendarWatcher** | Fires refreshes on calendar changes | §4.3 |
| **CommandListener** | Handles CLI requests | §3.2. Fixed set of commands: `today`, `today --dry-run`, `check` |
| **RunCoordinator** | Runs one briefing generation | Steps in A.4. Each trigger says what kind of run it wants: `morning`, `refresh(changes)`, or `manual` |
| **ScheduleGuard** | Decides whether a morning run should happen | Rules in A.3. Uses an injected `Clock` and `Calendar` |
| **RunLock** | One generation at a time | An in-process actor, plus `flock` on `run.lock` in case a second agent instance ever starts |
| **NetworkWaiter** | Waits for the network after wake | `NWPathMonitor`, up to 120 s. If it times out: plain summary, weather skipped |
| **BriefingPipeline** | The actual work (§4–§6) | Collect → DayContext → Summarizer → `Briefing` |
| **OutputWriter** | Saves the results | `.md`, `.html` and `.context.json`, written **atomically** (temp file + rename) |
| **Notifier** | Notifications | `UserNotifications`. A click opens the briefing via `NSWorkspace`. Several changes are grouped into one notification |
| **RunStateStore** | Records what happened | `state.json`: last run per kind, outcome (`full` / `plain` / `skipped:<reason>` / `failed`), failed sources, AI refreshes used today. Read by `briefing status` |
| **Log** | Diagnostics | `os.Logger` (subsystem `com.thakur90.briefing`) plus a rotating file at `~/Library/Logs/Briefing/briefing.log` (1 MB × 3) |

### A.2 Agent plist

Generated by PlistBuilder, never edited by hand:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>com.thakur90.briefing</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/neha/Applications/Briefing.app/Contents/MacOS/briefing</string>
    <string>agent</string>
  </array>
  <key>RunAtLoad</key>         <true/>   <!-- start at login -->
  <key>KeepAlive</key>         <true/>   <!-- restart if it exits or crashes -->
  <key>ThrottleInterval</key>  <integer>30</integer>
  <key>StandardOutPath</key>   <string>/Users/neha/Library/Logs/Briefing/launchd.log</string>
  <key>StandardErrorPath</key> <string>/Users/neha/Library/Logs/Briefing/launchd.log</string>
</dict>
</plist>
```

`launchd.log` only catches crashes; normal logging goes through Log.

### A.3 MorningScheduler

The scheduler works out the next run time (next weekday at `runAt`, in **local time**) and sleeps until then. It also **re-checks** whenever something could have made it miss a run or changed the timing:

| Event | What it does |
|---|---|
| Agent starts (login, or restart after a crash) | Catch-up check |
| Mac wakes (`NSWorkspace.didWakeNotification`) | Catch-up check (a timer doesn't fire during sleep) |
| Clock or time zone changes (`NSSystemClockDidChange`, `NSSystemTimeZoneDidChange`) | Recalculate the next run |
| `runAt` / `weekdaysOnly` changed in config | Recalculate the next run |

**Catch-up check = ScheduleGuard** (checked in order; the first match skips the run):
1. Today isn't a run day → `skipped:not-a-run-day`
2. It's before `runAt` → `skipped:too-early` (the timer will handle it)
3. Today's morning briefing already exists → `skipped:already-done`
4. Otherwise → **run now**

| Situation at 7:00 | Result |
|---|---|
| Awake | Runs on time |
| Asleep (lid closed) | Runs on wake |
| Shut down / logged out | Runs at login (agent start) |
| Weekend | Nothing |

### A.4 Sequence of a run

```
trigger (morning | refresh(changes) | manual)
  1. ScheduleGuard.check(now)         [morning only] → skip? record and stop
  2. RunLock.acquire()                → a refresh during a run is queued, not dropped
  3. NetworkWaiter.wait(≤120s)        → offline? continue (plain mode)
  4. BriefingPipeline.run(today)
       collectors in parallel (EventKit, Reminders, Location→Weather)
       refresh: schedule always updated; AI only if allowed by the limits (§4.3)
       Summarizer → Claude (retry ×2 → server fallback → plain summary)
  5. OutputWriter.write(md, html, context.json)   (atomic)
  6. Notifier.post(morning summary | change summary)
  7. RunStateStore.record(outcome)    → release lock
```

Typical run: 5–20 s (mostly the Claude call). Overall timeout: 3 min, after which the plain summary is written.

### A.5 CLI commands

| Command | Needs agent? | What it does |
|---|---|---|
| `briefing install` | No | Installs the app and agent, then starts it. The agent asks for all permissions on its first launch |
| `briefing uninstall` | No | Stops and removes the agent and app (keeps briefings, logs, config) |
| `briefing status` | No | Agent loaded and running? Next morning run, last runs and outcomes, AI refreshes used today, permission status (from `state.json`), and calendars found |
| `briefing open` | No | Opens today's briefing |
| `briefing today [--dry-run]` | Yes | Generates the briefing now (`--dry-run`: prints the DayContext only) |
| `briefing check` | Yes | Permission check (milestone 1) |

### A.6 Permissions & code signing

macOS remembers permissions **per code signature** (its "designated requirement"):

- An **ad-hoc** signature (`codesign -s -`) changes with every build, so **macOS would ask for permissions again after each rebuild**.
- **Plan:** sign `Briefing.app` with a **self-signed code-signing certificate**, made once in Keychain Access (Certificate Assistant → Create a Certificate → type "Code Signing"). Its designated requirement stays the same across rebuilds.
- **Verified in milestone 1:** grant once → change code → rebuild → reinstall → still granted. The designated requirement is `identifier "com.thakur90.briefing" and certificate leaf = H"b9a4…"`.
- `scripts/build-app.sh` uses this certificate automatically if it's in the keychain. The first signing shows a keychain prompt; answering **Always Allow** stops it from coming back.
- The certificate shows as "not trusted" in `security find-identity`. That's expected for a self-signed root and doesn't affect signing or permissions.

### A.7 Environment details

| Concern | Handling |
|---|---|
| launchd environment (no `PATH`, no shell profile) | Absolute paths everywhere; no reliance on environment variables |
| API key | Read from the **login Keychain**; works because the agent runs inside my user session (`gui/<uid>`) |
| Idle cost | The agent is idle between triggers: no polling, ~0% CPU, a few MB of memory |
| Disk | Briefings are ~5–20 KB each; no automatic cleanup |

### A.8 Testing

- **Unit:** ScheduleGuard and next-run calculation (weekday/weekend × before/after `runAt` × already done × time-zone change), PlistBuilder snapshot + `plutil -lint`, OutputWriter atomicity, RunLock queuing, CLI ↔ agent request/response. All use a fake `Clock` and a temporary directory.
- **Manual (milestone 4):** `install` → `status` → set `runAt` 2 minutes ahead → it runs and notifies; close the lid past `runAt` → wake → runs once; reboot → login → catch-up; weekend → skipped; `kill` the agent → launchd restarts it.
- For testing, `install --dev` installs a second copy (`com.thakur90.briefing.dev`, separate output folder) without touching the real one.
