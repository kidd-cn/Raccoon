# Raccoon 🦝

English · [简体中文](README.md)

![CI](https://github.com/kidd-cn/Raccoon/actions/workflows/ci.yml/badge.svg)

A native macOS cleanup tool: scan system junk and app caches → categorize and size → preview and select → move to Trash upon confirmation. Free and open source (MIT), mascot is a raccoon, benchmarked against the full feature set of the open-source cleaner Mole, implemented in iterative phases.

- **Native macOS**: Swift 6 + SwiftUI, pure system controls, automatic light/dark mode, zero third-party dependencies
- **Bilingual UI**: 简体中文 / English, follows the system language
- **Core value proposition: safety**. File deletion goes to the Trash only; local snapshots are reclaimed via the system `tmutil` (see cautious items); only regenerable content is selected by default; multiple layers of protection as a safety net

## Current features (Phases 1 + 2 + 3 + 4 + 5 + 6 + 7)

- **Five rule categories**: system junk / dev tool caches / app caches / cautious items / AI tools, with 43 built-in declarative rules (`rules.json`); AI rules appear only under the "AI Cleanup" entry and are never shown on the main cleanup page
- **Live scan progress**: per-rule progress feedback, discovered item counts and byte sizes updating in real time, cancellable at any moment (canceling discards the current round's results)
- **Category cards and details**: per-category size/item-count summaries; the details list is sorted by size descending, with app icons, paths, sizes, and status tags
- **Selection and cleanup flow**: select all / deselect all / deselect cautious items; a persistent footer shows "N items selected · X GB"; confirmation dialog (cautious items in their own section, running apps flagged in yellow) → "Move to Trash" → completion report (space freed, success/skip counts with reasons); from the report page, "Back to list" continues with remaining items (cleaned items leave the list, uncleaned ones stay — no rescan needed)
- **Cautious items**: iOS device backups, old macOS installers, local Time Machine snapshots (`tmutil-thin`) — always unchecked by default, marked orange, confirmed separately
- **User exclusion list**: managed in Settings; excluded paths are never scanned and never deleted; persisted across launches
- **Cleanup history**: recorded at `~/Library/Application Support/Raccoon/history.json`; the home page shows "Last cleanup freed X"
- **App uninstall**: an app's bundle and associated data are previewed together; by default only precisely-attributed regenerable data is checked; the bundle is always included, running apps carry a yellow notice
- **Orphan leftovers**: scans data left in known `~/Library` locations by already-uninstalled apps, grouped by high-confidence vs. unconfirmed attribution; unconfirmed items are unchecked by default
- **AI cleanup**: a dedicated sidebar entry that scans regenerable content of AI tools (Claude / Claude Code / Cursor / Codex / Ollama / HuggingFace / ChatGPT) — caches, logs, re-downloadable runtimes and model caches; results grouped by tool, sorted by size descending within each group; only regenerable content is listed — sessions, skills, and other personal data are never listed; models and runtimes are cautious items (unchecked by default, confirmed separately)
- **Disk analysis**: a sidebar "Disk Analysis" entry, scanning the home directory by default (with "Choose Folder…" to rescan any user-readable directory); treemap and list views side by side, treemap click-to-drill-down with breadcrumb navigation; selection happens only in the list, with recursive gating (protected/excluded items cannot be checked, directories containing protected descendants cannot be checked whole, the scan root is never checkable); everything unchecked by default, item-by-item confirmation dialog; cleanup goes to the Trash only, reusing the existing report and history, with the report page labeled "Disk Analysis"
- **Status monitor**: a sidebar "Status Monitor" entry, a read-only dashboard of five metric groups — system disk hero card (used/total bar with purgeable hint, other volumes as small cards), memory (used/compressed/wired/purgeable), CPU (user/system/idle with a 60-point sparkline), battery (charging/on battery/external power), and network (Wi-Fi/wired/other/offline); CPU/memory poll at 2s, disk/battery at 30s, network is event-driven; polling pauses when the window is backgrounded or the page is left; a failing collector only marks its own card "Unavailable" and never takes down the page
- **System optimization**: the monitor page suggests actions based on current state — disk space tight, local snapshots reclaimable, login items pending review, crash reports cleanable — each linking straight to Disk Analysis / Cleanup / Login Items management (the whole section hides when nothing matches); user-level login item management (`~/Library/LaunchAgents`) supports per-item confirmation then move-to-Trash, with in-page exclusion (protected items still listed but with disabled buttons); system-level `/Library/LaunchAgents` and `/Library/LaunchDaemons` are read-only; disabling is recorded in cleanup history (`source: "launch-items"`), restore by putting items back from the Trash
- **Menu bar monitor**: a persistent read-only menu bar monitor — one of four metrics (disk/memory/CPU/network) shown as an icon or icon + value, with the choice and style persisted; the dropdown panel contains five metric cards (CPU sparkline) and quick actions (main window modules, Settings, Quit), refreshed on every open; launch-at-login registers via `SMAppService` (no root required, visible in System Settings, with an explanation when approval is needed); threshold notifications (low disk <10% or <10 GiB, high memory above a threshold defaulting to 85%) fire at most once per 6 hours per category, cooldown timestamps persist across relaunches, and notifications report only space/percentage — never paths or file names. **Read-only monitoring + navigation, carrying no cleanup actions** — every deletion still requires entering the main window and passing the four gates with confirmation
- **Network traffic display**: upgrades the network metric from "connectivity only" to "connectivity + live rates + cumulative usage" — the menu bar network label (icon + value style) shows ↓/↑ short-format rates (falling back to the interface text while rates are not ready); the menu bar panel and the Status Monitor network card show ↓/↑ rates plus cumulative "received/sent" (since boot, reset on reboot); the data source is `sysctl` interface byte counters (the same source as Activity Monitor), counting only `en*` physical links (loopback / VPN tunnels / AirDrop links are naturally excluded, no double counting under VPN); rates come from fast-loop differencing (2s on the monitor page, 5s in the menu bar) and may differ from Activity Monitor (which sums all interfaces) due to this scoping

## Safety design: four gates

The first duty of a cleanup tool is to not delete the wrong things. Raccoon's four safety gates are arranged as defense in depth; the first two live in the engine layer and hold even when a rule file is wrong:

| Gate | Mechanism | Description |
| - | ---------- | --- |
| 1 | **Built-in hard protection** | User content directories (`~/Desktop`, `~/Documents`, `~/Downloads`, etc.) and key `~/Library` subdirectories (Mail, Keychains, Preferences, etc.) are protected by path-component-level prefix matching; a hit means the rule is refused at load time, refused at display time, and re-checked once more before deletion. **Rules may be wrong; the engine may not delete wrongly.** |
| 2 | **User exclusion list** | Paths added in Settings are filtered at scan time and never appear in results |
| 3 | **Safety classification** | `safe` rules are checked by default; `cautious` rules are unchecked by default, marked orange, and confirmed in their own dialog section; cache items of running apps are flagged yellow "app is running" and unchecked by default |
| 4 | **Trash only** | The sole deletion implementation is `FileManager.trashItem` — never `unlink`, never erase; the one exception is local snapshot cleanup (`tmutil-thin`), performed by the system `tmutil deletelocalsnapshots` and not restorable from the Trash — hence it is cautious with its own confirmation; the Disk Analysis entry also goes to the Trash only, reusing this single deletion implementation |

Supporting guarantees: a rule-root scope whitelist (must live inside the user's home directory; the sole exception is macOS installers under `/Applications`), dual-form symlink validation resolved both before and after (an alias pointing into a protected root or escaping the home directory rejects the whole rule), and a failed per-rule validation rejects only that rule with a logged reason — never a silent pass-through.

Known limitations: `~/Library/Preferences` and `~/Library/Cookies` are fully covered by Phase 1 hard protection and are not listed by any entry to this day; system-level `/Library` leftovers and any privileged operations remain out of scope. Phase 3 (AI cleanup) known limitations:

- Covers only the tools in the rule table (Claude, Claude Code, Cursor, Codex, Ollama, HuggingFace, ChatGPT); VS Code Copilot, Windsurf, Zed, LM Studio, etc. can be added later as rules on demand — not in this phase
- Large user data (sessions, skills, agent working data) is **intentionally not listed**; reclaiming `~/.claude/skills`, `Cursor/User`, etc. is left to the user
- `ai.chatgpt-cache` is a standard path, not verified on the author's machine; if absent it simply matches nothing (harmless)
- Cache items of running tools may be skipped due to file locks, reported honestly as skipped
- `anysphere.cursor-agent-worker` (3.0G) could not be confirmed regenerable and is not listed this phase; may be re-evaluated if confirmed later

Phase 4 (disk analysis) known limitations:

- Without FDA (Full Disk Access), large subtrees of `~/Library` are unreadable and appear undersized, honestly so (449 denials measured).
- Sizes use `du`-style 512-byte block usage (not Finder "Get Info" logical size); the two differ noticeably in small-file forests; no hard-link deduplication.
- The treemap is a single-level aggregate; very small subtrees need drill-down or the list view.
- First scans of large directories (e.g. node_modules forests under `~/programs`) take minutes; progress display and cancellation mitigate but do not eliminate this.
- External volumes and `~/.Trash` are out of scope for this phase.

Phase 5 (status monitor + system optimization) known limitations:

- App Store–style session login items cannot be enumerated without root and are not shown; login item management covers only user-level `~/Library/LaunchAgents`
- System-level `/Library/LaunchAgents` and `/Library/LaunchDaemons` are read-only; changing them is up to the user
- SSID is not shown; network status indicates connectivity and interface type only (obtaining SSID on macOS 14+ requires location permission)
- The CPU sparkline is empty for the first polling cycle (no tick delta yet); disk/battery refresh only every 30s
- Memory "used" follows Mach statistics and does not map one-to-one to Activity Monitor's "memory pressure"

Phase 6 (menu bar toolkit) known limitations:

- Menu bar text is limited by available system width; long values may truncate; the "icon only" style preserves the icon
- No sampling or notifications while the app is not running; launch-at-login is required to stay resident, and registration may require manual approval in "System Settings → General → Login Items"
- Menu bar sampling runs on its own cadence: CPU/memory 5s, disk/battery 30s; notifications are evaluated only in the 30s slow loop, so threshold triggers may lag up to 30s (the memory Mach-statistics caveat is the existing Phase 5 item, not repeated here)
- The dropdown panel has only the CPU sparkline (60-point ring history); memory/network are numeric summaries without curves (the rates and cumulative added in Phase 7 are still numeric summaries — no network sparkline)
- No menu-bar-only mode (`LSUIElement` not enabled); the Dock icon remains after the main window is closed

Phase 7 (network traffic display) known limitations:

- Scope is `en*` physical links: numbers differ from Activity Monitor (which sums all interfaces); under VPN this scope excludes tunnel double counting
- The first rate sample after waking from sleep spans the sleep duration and may be distorted; the next tick recovers
- Rate granularity = fast-loop interval (2s monitor page, 5s menu bar), not real-time jitter level
- Cumulative usage is "since boot", reset on reboot; no "today" scope and no persistence

## Build & run

Requirements: macOS 14+, Swift 6.3+ toolchain (Command Line Tools alone suffice, no full Xcode needed); CI verifies with the Xcode toolchain on GitHub's macOS runners.

```bash
swift build            # build
Scripts/test.sh        # full test suite (396 cases) — the only sanctioned test entry; do not run bare swift test
swift run              # run the app (development mode)
Scripts/bundle-app.sh  # assemble Raccoon.app (adhoc signed, output in build/)
```

CI: GitHub Actions (`macos-latest`) runs `swift build` + `Scripts/test.sh` + an L10n key-set parity check — see `.github/workflows/ci.yml`. `Scripts/test.sh` decides automatically based on the active toolchain whether to load the CLT testing macro plugin library; local and CI share the same entry point.

## Contributing cleanup rules

Junk-identification rules are not hard-coded; the app ships a declarative `rules.json` (`Sources/ScanKit/Resources/rules.json`), and PRs adding rules are welcome.

### Schema (v1)

```json
{
  "version": 1,
  "rules": [
    {
      "id": "xcode.deriveddata",
      "category": "dev",
      "safety": "safe",
      "action": "trash",
      "path": "~/Library/Developer/Xcode/DerivedData",
      "include": [],
      "exclude": [],
      "description": {
        "zh-Hans": "Xcode 编译产物,删除后首次编译会变慢",
        "en": "Xcode build artifacts; first build after cleanup will be slower"
      }
    }
  ]
}
```

| Field | Required | Description |
| ------------- | ----- | --- |
| `id` | yes | Globally unique; a duplicate rejects the whole rule |
| `category` | yes | `system` / `dev` / `apps` / `cautious` / `ai` |
| `tool` | no | Tool identifier; required and non-empty when `category = ai` (the AI cleanup page groups by it), enforced by the built-in rule test `aiRulesHaveNonEmptyTool` |
| `safety` | yes | `safe` (checked by default) / `cautious` (unchecked by default, confirmed separately) |
| `action` | no | `trash` (default) or `tmutil-thin` (local snapshots only) |
| `path` | yes | Supports `~` expansion; must be a concrete directory, no globs at the root |
| `include` | no | File-name glob whitelist (e.g. `[".DS_Store"]`); empty = the directory's entire contents |
| `exclude` | no | Relative glob exclusions |
| `description` | no (recommended) | Bilingual `zh-Hans` and `en` notes — what gets deleted and what happens |

Bundled rules are test-enforced bilingual — `bundledRulesCoverAllCategoriesAndHaveLocalizedDescriptions` requires every rule to carry both `zh-Hans` and `en` descriptions; PRs missing them fail the tests. Run `Scripts/test.sh` before submitting. The `tool` field additionally has three built-in rule-test gates: `aiRulesHaveNonEmptyTool` (`category=ai` must carry a non-empty `tool`), `aiRuleToolsAreKnownValues` (values must be in the known whitelist; new tools must first add `canonicalOrder` and the bilingual `ai.tool.*` keys), and `noRuleToolUsesReservedOtherId` (`other` is reserved for the "Other" group).

### Validation rules (executed per rule at load time; `Sources/ScanKit/RuleStore.swift` is authoritative)

- `version` must be `1`, otherwise the whole file is rejected
- A per-rule validation failure rejects only that rule (into the `rejected` list with a logged reason); all other valid rules load normally — never silent
- When `category == "cautious"`, `safety` must be `cautious`; `action == "tmutil-thin"` is allowed only for rules with `safety == "cautious"`
- **Rule roots must live inside the user home directory `~/`** (scope whitelist); sole exception: installer rules under `/Applications` exactly matching `Install macOS *.app` (in `include` glob form)
- Symlink aliases are validated in both pre- and post-resolution forms: an alias pointing into a hard-protected root, or resolving outside the home directory, rejects the whole rule
- A rule root conflicting with a hard-protected root (including component-level prefix checks) rejects the whole rule; overlapping roots among multiple trash rules raise a warning

### Rule targeting principles

**Point only at regenerable content** (caches, logs, build artifacts, re-downloadable package caches). Directories containing user data (e.g. the WeChat container as a whole, `Application Support` as a whole) are never used as rule roots — WeChat caches are pinned to `…/Containers/com.tencent.xinWeChat/Data/Library/Caches`, which excludes chat history.

## Roadmap

| Phase | Scope | Status |
| -- | --- | ---- |
| Phase 1 | App skeleton + core cleanup | ✅ Done |
| Phase 2 | App uninstall + leftovers | ✅ Implemented (manual QA pending) |
| Phase 3 | AI tool cleanup (Claude/Cursor/Ollama etc.) | ✅ Implemented (manual QA pending) |
| Phase 4 | Disk analysis (treemap) | ✅ Implemented (manual QA pending) |
| Phase 5 | Status monitor + system optimization | ✅ Implemented (manual QA pending) |
| Phase 6 | Menu bar toolkit | ✅ Implemented (manual QA passed) |
| Phase 7 | Network traffic display | ✅ Implemented (manual QA passed) |

Each phase runs its own spec → plan → implementation flow; the Phase 1 architecture (sidebar skeleton, rule store, ScanKit/CleanKit split) is the foundation for everything after.

## License

[MIT](LICENSE) © 2026 Raccoon contributors
