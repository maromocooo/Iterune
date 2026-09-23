# Contributing

Iterune is a Swift Package for macOS 14+. Contributions are licensed under MIT.

Run `swift build`, `swift test`, `python3 scripts/test-public-metadata.py` and `python3 scripts/check-privacy.py` before a pull request. Tests use temporary fixtures; opt-in live tests contact a provider only when explicitly enabled. Do not enable live tests in CI.

`README.md` is canonical. When user-facing README content changes, update `README.ja.md` and `README.zh-CN.md` in the same change. Keep current capabilities, limitations and future directions consistent across all three.

Keep UI in `Sources/AgentSkillStudio` and portable application logic in `Sources/SkillStudioCore`. Update all four localization catalogs together. Changes to source skills require the explicit Publish flow; AI responses are proposals, never direct file operations.

Never commit real skills, prompts, outputs, run history, SQLite databases, auth files, API keys, local paths, account email addresses or conversation IDs. Use synthetic examples and inspect `git diff --cached` before committing. Screenshots and logs can contain private data too.

The privacy script is heuristic and checks the current tracked tree. It does not inspect past commits, Git author/committer metadata or GitHub attachments. Confirm a public commit identity before contributing; use the exact noreply address supplied by GitHub if you do not want a personal email in commits. Changing identity does not remove previous metadata. The source archive omits `.git`, but neither that archive nor a clean scan replaces a repository-wide pre-publication review. Keep detailed audit records outside the repository.

Report bugs with sanitized reproduction steps and versions. Do not attach your full skill library, credentials or local database to public issues.
