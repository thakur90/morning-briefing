# Morning Briefing — Design Doc

**Status:** Draft v3 · **Author:** thakur90 · **Date:** 2026-10-22

## 1. Goal

A **native macOS app, written in Swift**. Every weekday morning it shows a short summary of my day:

- **Weather** for today, at my current location
- **How the day looks**: events from **Apple (iCloud) and Google calendars**, built so that more calendars (e.g. **Outlook**) can be added later
- **Reminders** that are due today or overdue (Apple Reminders)

It also lets me **add new events**. They go into my **Apple (iCloud) calendar** by default.

**Interfaces, in order:**
1. **v1, terminal:** a `briefing` command (`briefing today`, `briefing add "…"`)
2. **v2, menu-bar Mac app:** the briefing in a menu-bar dropdown, a quick-add box, a 7:00 weekday notification, and launch at login

### Non-goals

- Email, or notifications from other apps (macOS doesn't allow reading them)
- News headlines (dropped from scope)
- iPhone app (the shared core could support one later)
- Editing or deleting existing events

## 2. Platform & tooling

| | Choice | Why |
|---|---|---|
| Language | **Swift 6** | Native, safe concurrency |
| UI | **SwiftUI** `MenuBarExtra` | Apple's own menu-bar API |
| Minimum macOS | **14 (Sonoma)** | Needed for the new EventKit "full access" permissions. This Mac runs macOS 26.5 |
| Build | **Swift Package Manager** for core + CLI; **Xcode** project for the app | The CLI builds with the Command Line Tools already installed. **The app needs Xcode installed** (it isn't yet) |
| CLI parsing | `swift-argument-parser` | Apple's standard library for command-line tools |
| Signing | Personal Apple ID, "Sign to Run Locally" | Fine for my own Mac. A paid developer account is only needed to share it with others |

## 3. Architecture

```
┌──────────────────────────┐   ┌──────────────────────────────┐
│ briefing (CLI)  — v1     │   │ Briefing.app (menu bar) — v2  │
│  today / add / calendars │   │  dropdown · quick-add ·      │
│  setup                   │   │  scheduler · notifications    │
└────────────┬─────────────┘   └───────────────┬──────────────┘
             └──────────────┬──────────────────┘
                            ▼
 ┌──────────────────────────────────────────────────────────┐
 │ BriefingCore (Swift package, shared)                     │
 │                                                          │
 │  CalendarProvider ── EventKitProvider (iCloud/Google/    │
 │                       Outlook via Internet Accounts)     │
 │  RemindersService ── EventKit                            │
 │  LocationService ─── CoreLocation → IP lookup → config   │
 │  WeatherService ──── Open-Meteo                          │
 │            │                                             │
 │            ▼                                             │
 │  DayContext ──► Summarizer ──► ClaudeClient (HTTP)       │
 │                 EventParser ─┘                           │
 │            │                                             │
 │            ▼                                             │
 │  Briefing (model) ──► Markdown renderer / SwiftUI views  │
 └──────────────────────────────────────────────────────────┘
```

**Key decision: fetch first, then make one model call.** Plain code collects the data the same way every time, and then a single Claude call writes a prioritized summary that points out conflicts, back-to-back meetings and free blocks. Claude has no tools and can't change anything. The CLI and the app are thin layers over `BriefingCore`.

## 4. Calendars

### 4.1 Apple, Google and Outlook through EventKit

EventKit combines every account added under **System Settings → Internet Accounts** (iCloud, Google, Microsoft Exchange/Outlook, CalDAV). Reading and writing go through one API, with no Google or Microsoft login code in this project. **Adding Outlook later is a settings change.** It then appears in `briefing calendars` and in the app's Settings.

### 4.2 Provider protocol (extensibility)

```swift
protocol CalendarProvider: Sendable {
    var id: String { get }                       // "eventkit", "google", "msgraph"
    func calendars() async throws -> [CalendarInfo]
    func events(in range: DateInterval) async throws -> [Event]
    func add(_ event: NewEvent) async throws -> Event
}
```

| Provider | When |
|---|---|
| `EventKitProvider` | **v1, the default.** Covers every account in Internet Accounts |
| `GoogleCalendarProvider` (REST + OAuth) | Later, only if a Google-only feature is needed |
| `MicrosoftGraphProvider` (REST + OAuth) | Later, for work Outlook accounts that block Internet Accounts |

Events that come from more than one provider are de-duplicated by start time, end time and title.

### 4.3 Adding events

```bash
briefing add "Lunch with Sam tomorrow 12:30 for 1h at Tartine"
briefing add --title "Dentist" --start "2026-10-24 09:00" --duration 45m
briefing add "…" --calendar "Work (Google)"
```

- **Default calendar: an iCloud calendar** chosen once in `briefing setup` (or in app Settings). `--calendar` overrides it per event.
- **Free text** is turned into a `NewEvent` by a small Claude call that returns structured output. **Flags** skip the model completely. If a time is missing or ambiguous, it asks instead of guessing.
- It **always asks for confirmation** and warns about conflicts before saving:
  ```
  Lunch with Sam — Thu Oct 23, 12:30–13:30 @ Tartine → iCloud: Home
  ⚠ Overlaps "1:1 with Priya" (13:00–13:30)
  Add it? [y/N]
  ```
- In the app, the same flow is a quick-add text field → preview card → **Add** button.

## 5. Other data sources

| Service | Source | Notes |
|---|---|---|
| Reminders | EventKit | Due today, overdue, and flagged; optionally filtered by list |
| Location | CoreLocation | Current location. If that fails or is denied, falls back to an IP-based lookup, then to a city in config |
| Weather | [Open-Meteo](https://open-meteo.com) | Free, no API key. (Apple WeatherKit would need the paid developer account) |

Each service returns data or an error. **If one source fails, the briefing still appears** and notes what's missing.

## 6. Summarizer (Claude API)

- **No official Anthropic Swift SDK exists**, so `ClaudeClient` is a small `URLSession` + `Codable` wrapper around `POST /v1/messages`. Request and response types are written from the API reference.
- **Model:** `claude-opus-5-5`, adaptive thinking, `output_config.effort = "medium"`.
- **Refusal fallback:** `fallbacks: "default"` with the `anthropic-beta: server-side-fallback-2026-07-01` header. Always check `stop_reason`.
- **Structured output** via `output_config.format` (JSON schema), decoded into a `Briefing` struct:
  `headline` · `schedule` (events + notes) · `reminders` (ranked) · `weatherNote` · `notificationText` (no more than about 200 characters)
- **Prompt caching:** not used, since it runs once a day.
- **API key:** stored in the macOS **Keychain**. Both the CLI and the app read it there.

**Estimated cost:** briefing ~$0.07/day; free-text add ~$0.01 each → **≈ $2/month**.

## 7. Scheduling & notifications

| | v1 (CLI) | v2 (app) |
|---|---|---|
| 7:00 weekday run | launchd agent runs `briefing today --notify` | The app (launched at login via `SMAppService`) runs it at 7:00 Mon–Fri, and catches up after the Mac wakes |
| Notification | `osascript` (basic) | `UserNotifications`: clicking opens the dropdown |
| Output | `~/Briefings/YYYY-MM-DD.md` + DayContext JSON | Same files, plus the SwiftUI dropdown |

A once-per-day guard stops a briefing from being generated twice, whether by both the CLI and the app or by the run that catches up after wake.

Full design of the v1 scheduler: **Appendix A**.

## 8. Permissions (main technical risk)

Calendars, Reminders and Location each need user permission, and macOS asks for it based on usage-description keys in an **Info.plist**:
`NSCalendarsFullAccessUsageDescription` · `NSRemindersFullAccessUsageDescription` · `NSLocationWhenInUseUsageDescription`

- **App (v2):** standard. The keys go in the app's Info.plist.
- **CLI (v1):** a plain command-line binary has no Info.plist. We **embed one in the binary** (linker flag `-sectcreate __TEXT __info_plist`) so macOS can show the prompts. Run from Terminal, permission is granted to Terminal. Run by launchd, it's granted to the binary itself.
- → **Milestone 1 tests this first.**

## 9. Security & privacy

- Sent to Claude: event titles, times and locations; reminder titles; and weather. Calendars or lists marked private in config are never sent.
- Event titles from invites are written by other people. The summarizer has no tools, and the prompt treats that data as content, not instructions. Nothing is written to a calendar without my confirmation.
- The API key is kept only in the Keychain. Config holds no secrets.

## 10. Configuration

Shared by the CLI and the app: `~/Library/Application Support/Briefing/config.json`. Edited with `briefing setup` or in the app's Settings.

```json
{
  "runAt": "07:00",
  "weekdaysOnly": true,
  "outputDir": "~/Briefings",
  "location": { "mode": "current", "fallbackCity": "San Francisco" },
  "calendars": {
    "providers": ["eventkit"],
    "exclude": ["Holidays in United States"],
    "defaultForNewEvents": { "account": "iCloud", "calendar": "Home" }
  },
  "reminders": { "lists": [] },
  "model": { "name": "claude-opus-5-5", "effort": "medium" }
}
```

## 11. Project layout

```
pet-projects/
├── Package.swift                  # BriefingCore + briefing CLI
├── Sources/
│   ├── BriefingCore/
│   │   ├── Calendars/             # CalendarProvider, EventKitProvider, dedupe
│   │   ├── Services/              # Reminders, Location, Weather
│   │   ├── Claude/                # ClaudeClient, Summarizer, EventParser
│   │   ├── Models/                # Event, NewEvent, Reminder, DayContext, Briefing
│   │   ├── Render/                # Markdown renderer
│   │   └── Config/                # config.json + Keychain
│   └── briefing/                  # CLI (swift-argument-parser), embedded Info.plist
├── App/                           # v2: Xcode project, SwiftUI MenuBarExtra
├── Tests/BriefingCoreTests/
└── docs/design.md
```

## 12. Error handling

| Failure | Behaviour |
|---|---|
| A data source fails | Briefing still appears; the missing section is noted |
| Permission denied | Clear message linking to System Settings → Privacy & Security |
| Claude API error or refusal | Retry, then server-side fallback, then a **plain summary** (schedule, reminders and weather without the AI write-up) |
| Free-text add is ambiguous | Ask a follow-up question; nothing is saved |

## 13. Testing

- XCTest / Swift Testing for normalization, dedupe, conflict detection, the Markdown output, and decoding Claude JSON (from fixtures).
- Event parser checks: about 20 phrases ("next Tue 3pm", "lunch tomorrow for 90 min") compared to the expected `NewEvent`.
- Protocol-based fakes for EventKit, location and network, so tests never touch real calendars.
- `--dry-run` on `today` (no Claude call) and on `add` (doesn't save).

## 14. Milestones

1. **Permissions test (CLI):** a Swift binary with an embedded Info.plist that reads today's events, reminders and location. *(Removes the biggest risk first.)*
2. **Read path:** EventKitProvider, Reminders, Weather, DayContext, `briefing today --dry-run`.
3. **Summarizer:** ClaudeClient, structured output, plain-summary fallback, Markdown output.
4. **Add events:** `briefing setup` (pick the iCloud default), flags, free text, conflict check.
5. **Schedule (CLI):** launchd agent, weekdays at 7:00, notification.
6. **Menu-bar app:** Xcode project, MenuBarExtra dropdown, quick-add, built-in scheduler, notifications, launch at login, Settings. The launchd agent is removed once the app takes over.
7. **Polish:** tune the prompt using real briefings.

## 15. Open questions

- **Q1:** Install Xcode now (free, from the App Store, ~10 GB), or wait until milestone 6? Milestones 1–5 only need the Command Line Tools, which are already installed.

---

## Appendix A — Scheduling with a launchd agent (v1)

macOS's built-in scheduler, **launchd**, runs `briefing` at 7:00 on weekdays until the menu-bar app (milestone 6) takes over scheduling.

### A.1 Components

```
 briefing install / uninstall / status / run-now         (CLI commands)
        │
        ▼
 ┌────────────────────────┐     writes      ┌───────────────────────────────────────────┐
 │ LaunchAgentInstaller   │───────────────► │ ~/Library/LaunchAgents/                   │
 │  • PlistBuilder        │  launchctl      │   com.thakur90.briefing.plist             │
 │  • BinaryInstaller     │  bootstrap      └─────────────────────┬─────────────────────┘
 │  • LaunchctlClient     │                                       │ 7:00 Mon–Fri / login / wake
 └────────────────────────┘                                       ▼
                                          briefing today --notify --scheduled
                                                                  │
 ┌────────────────────────────────────────────────────────────────▼───────────────────┐
 │ ScheduledRunCoordinator                                                            │
 │   ScheduleGuard ─► RunLock ─► NetworkWaiter ─► BriefingPipeline ─► OutputWriter    │
 │                                                    (BriefingCore)      │           │
 │                                                                         ▼           │
 │                                                     Notifier · RunStateStore · Log │
 └─────────────────────────────────────────────────────────────────────────────────────┘
```

All components live in `BriefingCore/Scheduling/`, except the CLI commands themselves. Each one sits behind a protocol so tests can swap in fakes (clock, filesystem, launchctl, network).

| Component | Responsibility | Key details |
|---|---|---|
| **PlistBuilder** | Turns config into the agent plist | Builds from `runAt` and `weekdaysOnly`; encodes with `PropertyListEncoder`; the output is deterministic, so reinstalling with the same config produces the same file |
| **BinaryInstaller** | Puts the CLI at a fixed path | Copies the built binary to `~/.local/bin/briefing` and signs it (see A.6). launchd has no shell `PATH`, so every path is absolute |
| **LaunchctlClient** | Wraps `launchctl` | `bootstrap gui/<uid> <plist>` · `bootout gui/<uid>/com.thakur90.briefing` · `kickstart -k …` (run now) · `print …` (status). Runs via `Process`; turns failures into typed errors |
| **LaunchAgentInstaller** | Puts the above together | `install`: write plist → validate (`plutil -lint`) → bootout old → bootstrap new. Safe to run again. `uninstall` reverses it and leaves briefings and logs in place |
| **ScheduledRunCoordinator** | Entry point for `--scheduled` runs | Runs the steps below in order and **always ends with exit code 0** (launchd doesn't retry calendar jobs, and non-zero codes only clutter the system log) |
| **ScheduleGuard** | Decides whether this run should happen | Rules in A.3. Uses an injected `Clock` and `Calendar` so it can be tested for any date and time |
| **RunLock** | Stops two runs at once (scheduled + manual) | `flock` on `~/Library/Application Support/Briefing/run.lock`; if the lock is taken, exit quietly |
| **NetworkWaiter** | Waits for the network after wake | `NWPathMonitor`; waits for `.satisfied` for up to 120 s. If it times out, the run goes ahead offline, so the summary is the plain version and weather is skipped |
| **BriefingPipeline** | The actual work (§3–§6) | Collect → DayContext → Summarizer → `Briefing`. Same code that `briefing today` runs by hand |
| **OutputWriter** | Saves the results | Writes `YYYY-MM-DD.md` + `YYYY-MM-DD.context.json` **atomically** (temp file + rename), so a half-finished run never leaves a partial briefing |
| **Notifier** | Notifies me | v1: `osascript -e 'display notification …'`. Limitation: clicking it opens Script Editor, not the briefing. If `terminal-notifier` is installed, it's used with `-open file://…/YYYY-MM-DD.md` |
| **RunStateStore** | Records what happened | `state.json`: last run start and end, outcome (`full` / `plain` / `skipped:<reason>` / `failed`), and which sources failed. Read by `briefing status` |
| **Log** | Diagnostics | `os.Logger` (subsystem `com.thakur90.briefing`) plus a rotating file at `~/Library/Logs/Briefing/briefing.log` (1 MB × 3). launchd's own stdout/stderr go to `launchd.log`, which only catches crashes |

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
    <string>/Users/neha/.local/bin/briefing</string>
    <string>today</string>
    <string>--notify</string>
    <string>--scheduled</string>
  </array>

  <!-- 7:00 Mon–Fri. Weekday: 1 = Monday … 5 = Friday (0 and 7 = Sunday) -->
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>2</integer><key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>3</integer><key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>4</integer><key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer></dict>
    <dict><key>Weekday</key><integer>5</integer><key>Hour</key><integer>7</integer><key>Minute</key><integer>0</integer></dict>
  </array>

  <!-- Also run at login, to catch up if the Mac was off at 7:00 -->
  <key>RunAtLoad</key>         <true/>

  <!-- Background work: lower CPU/IO priority -->
  <key>ProcessType</key>       <string>Background</string>

  <key>StandardOutPath</key>   <string>/Users/neha/Library/Logs/Briefing/launchd.log</string>
  <key>StandardErrorPath</key> <string>/Users/neha/Library/Logs/Briefing/launchd.log</string>
</dict>
</plist>
```

Times are in the Mac's **local time zone**, so they follow daylight saving changes and travel automatically.

### A.3 When it runs

| Situation at 7:00 | launchd behaviour | Result |
|---|---|---|
| Awake, logged in | Fires on time | Briefing + notification at 7:00 |
| **Asleep** (lid closed) | Fires **once on wake**; missed runs are merged into one | Briefing when I open the laptop |
| **Shut down** / logged out | Doesn't fire, and launchd won't catch up later | `RunAtLoad` fires at the next login |
| Weekend | Not scheduled | — |

**ScheduleGuard rules** (only in `--scheduled` mode; checked in order, and the first match skips the run):

1. Today isn't a scheduled day (e.g. a weekend login) → `skipped:not-a-run-day`
2. It's before `runAt` (e.g. logging in at 6:30) → `skipped:too-early` (the 7:00 run will handle it)
3. Today's briefing already exists → `skipped:already-done`
4. Otherwise → run

A manual `briefing today` skips the guard and always regenerates, overwriting today's file.

### A.4 Sequence of a scheduled run

```
launchd ─► briefing today --notify --scheduled
  1. ScheduleGuard.check(now)              → skip? record + exit 0
  2. RunLock.tryAcquire()                  → busy? exit 0
  3. NetworkWaiter.wait(≤120s)             → offline? continue (plain mode)
  4. BriefingPipeline.run(today)
       collectors in parallel (EventKit, Reminders, Location→Weather)
       Summarizer → Claude (retry ×2 → server fallback → plain summary)
  5. OutputWriter.write(md, context.json)  (atomic)
  6. Notifier.post(briefing.notificationText)
  7. RunStateStore.record(outcome)          → release lock → exit 0
```

Typical run time is 5–20 s, mostly the Claude call.

### A.5 CLI commands

| Command | What it does |
|---|---|
| `briefing install` | Installs the binary, writes the plist, loads it. Also asks for Calendar, Reminders and Location permission *now*, so the 7:00 run never sits waiting on a prompt |
| `briefing uninstall` | Unloads and removes the agent (keeps briefings, logs, config) |
| `briefing status` | Shows whether it's loaded, the next run time, the last run (time, outcome, failed sources), and permission status |
| `briefing run-now` | `launchctl kickstart`, i.e. runs the *scheduled* path right now with the guard on (useful for testing the agent itself) |
| `briefing today` | Manual run; no guard |

Changing `runAt` or `weekdaysOnly` in config → run `briefing install` again to regenerate the plist.

### A.6 Permissions & code signing

macOS remembers Calendar, Reminders and Location permission **per code signature** (its "designated requirement"), so the signature has to stay the same across rebuilds:

- An **ad-hoc** signature (`codesign -s -`) changes with every build, so **macOS would ask for permissions again after each rebuild**. That's fine during development, but not for the installed binary.
- **Plan:** BinaryInstaller signs with a **stable certificate** and identifier `com.thakur90.briefing`. That's either the free "Apple Development" certificate (created by Xcode when signing in with my Apple ID) or a self-signed code-signing certificate made in Keychain Access. Either way, the designated requirement stays the same across rebuilds.
- The embedded Info.plist (§8) provides the usage-description strings for the prompts.
- Milestone 1 checks this works: grant once → rebuild → reinstall → still granted when launched by launchd.

### A.7 Environment details

| Concern | Handling |
|---|---|
| Minimal environment (no `PATH`, no shell profile) | Absolute paths everywhere; no reliance on environment variables |
| API key | Read from the **login Keychain**. That works because the agent runs inside my user session (it's a `gui/<uid>` agent) |
| Network not ready after wake | NetworkWaiter (A.1) |
| Long or stuck run | Overall timeout of 3 min; on timeout, write the plain summary and exit |
| Disk | Briefings are ~5–20 KB each; no automatic cleanup in v1 |

### A.8 Testing

- **Unit:** ScheduleGuard (weekday/weekend × before/after `runAt` × file exists), PlistBuilder (snapshot of the generated XML, run through `plutil -lint`), OutputWriter atomicity, RunLock contention. All use a fake `Clock` and a temporary directory.
- **Integration (manual, milestone 5):** `install` → `status` → `run-now` → check that the file, notification and `state.json` appear; close the lid past a test time → wake → it runs once; reboot → log in → `RunAtLoad` catch-up; weekend login → skipped.
- For testing, a `--label-suffix dev` option on `install` creates a second agent (`com.thakur90.briefing.dev`) at a time I choose, without touching the real one.

### A.9 Moving to the app (milestone 6)

The menu-bar app runs its own 7:00 scheduler, reusing **ScheduleGuard, RunLock, NetworkWaiter, BriefingPipeline, OutputWriter and RunStateStore**. Notifier is replaced with a `UserNotifications` version. On first launch, the app finds the launchd agent and offers to remove it (`briefing uninstall`). RunLock and `already-done` keep the two from both producing a briefing during the switchover.
