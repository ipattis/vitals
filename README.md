# Vitals

A personal iStat Menus–style system monitor for macOS: a dashboard window you can leave
open, plus a compact menu bar readout. Native Swift/SwiftUI, no dependencies, no admin rights.

## What it shows

The dashboard has two tabs, switched from the header or with **⌘1 Machine Vitals** / **⌘2 Agent
Vitals** in the View menu.

### Agents tab

- **Agent fleet:** working/total agents, combined CPU (and share of the machine), memory,
  processes, running subagents, tool calls and errors in the last hour, output tokens, a stacked
  CPU-by-agent graph and a tool-calls-per-minute chart across every session.
- **Agent list:** every agent with status, source, folder, CPU, memory, what it is doing right now,
  and a CPU sparkline. Select one to open its detail pane:
  - **Overview:** CPU / memory / GPU for the whole process tree with history. For Claude Code
    sessions, also: prompts, responses, tool calls, errors (tool and API), context size and peak,
    tokens (input / cache read / cache write / output, with subagents), average turn time,
    compactions, cost and lines changed when Claude Code has recorded them, activity charts
    (tool calls, output tokens, prompts) over 1h / 6h / 24h, and top tools.
  - **Log:** prompts, slash commands, replies, tool calls with their inputs, results and
    durations, subagent launches, compactions, API errors and hook failures. Filter by kind or
    text; click a row to expand it. Tool calls still running show a live timer.
  - **Tools:** calls, error rate, average and maximum duration for each tool.
  - **Processes:** the busiest processes in the agent's tree, with CPU and memory.
  - **Subagents:** each subagent (running and finished) with type, task, model, tokens, tool calls
    and its last action.
  - Header buttons reveal the transcript in Finder, open the working folder, or copy the session ID.

### Machine tab

| Card | Details |
|---|---|
| **CPU** | Total, user/system history, per-core bars split into E-cores / P-cores, load average, process count, thermal state, top 5 processes by CPU |
| **GPU** | Utilisation history, renderer / tiler %, GPU memory in use, model and core count |
| **Memory** | Used of total (Activity Monitor's definition), App / Wired / Compressed / Cached breakdown, memory pressure, swap, top 5 processes by memory |
| **Network** | Download/upload history (mirrored graph), per-interface IPs (Wi-Fi, Ethernet, VPN), session totals |
| **Disk** | Read/write throughput history, IOPS, free space per volume |
| **Sensors** | CPU die temperature (average and hottest), SSD, battery, fan speeds, and an expandable list of every sensor |
| **Battery & Power** | Whole-system power draw in watts with history, charge, time remaining, charge/drain rate, adapter wattage, battery health, cycle count |

Hover over any graph to read the value at that moment. History covers the last 120 samples
(2 minutes at the default 1-second interval).

## Build and run

Needs macOS 14+ and the Xcode Command Line Tools (full Xcode isn't required).

```bash
./build.sh
```

This compiles a release build, wraps it into `Vitals.app`, signs it ad hoc, installs it to
`~/Applications/Vitals.app` and launches it. Use `./build.sh --no-open` to skip the launch.

After that, start it like any app (Spotlight → "Vitals"). To have it start automatically,
choose **Open at Login** from the menu bar item or the **View** menu.

## Controls

From the menu bar item or the app's **View** menu:

- **Menu Bar Shows** – choose any of Working Agents, CPU, GPU, Memory, Network, Disk, Temperature, Power
- **Update Interval** – 0.5 s, 1 s, 2 s or 5 s
- **Keep Dashboard on Top** – also available as the pin button in the window's top-right
- **Show Dashboard on All Spaces**
- **Show Dock Icon** – turn off for a menu-bar-only app
- **Open at Login**

Closing the window keeps Vitals running in the menu bar; click the Dock icon or choose
**Show Dashboard** to bring it back.

## How agent tracking works

- **Claude Code** sessions (desktop app and terminal) are read from Claude Code's own registry,
  `~/.claude/sessions/<pid>.json`, which gives the session title, folder and a busy/idle status.
  That format is undocumented, so each entry is checked against the live process (pid and start
  time) and `claude` processes missing from it are still picked up by executable path.
- **Other agents** (Codex, Gemini CLI, Cursor Agent, Aider, OpenCode, Goose, Amp) and **local model
  runtimes** (LM Studio, Ollama) are recognised by executable or arguments. They report no status,
  so "active" means they used more than 5% CPU or GPU in the last sample.
- **Resource use** is the sum over the agent's whole process tree: tool commands, builds, MCP
  servers, background jobs. CPU includes children that have already exited, so bursts of
  short-lived processes count (Activity Monitor and `top` mostly miss them). Processes the agent
  started that later detach are still counted while they run.
- **Logs and metrics** for Claude Code come from its session transcript,
  `~/.claude/projects/<folder>/<session>.jsonl`, read incrementally on a background queue
  (only newly appended bytes are parsed, and bulky request records are skipped unread). The
  format is undocumented, so missing fields are ignored rather than treated as errors. The log
  keeps the latest 2,000 entries; per-minute activity covers the last 24 hours.
- **Subagents** come from `~/.claude/projects/…/<session>/subagents`, with their own transcripts
  parsed the same way. They run inside their parent process, so their resource use is part of
  the parent's numbers.
- **Other agents** don't write a log Vitals can read, so they show resource use only.
- **Not shown:** per-agent power (macOS doesn't carry a finished child's energy up to its parent,
  so the figure isn't reliable) and per-agent network (no API without admin rights).

## Notes

- **Bartender / menu bar managers:** new menu bar items go into Bartender's hidden section.
  Open Bartender's settings and move Vitals to the shown section, or the readout won't appear.
- **Why the build happens in `~/Library/Caches/VitalsBuild`:** this folder is synced by OneDrive,
  which touches files mid-compile ("modified during the build") and adds extended attributes
  that break code signing. `build.sh` copies the sources out and builds there.
- **Top processes** only include processes you own; system daemons running as root can't be
  read without admin rights.
- **Temperatures** come from the IOHID sensor interface Apple uses internally (not a public API),
  and fans/power come from the SMC. Both are read-only, but a future macOS update could
  change sensor names.
- Sensors refresh every 3 s and the process list every 2 s; the dashboard stops redrawing
  while its window is hidden or covered.

## Diagnostics

```bash
~/Applications/Vitals.app/Contents/MacOS/Vitals --dump
```

prints one set of readings to the terminal. `--snapshot out.png [width height]` renders the
dashboard (and `out-menubar.png`, a preview of the menu bar item) without showing a window.

## Layout

```
Sources/Vitals/
  main.swift            entry point and CLI flags
  AppDelegate.swift     window, menu bar item, menus, preferences
  Monitor.swift         background sampling loop and history
  Settings.swift        persisted preferences
  Samplers/             CPU, GPU, memory, network, disk, power, sensors (IOHID + SMC), processes
  UI/                   dashboard cards, charts, components, palette, icon, menu bar renderer
build.sh                build + package + install script
```
