# Raccoon 🦝

English · [简体中文](README.md)

![CI](https://github.com/kidd-cn/Raccoon/actions/workflows/ci.yml/badge.svg)

A native macOS cleanup tool: scan system junk and app caches → categorize and size → preview and select → move to Trash upon confirmation. Free and open source (MIT), mascot is a raccoon, benchmarked against the full feature set of the open-source cleaner Mole, implemented in iterative phases.

- **Native macOS**: Swift 6 + SwiftUI, pure system controls, zero third-party dependencies
- **Bilingual UI**: 简体中文 / English, follows the system language
- **Core value proposition: safety**. Deletions go to the Trash only, regenerable content is checked by default, and four safety gates stand guard

## Current features (Phases 1–7)

- **Five rule categories**: system junk / dev tool caches / app caches / cautious items / AI tools, with 43 built-in declarative rules (`rules.json`); live per-rule progress, cancellable at any time
- **Selection and cleanup flow**: category cards and details (size descending); confirmation dialog (cautious items in their own section, running apps flagged in yellow) → "Move to Trash" → completion report; return to the list from the report and continue with remaining items — no rescan needed
- **Cautious items**: iOS device backups, old macOS installers, local Time Machine snapshots — always unchecked, marked orange, confirmed separately
- **User exclusion list**: excluded paths are never scanned and never deleted; persisted
- **Cleanup history**: the home page shows "Last cleanup freed X"
- **App uninstall**: an app's bundle and associated data previewed together; by default only precisely-attributed regenerable data is checked; running apps carry a yellow notice
- **Orphan leftovers**: scans data left in known `~/Library` locations by uninstalled apps, grouped by high-confidence vs. unconfirmed; unconfirmed items unchecked by default
- **AI cleanup**: scans regenerable content of AI tools (Claude / Claude Code / Cursor / Codex / Ollama / HuggingFace / ChatGPT) — caches, logs, re-downloadable runtimes and model caches; sessions, skills, and other personal data are never listed
- **Disk analysis**: treemap and list views side by side, click-to-drill-down with breadcrumb navigation; selection only in the list with recursive gating; everything unchecked by default, per-item confirmation dialog, Trash only
- **Status monitor**: read-only dashboard of five metric groups (disk / memory / CPU / battery / network); polling pauses when the window is backgrounded; a failing collector only affects its own card
- **System optimization**: suggestions based on current state (disk tight, snapshots reclaimable, login items pending review, crash reports cleanable) with direct links to each module; user-level login items (`~/Library/LaunchAgents`) can be confirmed then moved to Trash; the system level is read-only
- **Menu bar monitor**: persistent read-only menu bar item (one of four metrics) with a dropdown panel of five metric cards and quick actions; launch-at-login via `SMAppService`; threshold notifications at most once per 6 hours per category, reporting only space/percentage — never paths
- **Network traffic display**: the menu bar label, panel, and monitor-page card show ↓/↑ live rates and cumulative usage since boot; data from `sysctl` interface byte counters (same source as Activity Monitor), `en*` physical links only, no double counting under VPN

## Safety design: four gates

The first duty of a cleanup tool is to not delete the wrong things. The four gates are arranged as defense in depth; the first two live in the engine layer and hold even when a rule file is wrong:

| Gate | Mechanism | Description |
| - | ---------- | --- |
| 1 | **Built-in hard protection** | User content directories (`~/Desktop`, `~/Documents`, `~/Downloads`, etc.) and key `~/Library` subdirectories (Mail, Keychains, Preferences, etc.) are protected by path-component-level prefix matching; a hit means the rule is refused at load time, refused at display time, and re-checked once more before deletion. **Rules may be wrong; the engine may not delete wrongly.** |
| 2 | **User exclusion list** | Paths added in Settings are filtered at scan time and never appear in results |
| 3 | **Safety classification** | `safe` rules are checked by default; `cautious` rules are unchecked by default, marked orange, and confirmed in their own dialog section; cache items of running apps are flagged yellow "app is running" and unchecked by default |
| 4 | **Trash only** | The sole deletion implementation is `FileManager.trashItem` — never `unlink`, never erase; the one exception is local snapshot cleanup (`tmutil-thin`), performed by the system `tmutil deletelocalsnapshots` and not restorable from the Trash — hence it is cautious with its own confirmation; the Disk Analysis entry also goes to the Trash only, reusing this single deletion implementation |

Supporting guarantees: a rule-root scope whitelist (must live inside the user's home directory), dual-form symlink validation resolved both before and after, and a failed per-rule validation rejects only that rule with a logged reason — never a silent pass-through.

## Known limitations (summary)

- Without Full Disk Access, Disk Analysis cannot read parts of `~/Library` and honestly shows undersized totals; sizes use 512-byte block usage (`du`-style), not Finder logical size
- `~/Library/Preferences` and `~/Library/Cookies` are fully covered by Phase 1 hard protection and never listed; system-level `/Library` leftovers and privileged operations are out of scope
- Login item management covers only user-level `~/Library/LaunchAgents`; the system level is read-only; App Store–style session login items cannot be enumerated without root
- The menu bar monitor does not sample or notify while the app is not running; launch-at-login may require manual approval in System Settings
- Network rates count `en*` physical links only and can differ from Activity Monitor (which sums all interfaces); cumulative usage is measured since boot and resets on reboot
- Threshold notifications have a 6-hour cooldown; no menu-bar-only mode; memory follows Mach statistics and does not map one-to-one to Activity Monitor's "memory pressure"

Full per-phase limitations: see the design docs and QA checklists under `docs/superpowers/`.

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
| `tool` | no | Tool identifier; required and non-empty when `category = ai` (the AI cleanup page groups by it) |
| `safety` | yes | `safe` (checked by default) / `cautious` (unchecked by default, confirmed separately) |
| `action` | no | `trash` (default) or `tmutil-thin` (local snapshots only) |
| `path` | yes | Supports `~` expansion; must be a concrete directory, no globs at the root |
| `include` | no | File-name glob whitelist (e.g. `[".DS_Store"]`); empty = the directory's entire contents |
| `exclude` | no | Relative glob exclusions |
| `description` | no (recommended) | Bilingual `zh-Hans` and `en` notes — what gets deleted and what happens |

Validation runs per rule at load time; `Sources/ScanKit/RuleStore.swift` is authoritative: `version` must be `1`, otherwise the whole file is rejected; a per-rule failure rejects only that rule (into the `rejected` list with a logged reason) — never silent; **rule roots must live inside the user home directory `~/`**, the sole exception being installer rules matching `Install macOS *.app` under `/Applications`; roots conflicting with hard-protected ones reject the whole rule. **Rules must point only at regenerable content** (caches, logs, build artifacts, re-downloadable package caches); directories containing user data (e.g. the WeChat container or `Application Support` as a whole) are never used as rule roots. Bundled rules are test-enforced bilingual in `description`; `category = ai` requires a non-empty `tool` from the known whitelist (rule-test gates: `aiRulesHaveNonEmptyTool`, `aiRuleToolsAreKnownValues`, `noRuleToolUsesReservedOtherId`). Run `Scripts/test.sh` before submitting.

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
