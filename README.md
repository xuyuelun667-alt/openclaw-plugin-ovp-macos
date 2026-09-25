# OVP — Visual Preprocessor for OpenClaw (macOS)

**Give a text-only OpenClaw agent eyes — locally, deterministically, and without burning an agent detour on every screenshot.**

OVP turns a screenshot, a window, or the live screen into a **compact, priority-ranked Visual State** using macOS-native building blocks (Apple Vision OCR, CGWindowList, the Accessibility API). The state is injected as the agent's image input, so a text-only model can answer questions about what's on screen — and, crucially, it stops the agent from going off and re-inventing OCR with a dozen tool calls.

macOS-only, plugin-only. No models are trained, no image ever leaves the machine.

---

## Why this exists

With a text-only model, an inbound screenshot normally arrives as an unreadable reference. The agent then improvises: it tries `view_image` (fails — no vision), then reaches for some OCR script, crops regions, re-runs things, and often still can't answer. Measured on real tasks in this repository's development:

| | no preprocessor | OVP |
|---|---|---|
| Tool calls for one image question | **11–16** (often without converging) | **0** |
| Tokens burned per image task | ≈ +16k in / +10.6k out vs. baseline | +≈0.4k in (the injected state) |
| Task cost | ≈ $0.02 | ≈ $0.0027 |
| Time to first useful answer | tens of seconds of thrash | 0.14–0.41 s |
| Data | may be sent to a third-party vision API | stays on the machine |

The same comparison against a hosted vision model (MiniMax-VL-01, measured on the same images):

| | OVP | hosted VLM |
|---|---|---|
| Cost per screenshot | **$0** | ≈ $0.0105 |
| Latency | 0.14–0.41 s | 11.8–31.2 s |
| Success rate | 6/6 | 6/8 (dense screenshots timed out) |
| Determinism | same input → same output | two runs differed (similarity 0.564) |
| Field-level accuracy (verifiable set) | 94% (16-field poster) / 100% (dialog ground truth) | 88% / 100% |
| Coordinates, Accessibility roles, actions | ✅ | ❌ |

That last row is the part a VLM cannot replace: OVP tells the agent *where* things are and *what can be pressed*.

---

## Install

Requirements: macOS, Node 22.22.3+ / 24.15+ / 25.9+, and (for the engine) Xcode Command Line Tools.

```bash
git clone <this-repo> openclaw-plugin-ovp-macos
cd openclaw-plugin-ovp-macos

npm install
npm run build:engine     # swift build -c release -> ./bin/ovp
npm run build            # tsc -> ./dist
npm test                 # unit tests (no network, no permissions needed)

openclaw plugins install npm-pack:$(npm pack --silent)   # local proof install
```

Then verify permissions **before** trusting anything:

```bash
npm run doctor
# or, through the agent:  visual_inspect { "mode": "doctor" }
```

## Permissions (this is where macOS plugins usually die silently)

OVP needs two grants, given to **the process that runs OpenClaw** (the Gateway/node binary) — child processes inherit them, so `ovp` never needs its own entry:

| Grant | Needed for | Without it |
|---|---|---|
| **Accessibility** | control roles/titles/actions, focused element | control reads are empty (`ui=0`) |
| **Screen Recording** | window list with names, `screencapture` | window list returns unnamed rows; captures can be blank |

System Settings → Privacy & Security → Accessibility / Screen Recording → add the OpenClaw process. `npm run doctor` reports exactly which one is missing, and `mode=doctor` does the same from inside an agent turn.

---

## Usage

Installed, the plugin contributes two things:

**1. Image understanding for inbound attachments.** Paste a screenshot into any OpenClaw chat: the media-understanding stage resolves the plugin's provider (local, no credentials) and the model receives a Visual State instead of an unreadable reference. Nothing to configure.

**2. The `visual_inspect` tool** for live/on-demand reads:

| mode | what you get |
|---|---|
| `state` (default) | the full compact Visual State |
| `headline` | ~400-char triage line (cheap "do I need more?" check) |
| `grep` | substring search over the cached state — returns the match **plus its neighbours** (a label alone is rarely the answer) |
| `region` | the contents of one `x,y,w,h` rectangle |
| `json` | the raw Visual State (bboxes, classes, timings, cache state) |
| `doctor` | permission + engine preflight |

`source` selects `screen` (default), `window` (+ `window_id` from `ovp windows`), or `file` (+ `path`).

---

## The contract (why agents stop re-deriving)

The injected text is not a description; it is a contract designed for a text-only consumer:

```
You are a text-only model. Do not call view_image. Visual information has been preprocessed by OVP and is provided below.
HEADLINE: source=screenshot_file app=unknown | dialog=0 text=55 shown=23 ui=0 | alert=2 error=1 ... | truncated=true
ALERT/ERROR (3):
  ![1252,649,333,30] c=0.50 synthetic system dialog for
  ![1449,755,38,34] c=1.00 好
TEXT (55 total, 20 shown):
  [r1/generic_region 316,94,380,30] OpenClaw … · ⑤ … · 127.0.0.1:18789/chat/main/…
MORE: truncated=true hidden=text:28 ui:0 reg:6 dup:0 noise:4 | query: --grep <s> | --region x,y,w,h | --max-chars N | --headline-only
ESCALATE: vlm:possible_dialog | local state is insufficient here; an opt-in vision call can resolve it (sends the image off-machine).
```

Four rules make it work:

1. **The first line removes a guaranteed-failing round.** A text-only model cannot use `view_image`; saying so up front eliminated that wasted call in every measured run.
2. **Priority, not reading order.** `dialog/alert > error > focused element > frontmost-window text > result-like > everything else`, with a two-pass classifier so a bare button label (`好`, `OK`) only counts as a dialog once dialog/error evidence exists. Alerts and errors are force-included even when the budget is exhausted.
3. **Truncation is stated, and follow-up queries are real.** `truncated`, per-category hidden counts, and working `--grep` / `--region` / `--max-chars` / `--headline-only` verbs. Nobody has to guess what was dropped — measured: this is what turns 11–16 tool calls into 0.
4. **Escalation is declared by the engine, not guessed by the model.** Two triggers came out of measured comparisons: `vlm:possible_dialog` (an alert smells present but no dialog structure was detected — typical for screenshot files, where there is no Accessibility tree) and `vlm:icon_heavy` (almost no text and almost no coverage: the frame is graphics/icons). Both are the cases where a hosted vision model genuinely adds value; both are opt-in.

Budget arithmetic matters: the fixed overhead (preamble + headline + follow-up contract) is ≈460 characters, so `maxChars` below ~800 leaves no room for content. Default is 1500 (≈350–400 tokens) which measured 20–28 lines of real content.

---

## What it reads

- **Text**: Apple Vision OCR (`zh-Hans` + `en-US`, accurate), every item with a pixel bbox and a confidence. CJK confidence is systematically low (0.30–0.50) — it is *not* a failure signal.
- **Controls**: Accessibility-first. On native and Chromium apps this is exact (roles, titles, values, actions like `AXPress`, focused element). Where the tree is absent or its geometry is invalid (Electron shells), invalid rects are dropped and the state says `ax_unreliable=true` rather than reporting wrong coordinates.
- **Windows/apps**: `CGWindowList` — window ids, owners, titles, layers, z-order, frontmost app.
- **Layout**: contrast-projection bands and column gutters → `generic_region`s, marked as heuristic (confidence 0.35) and never labelled with semantics.

## What it does not do

- macOS only (Apple Vision, CGWindowList, AX have no portable equivalent here).
- **No photo/chart/diagram semantics** — that needs a vision model. Use the escalation flag.
- **No object or icon detection.** Icon-only toolbars with no text are unreadable; hover tooltips or templates are the fallback.
- **Structured dialog detection in screenshots is unsolved** and documented as such: `VNDetectRectanglesRequest` saturates with small text-line rectangles and never surfaces a modal box; the "dimmed backdrop + bright centred panel" heuristic fails because **macOS alerts do not dim the background** (measured border-ring median luminance 240). Keyword classification plus the escalation flag is the honest answer for now.
- **Live-screen caching is imperfect**: the menu-bar clock changes pixels, so repeated screen reads miss the pixel-hash cache. Image files hit it reliably (108 ms → 4 ms internally).

## Privacy

Everything above runs locally. The plugin never calls a network API. The optional escalation is exactly that — optional: the state *flags* that a vision model would help and the agent (or you) decides whether to send the image somewhere.

## Architecture

```
openclaw-plugin-ovp-macos
├── src/                     plugin (TypeScript)
│   ├── index.ts             registers the media-understanding provider + visual_inspect tool
│   ├── engine.ts            binary resolution, argument building, output parsing
│   └── doctor.ts            permission preflight (Accessibility / Screen Recording)
├── Sources/ovp/             the engine (Swift, no third-party dependencies)
│   ├── Capture.swift        screen / window / file capture + image metadata
│   ├── OCR.swift            Apple Vision text recognition
│   ├── WindowsAX.swift      CGWindowList + Accessibility tree (+ bbox sanitisation)
│   ├── Regions.swift        contrast/whitespace region segmentation
│   ├── Priority.swift       text classification for the cost-aware renderer
│   ├── Render.swift         the contract renderer (priority + truncation + queries)
│   ├── Pipeline.swift       orchestration, coverage/confidence, escalation decision
│   ├── Cache.swift          two-level cache (raw-pixel hash, state hash)
│   └── Daemon.swift         unix-socket resident process (keeps the Vision model warm)
└── scripts/                 build-engine.sh, doctor.sh
```

The engine is a plain CLI (`ovp inspect …`, `ovp windows`, `ovp ax-check`), so it is usable without the plugin; the plugin only wires it into OpenClaw's image pipeline and exposes it as a tool. A resident daemon keeps the OCR model warm: first call after boot ≈0.7 s, warm calls 0.14–0.41 s.

**Operational note:** the daemon is a long-lived process, so a rebuilt engine only takes effect after it is restarted (`ovp daemon --stop`; the next call starts a fresh one). `scripts/build-engine.sh` does this automatically. This bit us once during development: the CLI forwards to the daemon, so a stale daemon silently serves stale rendering logic.

**Engine resolution order:** plugin config `path` → `OVP_BIN` → `<plugin>/bin/ovp` → `ovp` on `PATH`. The npm package does not ship a prebuilt binary (Gatekeeper quarantine + TCC grants are per-host decisions); build it locally with `npm run build:engine` and either leave it at `bin/ovp` or point the config at it.

## Development

```bash
npm run build:engine     # engine
npm run build            # plugin
npm test                 # unit tests
npm run doctor           # permissions
npm run plugin:validate  # manifest/runtime validation
```

## License

MIT.
