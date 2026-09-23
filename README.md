**English** | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

# Iterune

**Refine how your coding agents work.**

Iterune combines *iterate* and *tune*: use an agent, review the result, improve its instructions, and try again.

Iterune is a local-first macOS app for reviewing the results of agent skills and improving the instructions behind them. Review prompts, outputs and feedback, turn disappointing results into improvement proposals, inspect the diff, and save a version. Publish back to the original skill only when you choose to.

Today, Iterune focuses on **Skills** for Claude Code, Codex and Gemini CLI. It works independently: browsing, local editing and version management do not require an API key or another project. AI features are optional.

## Why Iterune

Agent instructions are often edited before a task, then left disconnected from what actually happened. Iterune brings the result and the next instruction change into the same workflow:

```text
Prompt → Agent output → Review / feedback → Skill improvement → Versioned change → Try again
```

A skill catalog is the starting point. The goal is to use real results to decide what to change, review that change, and keep a version you can return to. You run the agent again outside Iterune; it does not automatically rerun tasks or judge whether a change improved quality.

## What it does today

- **Review runs:** import supported local histories or record a result manually; inspect the prompt, output, model, rating, feedback and artifact references.
- **Make targeted improvements:** give an overall instruction or comment on selected `SKILL.md` text, generate an AI proposal, or edit directly. An offline local template is also available.
- **Review before saving:** inspect the original-text diff. AI edits must match the original unambiguously; overlapping or invalid patches are rejected. Save and resume improvement drafts.
- **Version and restore:** save library revisions and restore an earlier version as a new revision, without erasing the intervening history.
- **Keep context clear:** distinguish the reference run's associated version from the fixed version being edited. Older or unknown-version runs can still inform an improvement.
- **Publish deliberately:** keep library changes separate from source files, with source protection, external-change checks and backups.
- **Read in your language:** the app supports English, Japanese, Simplified Chinese and Traditional Chinese. Optional AI translation of `SKILL.md` is for viewing only and does not rewrite the original or save a translated skill version.

History labels describe the evidence behind a version association:

| Association | Meaning |
| --- | --- |
| Matching content | A complete read matches saved text byte for byte. Identical text may belong to several revisions; Iterune keeps the candidates rather than choosing one. |
| Manual association | A user selected the version. It was not observed at execution time. |
| Unknown | The read is incomplete, unsupported, conflicting, or does not match a saved version; a manually recorded run can also leave the version unspecified. |
| Legacy, unverified | An older association is retained without claiming it meets the current verification rules. |

A read record or text match does **not** prove that an agent invoked the skill, followed its instructions, or used a specific revision at execution time. Reimport preserves existing associations and user ratings/feedback under the history merge policy.

## How it works

1. Let Iterune discover local skills, add a project folder, or explore the clearly labeled demo library.
2. Import supported local run history, or use **Add run** to record an existing result.
3. Review the prompt and output, then add a rating or feedback.
4. Open **Improve Skill** or comment on selected skill text. Check the reference run and editing base version separately.
5. Choose a provider/model and generate a proposal, or edit locally. Including the run's prompt, output and feedback in an AI request is **off by default**.
6. Review the diff and save a new library version. A changed editing base requires resolving the conflict rather than silently saving against another version.
7. When appropriate and allowed, open **Publish to source…**, review the destination, fixed version and source diff, and confirm.
8. Run your coding agent again in its usual environment, review the next result, and continue refining.

## Supported agents

| Agent | Skill discovery | Local history import |
| --- | --- | --- |
| Claude Code | User/project skills, synced skills and plugin caches | Supported successful `Read` results with completed turns; sidechain records are excluded. |
| Codex | User/project/shared locations, local/bundled areas, plugin caches and administrator roots | Supported `item_completed` JSONL records of skill reads and completed turns. |
| Gemini CLI | User/project/shared skills and extension locations | Supported conversation JSON/JSONL with `read_file`, or `activate_skill` results that identify the source path, and completed answers. |

These adapters cover specific paths and log formats, not every agent feature or version. Import operates on the selected local skill; it is not comprehensive invocation telemetry. Import controls, time windows and excluded folders are available in settings. Missing or unsupported evidence may leave the version unknown, and manual recording remains available. Discovery does not imply permission to overwrite a source.

AI improvement and translation currently connect through **Codex CLI, Claude CLI, OpenAI API or Anthropic API**. Use an authenticated CLI or configure an API key and model. Gemini catalog/history support does not include a Gemini AI provider connection. Improvement and translation can use separate model settings.

## Source safety and publishing

**Saving or restoring a library version does not change the original `SKILL.md`.** Source Publish is a separate, explicit action.

- Verified user/project/shared local sources can be published to when current file and ownership checks pass.
- Plugin caches, synced, managed, bundled and extension sources stay read-only at the source. Their history, improvement proposals and library versions remain usable.
- Unknown origins require rechecking; unclassified sources remain protected. Demo skills and missing sources cannot be published. Symlink/hardlink and other unsafe file targets are rejected.

The confirmation fixes the version, destination and source contents being reviewed. Iterune checks for external changes byte for byte, creates a private backup before replacement, and asks for a fresh review if the confirmed state changes. These protections are enforced by the core writer, not just a disabled button.

The library editing version and **last-observed source contents** are shown separately. Last observed is not a guarantee of the current disk contents or the version an agent is using. Rescanning an externally changed source preserves unpublished library edits so you can review the difference.

Publishing does not provide a perfect transaction across an external editor and the library database. A small external-editor race remains possible. If the source is written but the database save fails, Iterune reports partial success, retains the backup and requires a rescan before retrying; it does not blindly roll the file back.

## Installation and build

There is **no formally signed and notarized Iterune release yet**. Build from source on **macOS 14 or later**, with **Xcode 15 or later and Swift 5.9 or later**. The app uses SwiftUI and the system SQLite library, with no external Swift package dependencies.

```sh
git clone https://github.com/maromocooo/Iterune.git
cd Iterune
swift build
swift test
bash scripts/build-app.sh
open "dist/Iterune.app"
```

For development and SwiftUI Preview, **an explicit isolated data directory is required**. Debug builds never fall back to the normal library. The dedicated launcher builds a fresh development app, uses synthetic skills/history, disables external services and source Publish, and checks that production DB/WAL/SHM file fingerprints remain unchanged:

```sh
bash scripts/run-gui-smoke.sh
# Or start a Debug build with a new, empty private directory:
SKILL_STUDIO_DATA_DIR="$(mktemp -d /private/tmp/iterune-dev.XXXXXX)" swift run Iterune
```

In Xcode, set `SKILL_STUDIO_DATA_DIR` to an empty private directory in the run/Preview environment. Missing, relative, production or unmarked existing data paths are refused. Development settings stay in memory; API/CLI AI, Keychain, host history and source publishing are disabled. Quit the development app to finish the smoke run; its private evidence is retained by default. `--headless` checks the fixture store without a window.

The normal packaged Release app keeps its existing library location and preferences. A local app build is ad-hoc signed, not Developer ID signed or notarized; this is not a signed download workflow.

An optional Universal build uses `STUDIO_UNIVERSAL=1 bash scripts/build-app.sh`. See [release/build procedures](RELEASING.md) and [verification coverage and known gaps](VERIFICATION.md) for details. Cross-compiling for Intel does not replace testing on an Intel Mac.

On a normal production launch, Iterune scans supported skill locations. If none are found, it opens the demo library; you can switch between **Local skills** and **Demo library**. Demo mode is not an isolated test environment: discovery still runs.

## Privacy

- **Local-first:** the library, run history, versions and drafts are stored locally in SQLite. Scanning and importing history do not send those records to an AI provider or execute commands found in logs.
- **Optional AI requests:** when you generate an AI improvement, the original skill, your instruction and any selected quote/context go to the configured provider. The reference run's prompt, output and feedback are included only if you opt in; that option starts off. Information already present in the submitted text is still sent.
- **Viewing-only translation:** requesting AI translation sends the displayed skill text to the chosen provider. It changes the view, not the source file. Provider terms, network access and usage charges may apply to both AI features, including CLI connections.
- **Credentials:** API keys are stored in macOS Keychain, not in the library or backups. CLI authentication stays with the CLI. No API key is required for offline library use.
- **Explicit source writes:** neither a scan nor a library save publishes a skill. Protected external sources are not silently overwritten.

Library export/restore is available in settings. Backups contain skill text and conversation data, so treat them as private; they are not encrypted by Iterune. They exclude API keys, CLI credentials and the actual artifact files. Artifact entries are references/metadata, not snapshots of past file contents.

## Current limitations

- macOS only; the current editing and versioning unit is the `SKILL.md` body. Supporting scripts, references and assets are not versioned as a bundle.
- History import is best effort. Host formats can change, and not every invocation or result can be captured or assigned a known version.
- AI improvement requires a configured provider and a review of the proposal. It does not guarantee a better result.
- No automatic agent reruns, automated quality judging or before/after artifact comparison yet.
- Source discovery runs at startup and on rescan/project changes; there is no continuous source-file watcher.
- Formal distribution and broader platform/accessibility validation remain unfinished. See [verification notes](VERIFICATION.md).

## Future direction

Today, Iterune focuses on skills. Longer term, we want to explore extending the same **use → review → feedback → refine** loop to the instructions and configuration that shape coding agents more broadly: `CLAUDE.md`, `AGENTS.md`, rules, plugins and other agent configuration.

Managing those files and plugins is **not currently implemented**. This is a direction to explore, not a promised delivery order or release schedule. Iterune should remain useful on its own as that scope develops.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and privacy guidance, and [AGENTS.md](AGENTS.md) for codebase conventions. Use synthetic fixtures and sanitized bug reports; do not attach real conversations, credentials or library databases.

`README.md` is canonical. Update the Japanese and Simplified Chinese READMEs in the same change when user-facing README content changes.

## License

[MIT](LICENSE). Existing copyright notices are retained. This license does not grant rights to redistribute third-party skills, agent branding or generated output. See [asset and attribution notes](BRAND_ASSETS.md).
