# Attune — contributor guidance

- SwiftUIベースのmacOSネイティブアプリです。README.md、変更対象のコード・テストを読み、`git status` で状態を確認します。既存変更を消さず、依頼範囲を意味単位のcommitに分けてください。
- Swift Packageを維持し、`Sources/SkillStudioCore` はUI非依存、`Sources/AgentSkillStudio` はSwiftUIとアプリ状態管理です。host固有のdiscovery/historyはClaude・Codex・Geminiのadapterへ分離し、UIにパス規則を埋め込みません。
- 履歴の捕捉、完全本文のbyte一致、実行時の版ID確定は別です。matching-contentの複数候補、manual、legacy-unverified、unknownを保持し、再取込で過去の関連付け・評価を変えないでください。改善の参考runと固定された編集基準版も区別します。
- AI改善・翻訳は実装済みです。ローカルテンプレートは別のオフライン機能です。prompt/output/feedbackのAI送信は明示opt-inを保ち、AIの提案は厳密なpatch検証と差分レビューを経てライブラリへ保存します。基準版の競合検知を維持します。
- ライブラリ保存・rollbackと元ファイルへのPublishは別です。読取・scanでは元Skillを変更しません。Publishはcoreでoriginと現在のroot/path/file状態を再確認し、plugin/synced/managed/bundled/extension/unknownを保護します。UIのdisabledや保存済みprovenanceだけを権限にしません。
- Publishの確認対象版を固定し、byte-exactな外部変更チェック、private backup、atomic replacementを維持します。未反映編集を再scanで失わず、source成功・DB失敗は部分失敗として明示します。last-observedは現在のhost使用版の保証ではありません。
- SQLiteと旧backupの互換性、ID、改善下書き、履歴根拠を保持します。大規模migrationや別機能への拡張は依頼範囲を確認してください。
- テストは合成fixture、一時directory、隔離DBのみ。実Skill、prompt/output、履歴、Keychain、host認証設定を使用・変更しません。live opt-in testsは明示依頼なしに有効化しません。GUIもhome、UserDefaults、discovery roots、`SKILL_STUDIO_DATA_DIR` を隔離します。
- 標準確認はmacOSで `swift build`、`swift test`、`python3 scripts/check-privacy.py`、必要なlocal app buildは `bash scripts/build-app.sh`。変更した挙動の回帰テストを追加し、4言語のキーとplaceholder整合を保ちます。PASS/FAIL/SKIP/未実施を区別し、必要な結果だけVERIFICATION.mdへ記録します。
- 実データ・認証情報・個人path・監査の生レポートをGitや配布物へ含めません。公開用commit identityを確認し、staging対象を明示します。privacy scriptは最新treeのヒューリスティックで、Git履歴やGitHub上の公開面を保証しません。
- ソース公開と正式アプリ配布は別の判断です。署名・公証、tag/Release、visibility変更、履歴書換え、mainへのmergeは個別の許可範囲に従います。現在の制約と配布手順はRELEASE_PLAN.md / RELEASING.mdを参照してください。
