# Attune

**使った結果とフィードバックから、指示・設定を磨いていく場所。**

Attuneは現在、Claude / Codex / Gemini のローカルSkillを管理・改善するmacOSネイティブアプリの開発版です。SwiftUI + SQLite。基本の管理機能はオフラインで利用でき、外部Swiftパッケージは不要です。任意のAI翻訳にはCLIのログインまたはAPIキーとネットワーク接続を使います。

現在の対象はSkillです。plugin管理やCLAUDE.md / AGENTS.md自体の管理機能は未実装です。

## 起動

**macOS 14 Sonoma以降。** 下の手順で作成した `Attune.app` をダブルクリックしてください。Applicationsへの移動は任意です。ローカルbuildはad-hoc署名で、Developer ID署名・公証はありません。別のMacでダウンロード扱いになる場合は、macOSの「プライバシーとセキュリティ」から開く操作が必要になることがあります。

起動時に候補ディレクトリを実際にスキャンします。見つからなければデモライブラリを表示します。左の「Local skills / Demo library」でいつでも切り替えられます。デモのSkill・runには明示的な表示があり、実在するSkillの履歴に混ざりません。

## ソースからビルド

Xcode 15以降（macOS 14 SDK以上）とSwift 5.9以降が必要です。開発・検証環境は Xcode同梱 Swift 6.3.3 / macOS 26 / Apple Silicon です。

```sh
cd Attune
swift build
swift test
swift run Attune
```

`Package.swift` をXcodeで開き、`Attune` scheme / My Mac を選んで実行することもできます。

アプリ形式の作成:

```sh
bash scripts/build-app.sh
open "dist/Attune.app"
```

Intel / Apple SiliconのUniversal版:

```sh
STUDIO_UNIVERSAL=1 bash scripts/build-app.sh
```

任意の場所に中間ファイル・配布物を出すには `STUDIO_BUILD_DIR` / `STUDIO_OUTPUT_DIR` を指定します。

## 試す流れ

1. **Demo library → release-notes** を開きます。Claude / Codex / Geminiのアイコンで絞り込めます。
2. **Run history** でrunを選び、Prompt / Output / Artifact metadata / 関連版と根拠 / 評価を確認します。フィードバックを保存できます。
3. **Improve Skill** を押し、改善点を入力して **Generate AI proposal**。オフラインでは **Local template → Create local draft**。あるいは **Edit current skill directly** で直接編集します。
4. **Review diff** で差分を確認して **Save new version**。v2→v3のように新しい版を保存します。
5. **Versions → Restore** で過去版を新しい版として復元します。runの既存の関連先と根拠は保持します。本文一致だけで実行時の版IDを確定するものではありません。
6. **Local skills** で実在するSkillを開きます。**Add project folder** でプロジェクトを追加し、⌘Rで再検出できます。
7. 実在Skillにも **Add run** からプロンプト・出力・モデル名・関連版（不明も可）・添付ファイル参照を登録できます。これは既存結果の記録で、agent実行ではありません。
8. ライブラリの編集版と元ファイルの最終確認本文が異なる場合、書込み可能なlocal sourceでは **Publish to source…** から固定した版・書込先・差分を確認できます。明示確認後に元の `SKILL.md` をバックアップして置換します。外部管理のsourceは直接反映できません。

AI修正では差分タブを確認してから保存します。改善案・復元はまずアプリのライブラリに保存されます。元のSkillはPublishするまで変更されません。スキャンと閲覧は元ファイルを変更せず、Skill内のスクリプトも実行しません。

## 言語とAI翻訳

左下または設定（⌘,）で **English / 日本語 / 简体中文 / 繁體中文** を切り替えられます。初回はmacOSの優先言語から選び、その後は選択を保存します。本文やユーザーのprompt/outputは自動で翻訳しません。

英語以外のUIでSKILL.mdタブを開くと翻訳ボタンが表示されます。初回に送信先を確認し、表示中の本文だけを送ります。翻訳後は「原文 / AI翻訳」を切り替えられます。**翻訳は閲覧専用**で、元ファイル、ライブラリの版、run履歴には保存しません。キャッシュはアプリ実行中のみ（最大10件）、接続・本文・翻訳先ごとに分けます。翻訳中の取消、エラー表示、再試行に対応しています。

「翻訳設定」で接続方法を選択します:

| 接続方法 | 準備 / 設定 |
| --- | --- |
| Codex CLI | 最新のCLIをインストールして `codex login`。実行ファイルを自動検出、または指定 |
| Claude CLI | 最新のClaude Codeをインストールし、CLIでログイン。実行ファイルを自動検出、または指定 |
| OpenAI API | APIキーを保存。既定モデルは `gpt-4.1-mini` |
| Anthropic API | APIキーを保存。既定モデルは `claude-haiku-4-5` |

モデルIDは接続ごとに変更できます。CLIは空欄でCLI既定モデルを使用します。CLI検出はPATH、Homebrew、`~/.local/bin`、Volta、NVMを確認します。APIキーはmacOS Keychainに保存し、UserDefaults・SQLite・Gitには含めません。設定からキーを削除できます。「接続テスト」は短い固定サンプルだけを送信します。API・CLIともに契約の利用枠や料金が適用されます。

CLIは一時作業ディレクトリと独立セッションで起動します。Codexはread-only sandbox、CLIの追加ツール・hooks・plugins・Skill検出を無効化。Claudeはsafe mode、空のtool/MCP構成、セッション保存なしで実行します。実行にはこれらのオプションを備えたCLIが必要です。翻訳入力は最大100 KBです。長い本文は行境界で約5 KBずつに分割し、既定で同時に最大18リクエストを実行します。「翻訳設定」の「翻訳の並列数」で1〜18件に変更できます。18セクションなら18件を同時に開始し、完了順にかかわらず本文は元の順序で結合します。接続先の同時実行制限や利用上限に達する場合は並列数を下げて再試行してください。並列化による速度向上は接続先にも依存します。コードフェンス内は翻訳に送らず原文を保持します。1リクエストの上限は約120秒ですが、文書全体では数分かかる場合があります。完了セクション数と経過秒数を表示し、すべて成功した場合だけ翻訳表示へ切り替えます。途中失敗・取消時は部分的な翻訳を完成結果として扱いません。非常に長い単一行は構文を壊さないよう分割せず扱います。長い出力はモデル上限に達する場合があり、APIの打切り応答はエラーとして扱います。コード・URLを維持するよう指示しますが、AI翻訳の正確性は保証されないため原文も確認できます。

APIキーとCLIパスは翻訳・AI修正で共用します。**改善用の接続方法とモデルは翻訳用とは別に記憶**します。Skill検出はローカルスキャンです。Gemini CLI/APIや互換APIエンドポイント、AIによる収集は今後の追加候補です。

「Skillを改善」のボタン上に選択中の接続方法・モデルを表示します。改善画面では接続方法とモデルIDを変更でき、生成ボタンの上でも確認できます。初回は既存の接続設定を引き継ぎ、CLIでモデル未指定の場合は選択・入力するまで生成できません。改善時にモデルを変えても翻訳モデルは変わりません。実行時点の指定を固定し、提案のレビュー画面にも表示します。

Codexの候補はローカルの `models_cache.json` の公開表示対象から読み取ります。キャッシュがない・形式が異なる場合もモデルIDを直接入力できます。Claude CLIは `sonnet` / `opus` / `haiku` の候補、APIは既存設定のモデルと既定候補を表示し、任意のIDも入力できます。候補は利用権限の保証ではなく、CLIのエイリアスは接続先で具体的な版に解決されます。指定が拒否された場合に別モデルへ自動変更しません。Codexには明示的に `--model` を渡します（[公式のモデル指定方法](https://learn.chatgpt.com/docs/models)）。

接続実装の参照: [OpenAI Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs)、[Anthropic Messages API](https://platform.claude.com/docs/en/api/messages/create)、[Claude Code CLI](https://code.claude.com/docs/en/cli-reference)。

## 実装済み

| 機能 | MVPの内容 |
| --- | --- |
| Agent adapters | `ClaudeAdapter`, `CodexAdapter`, `GeminiAdapter` を独立した実装として分離 |
| 3ペイン | agent rail / 検索付きSkill一覧 / run・Markdown・versions詳細 |
| SKILL.md | Markdownの簡易プレビューと全文ソース表示、Finder表示、表示専用AI翻訳 |
| 言語 / AI設定 | 英語・日本語・簡体字・繁体字、4接続方式、Keychain、接続テスト |
| Run history | prompt、output、日時、モデル、所要時間、評価、feedback、artifact metadata、任意のversion ID。Claude/Codex/Geminiローカル履歴取込 |
| 永続化 | システムSQLite、WAL、トランザクション、スキーマバージョン |
| Versioning | 初回取込v1、編集・外部変更・復元のたびに単調増加する版 |
| Diff | 行番号付き追加・削除・共通行。比較元/先を選択可能 |
| Rollback | 過去版をコピーした新しい版を追加。既存版・run関連を保持 |
| Improve Skill | 選択コメント / 全体指示、CLI/APIでAI修正案、差分レビュー、指示・モデル・下書きの保存と再開 |
| 実ファイル反映 | origin別のcore保護、固定版の差分確認、byte厳密照合、private backup、atomic replacement |
| Demo | 3 agents × 3 skills。サンプルrun、版、artifact metadata |

## ローカル実行履歴（v0.4）

実Skillを選択中に15秒ごとに同期します。「履歴を同期」で手動更新、「ローカル履歴を取り込む」でagentごとの停止・再開ができます。設定 → ライブラリとプライバシーで対象期間（既定90日／無期限も可）と除外フォルダを設定します。これは選択中のSkillの取り込みで、全Skillの常駐収集ではありません。

| Adapter | 読取先 / 対応する根拠 |
| --- | --- |
| Codex | `$CODEX_HOME/sessions`（既定 `~/.codex/sessions`）。0.155系 `item_completed` の成功したSKILL.md読取と完了ターン |
| Claude | `$CLAUDE_CONFIG_DIR/projects`（既定 `~/.claude/projects`）。JSONLの成功した `Read` tool_resultと `end_turn`回答。sidechainを除外 |
| Gemini | `~/.gemini/tmp` の会話JSON / JSONL。成功した `read_file`（または結果に原文パスを含む `activate_skill`）と、tokensを記録した回答。上書きイベント・rewindに対応 |

- 単なるSkill名・パスの言及、失敗した読取、最終回答がないターンは取り込みません。履歴の捕捉と版照合は別です。ファイルへのアクセス記録は、native Skillの呼出し・指示への遵守・出力品質の証明ではありません。文脈だけで継続したターン、ClaudeのReadを伴わないSkill起動などは対象外です。
- session/turn/skillから安定IDを作り、重複を防ぎ、評価・feedbackを保持します。版関連付けは以下の根拠を表示します。
- 書込イベントを根拠にartifactの名前・パスを記録します（Codex FileChange、Claude Write/Edit、Gemini write_file/replace）。ファイルのコピー、シェルコマンドからの生成物の推測、過去時点の中身の保存は行いません。
- prompt/output/feedback/modelの検索、評価フィルタ、削除に対応。削除IDを保存し、同期で復活させません。対象期間の設定は今後の取り込みを制限します。期間外の既存取込履歴は設定の削除ボタンで明示的に削除し、手動登録は保持します。
- 除外はSkillの元パスと会話ログのパスに適用します。過去の取込内容は自動削除しません。会話に登場する別フォルダまでは内容解析しません。削除後もバックアップ、改善案、元のagentログには内容が残る場合があります。
- 新しい100ファイル、1ファイル32MB、1回128MBが上限。未対応形式・除外・上限・読取失敗を表示します。古い形式やログの欠落、長い会話・分岐では取り込めない場合があります。
- 解析と保存はローカルのみ。履歴本文をAI改善へ渡すのは明示的に選択したときだけです。**Claude/Geminiは公開形式に基づくfixtureで検証し、実ユーザーの全環境での捕捉を保証するものではありません。**

参照: [Codex hooks](https://learn.chatgpt.com/docs/hooks)、[Claude hooks/transcript](https://code.claude.com/docs/en/hooks)、[Gemini session management](https://geminicli.com/docs/cli/session-management/)、[Gemini recording types](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/services/chatRecordingTypes.ts)。正式hookによる実行時の版確定・網羅的な収集は次の段階です。

## 履歴の関連版と改善の編集基準

| 表示する根拠 | 意味 |
| --- | --- |
| 保存本文と一致 | 完全読取として扱える本文のUTF-8 byte列が、このSkillの保存版と一致。実行時にその版IDを使用した証拠ではない |
| 保存本文と一致: 複数の版 | rollback等で同じ本文の版が複数ある。候補IDを保持し、新旧いずれかへ決めない |
| ユーザーによる関連付け | 手動登録で明示的に版を選択。実行時の観測ではない。初期値は「版は不明」 |
| 旧データの関連付け（未検証） | 旧アプリの関連先をそのまま保持。旧方式には部分文字列照合があったため、厳密照合済みとは扱わない。captureがない旧手動／デモデータも確認済みへ昇格させない |
| 版は不明 | 部分読取・切り詰め、未対応形式、完全本文と一致する保存版なし、異なる全文の読取等。run自体は保存・改善に利用可能 |

共通resolverは`Data(content.utf8)`を比較し、空本文を拒否します。trim、改行やUnicodeの正規化、部分一致、最新版へのfallbackは行いません。履歴のcommandは実行せず、現在のSKILL.mdや版作成時刻から過去の版を推測しません。追加保存する読取根拠は完全本文のSHA-256と部分／未対応のフラグだけで、raw logや本文の追加コピーは保存しません。

完全性の判定はhostごとに限定しています（既存ログfixtureで検証）:

- **Codex**: 成功した単一readの`CommandExecution`。対象pathと一致するliteralな単一ファイル`cat`（`/bin/cat`、引用されたpath、`--`も可）と独立したstdoutを扱います。stderr混在、`aggregated_output`のみ、複数command／ファイル、shell wrapper、パイプや展開は版不明。`head`／`tail`／`sed`、範囲指定、明示的な切り詰めも一致に使いません。
- **Claude**: 成功した`Read`の範囲指定なしの装飾されていない文字列、または単一text blockを扱います。offset／limit等の指定、切り詰め表示は部分読取。行番号付きや未知のヘッダー／wrapper、複数blockは版不明です。行番号を取り除いても末尾改行等のbyteを復元できる保証がないため、自動復元しません。
- **Gemini**: 成功した`read_file`の範囲指定なしの文字列、または単一`functionResponse.response.output`文字列を扱います。未知の再帰wrapper、混在結果、範囲指定・切り詰めは一致に使いません。既存のpathを伴う`activate_skill`捕捉は保持しますが、そのイベントだけでは本文や版を確定しません。

未対応の装飾出力や、ログに完全性情報が残らない形式は対応を広げず不明として扱います。生テキスト形式でhostが切り詰めを一切記録しない場合、その欠落を後から検出する保証はありません。同一turnの同じ全文の再読は重複排除し、後続の部分readは完全な根拠を消しません。異なる全文を読んだturnはconflictingとして単一版を選びません。

再取込では読取根拠と関連付けのsnapshotを分離します。同じ完全本文の証拠なら、保存版の追加・順序変更・rollbackで既存の関連先や候補を再計算しません。「一致版なし」も版追加だけでは自動確定しません。新しい完全本文の根拠は部分読取だけだった新形式runを補えますが、異なる全文が加われば不明（競合）になります。手動関連付けと旧未検証は自動同期で確定／付け替えしません。最終回答等の更新、評価・feedbackの保持、削除IDによる再出現防止は継続します。旧runの明示的な再照合UIは今回ありません。

改善画面は**参考履歴の関連版・根拠**と**編集基準版**を別々に表示します。v1の失敗例を参考に現在のv4を改善できます。異なる版・不明・未検証の場合はその利用を確認します。この確認と「runのprompt/output/feedbackをAIへ送る」opt-inは別で、後者は初期OFFです。送信する場合も過去の参考結果であることをAIへ明示します。編集基準は開始時に固定し、下書き再開でも保持します。現在版が変われば保存を拒否し、黙って新しい版へ合わせません。

## 検出パス

| Agent | 自動検出候補 |
| --- | --- |
| Claude | `~/.claude/skills`、`~/.claude/plugins/cache`、追加プロジェクトの `.claude/skills`。`CLAUDE_CONFIG_DIR` に対応 |
| Codex | `~/.agents/skills`、`$CODEX_HOME/skills`（既定 `~/.codex/skills`）、`$CODEX_HOME/plugins/cache`、`/etc/codex/skills`、追加プロジェクトの `.agents/skills` と互換候補 `.codex/skills` |
| Gemini | `~/.gemini/skills`、`~/.agents/skills`、`~/.gemini/extensions`、追加プロジェクトの `.gemini/skills` と `.agents/skills` |

Codexは追加したフォルダから最寄りのGitルートまで、祖先の `.agents/skills` も検出します。Git外では選択フォルダのみです。ディレクトリ探索は深さ制限があり、通常ルートは3階層、Gemini通常ルートは1階層、plugin/extension cacheは5〜8階層です。SKILL.mdを見つけたフォルダの内部には降りません。シンボリックリンクを解決し、agent内で同じ実体を重複登録しません。同じ共有SkillがCodexとGeminiの両方にある場合はagentごとに管理します。

**候補のカタログであり、各CLIの有効化状態・信頼設定・優先順位を完全再現するものではありません。** キャッシュには古いplugin版も含まれることがあります。GUI起動ではシェルの環境変数を継承しない場合があります。必要なら環境変数を指定して実行ファイルを起動してください。権限不足や非UTF-8・2MB超ファイルは警告として「Skill sources」に表示されます。存在しない候補ルートは正常な状態として扱います。

パス候補の参照（2026-09-21確認）:

- [OpenAI公式: Build skills](https://learn.chatgpt.com/docs/build-skills)
- [Claude Code公式: Extend Claude with skills](https://code.claude.com/docs/en/skills)
- [Gemini CLI公式: Managing Agent Skills](https://geminicli.com/docs/cli/using-agent-skills/)

## アーキテクチャ

```text
SwiftUI views
    │
    ▼
StudioStore (@MainActor / ObservableObject)
    ├── SkillScanner → AgentAdapter → SKILL.md（バックグラウンド検出）
    ├── RunHistoryAdapter → Codex / Claude / Gemini adapters → ローカルJSONL（読み取りのみ）
    ├── Versioning / LineDiff / SourcePublisher
    ├── SkillTranslationService → CLITranslationService / APITranslationService
    ├── AIConnectionSettings / CredentialStore → Keychain
    ├── SkillImprovementService → LocalImprovementService
    └── StudioDatabase → SQLite（transaction / WAL）
```

- `Sources/SkillStudioCore/Models.swift`: Skill、SkillVersion、SkillRun、Artifact、LibrarySnapshot。
- `Adapters.swift`: agent固有のパス候補と共通スキャナー。UIやDBに依存しません。
- `RunVersionEvidence.swift` / `RunVersionPresentation.swift`: 完全読取の厳密照合、根拠・候補の保存、再取込の保持規則と表示。
- `CodexRunHistory.swift`: 履歴adapter protocol、完了ターンとSkill読取の対応付け、取り込み根拠、重複を避けたマージ。履歴解析はactorでUIから分離します。
- `Database.swift`: 1つのlibraryレコードにCodableのスナップショットをBLOB保存する、依存なしのSQLite repository。小規模MVP向けに版・run・選択版の更新を1トランザクションで行います。破損したDBを勝手に初期化せず、エラーを表示します。
- `Versioning.swift`: 版の追加・復元・スキャン結果取込・byte差を保持する行diff。
- `SourcePolicy.swift` / `SourcePublisher.swift`: root由来のsource分類、確認要求の固定、現在の環境での書込み可否の再判定、backupとatomic replacement。`PublishOperation`はsource反映とDB保存の部分失敗を区別。
- `SourceStatePresentation.swift`: ライブラリ編集版と元ファイルの最終確認状態の表示。
- `ImprovementService.swift`: `SkillImprovementService.propose(_:) async throws` と入出力型。requestに現在版、選択runのprompt/output/artifacts、feedbackを渡します。
- `Localization.swift` / `Resources/*.json`: 言語選択と4言語の文字列。
- `TranslationService.swift`: 翻訳request、CLI起動、取消、表示用メモリキャッシュ。
- `AIConnections.swift`: 再利用可能な接続設定・認証protocol・Keychain・API transport。テストではHTTP transportを差し替えます。
- `Sources/AgentSkillStudio`: SwiftUI画面、状態管理、ファイル選択、Finder連携。
- `Tests/SkillStudioCoreTests`: 実ディレクトリfixture、symlink、深さ制限、SQLite再起動、版・diff・publish競合等のテスト。

`SkillImprovementService` はオフラインの `LocalImprovementService` と、設定済みCLI/APIを利用する `AIImprovementService` を選べます。翻訳と改善は `TextGenerationService` のtool-free transportを共用し、改善は全文を並列に書き換えず、1回のリクエストでレビュー用の変更案を生成します。

## 選択コメントとAI修正

SKILL.mdの原文・翻訳どちらでも、プレビューまたはソース表示の本文を選択すると吹き出しが開きます。修正指示を入力して「修正内容を確認する」→「AIで修正案を生成」と進み、原文の差分を確認して新版を保存します。右クリックの「選択箇所にコメント」やShift＋矢印による選択でも開けます。全体への曖昧な指示は、既存の「Skillを改善」から入力できます。直接編集・ローカルテンプレートも利用できます。

- AIへ送るのは原文、選択した引用とその文脈、修正指示です。runのprompt/output/feedbackは明示的にチェックした場合だけ追加します。ファイルパスやartifact metadataはアプリから自動添付しません。ただし本文自体に含まれる情報は送信されます。
- 翻訳の選択位置を原文の文字位置として扱いません。AIが原文内の対応箇所を提案し、原文に一意に一致する変更だけを受け付けます。原文プレビューからの変更範囲は選択を含む元の行、ソース表示では選択した範囲に制限します。翻訳経由の対応づけは意味の正しさまで保証できないため、差分を確認してください。
- 指示・選択引用・指定した接続／モデル・元版・修正案・保存先版をライブラリへ保存します。「改善履歴」から確認・下書き再開・削除できます。入力は約350ms後に自動保存し、閉じる際にも保存します。元版が更新された下書きの保存は競合として拒否します。モデルIDは指定値で、CLIエイリアスの解決後の厳密なモデル版まで確定するものではありません。
- キャンセル・再試行・生成中の操作制限・曖昧な一致や重複変更の拒否に対応。生成中に元の版が更新された場合は保存を拒否します。元ファイルへの書き込みは引き続き明示的Publishのみです。
- 原文100 KB、修正指示10 KB、引用10 KB、JSON入力250 KBまで。長文の大規模変更は範囲を絞って行ってください。


## 保存・復旧の動作

既定の保存先:

```text
~/Library/Application Support/AgentSkillStudio/
  studio.sqlite
  studio.sqlite-wal / studio.sqlite-shm  （稼働中に存在する場合）
  Backups/<UUID>-SKILL.md
  LibraryBackups/*.skillstudio
  Recovery-<UUID>/  （破損DBからの復旧時）
```

別ライブラリやデモ専用環境:

```sh
SKILL_STUDIO_DATA_DIR=/tmp/skill-studio-demo swift run Attune --demo
```

`--demo` は初期表示をデモにする指定です。実Skillの検出自体も動きます。デモのartifactはmetadataのみで、存在しないファイルを開くボタンは表示しません。手動で添付したartifactは元ファイルへの参照で、アプリ内にコピーしません。

`activeVersionID`は**ライブラリの編集対象版**です。agentが実際に使用中の版ではありません。版保存・rollbackはライブラリだけを更新し、rollbackも既存版を変更せず新しいrevisionを作ります。詳細画面とVersionsでは、編集版、元ファイルの最終確認時刻・本文に一致する版、Studioが最後にPublishした版を別表示します。同じ本文のv1/v3があれば両方が一致候補です。last-observedも最後のPublishも、現在のdiskやhost使用版の保証ではありません。

再scanでは、元ファイルAに対する未反映の編集版Bがある間に外部変更Cを見つけても、**Bを編集対象に保持**します。Cは元ファイルの最終確認本文として記録し、未保存の本文なら観測版も追加します。次回PublishではC→Bの差分を改めて確認します。未反映編集がないときは元ファイルの本文へ編集対象を追従させ、既に同じ本文の保存版がある場合はそれを再利用します。同じ本文の再scanでは版を増やさず、元ファイルが既にBなら未反映とは表示しません。元ファイルが消えたり読めなくなった場合も、編集版と履歴を保持します。過去runの版関連付けはscanで変更しません。

### 元ファイルへのPublish保護

発見・閲覧できるSkillと、元ファイルへ書けるSkillは別です。外部管理sourceでも履歴、AI改善案、ライブラリ版保存・復元は利用できます。`manual-only` / `disable-model-invocation`等の呼出し設定を編集権限には使いません。

| source origin | 現在の判定・Publish policy |
| --- | --- |
| localUser / localProject / localShared | adapterが確認した通常user・登録project・shared rootなら条件付きで許可。Claude user/project、Codex `.agents/skills`とproject roots、Gemini user/project/sharedが対象 |
| pluginCache | Claude / Codexの既存plugin cache rootは直接反映不可。OS上で書込可能でも不可 |
| synced | Claude `skills/synced`は広いuser rootの内側でも直接反映不可 |
| managed | Codexの既存administrator rootは直接反映不可 |
| bundled | Codex `skills/.system`は直接反映不可 |
| extensionCache | Geminiの既存extensions rootは直接反映不可 |
| unknown | 未分類や旧provenanceは再確認が必要。Codex `$CODEX_HOME/skills`の混在領域は、`.system`以外もuser管理と安全に断定できないためunknown。新しいcatalogや管理設定の推測はしない |
| demo / sourceなし | Publish不可。ライブラリ内の編集は可能 |

分類は表示用scopeやfrontmatterを使わず、adapterのrootとdirectory componentで行います。custom host root・登録projectは従来どおり扱い、同じ実体を複数rootから発見したときは外部管理・不明・リンクの根拠を優先します。保護rootからlocalへのaliasも、既存adapterの探索範囲内で検出します。全plugin registry、hostのmanaged policy、探索深度外の未知aliasを網羅する機能ではありません。

保存した`sourceProvenance`は観測情報で、Publish許可証ではありません。旧データ・復元データを含め、core writerは現在のroot contextから再分類します。画面のdisabled状態やbackup内の分類を書き換えてもそれだけでは許可されません。旧local sourceもfresh scan／確認で安全に再分類できればPublish可能です。backup復元後の画面では再scanを求め、復元だけでは元ファイルへ書きません。

Publishは確認画面を開いた時のSkill ID、書込先、版ID・本文、比較元のbytes・ファイル実体・分類を固定します。実行時と置換直前に再検証し、内容・版・実体・分類が変われば再確認を求めます。別Skillの版や未保存の下書きはPublishできません。同じsourceの処理中と、失敗後の未確認状態では再Publishを止めます。

sourceは最大2 MBの通常ファイルで、所有者と書込権限を確認します。末端・root配下のsymlink、hardlink、missing、directory/FIFO/device、検証root外のsourceを拒否し、新規作成や権限拡張はしません。信頼するhome/project/custom root自身のOS aliasはroot配下のリンクと区別します。sourceのmode・ACL・拡張属性を自分で作成した同一directoryの一時ファイルへコピーし、atomic renameで置換します。比較はUTF-8のbyte列で、trim・改行変換・Unicode正規化をしません。

置換前に実際の比較元bytesをprivate backupへ保存します（directory 0700、file 0600、排他的な新規作成）。backup失敗時はsourceへ書かず、作成済みbackupは後段失敗時も保持します。一時ファイルは自分が作成した実体を確認してcleanupします。外部editorとの照合〜renameの小さな競合余地は残り、完全なcross-process compare-and-swapではありません。

ファイル反映とSQLite保存は単一transactionではありません。**source置換成功後にDB保存だけ失敗した場合は、その部分成功とbackupを明示し、再scan前の再Publishを止めます。** sourceを無条件に自動巻き戻ししません。再scan／再起動でdiskを観測し直して編集版・履歴を保ちますが、保存できなかった操作を後から「前回Publish成功」と捏造しません。

## ライブラリのバックアップと復旧

設定（⌘,）→ **ライブラリとプライバシー** で書き出し／復元します。バックアップにはSkill本文、版、run、artifact参照、改善履歴、プロジェクトパス、履歴収集設定、削除済みIDを含みます。APIキー・CLI認証・UI/モデル接続設定・artifact実ファイル・元のSkillフォルダは含みません。別のMacに移した場合、元パスの再登録が必要なことがあります。

起動時と変更前に最大1時間に1回、自動バックアップを作り最新10件を保持します。復元直前のバックアップは別名で残し、自動世代削除の対象にしません。SHA-256で破損と関連レコードの整合性を確認してから、ライブラリ全体を置換します。チェックサムは暗号化・真正性の署名ではありません。

DBが開けない場合も、設定から正常なバックアップを指定できます。破損したSQLite/WAL/SHMは `Recovery-*` に退避します。正常なバックアップなしに壊れた内容を修復する機能ではありません。元のSkillファイルには書き込みません。バックアップには会話本文があるため、Git対象から除外しています。

同じ保存先の新アプリを同時起動するとライブラリロックで拒否します。SQLite保存時にも読み込み後の外部変更を照合して上書きを止めます。ロックを知らない旧版との同時起動は避けてください。

## 接続診断と配布

設定 → AI接続 → **接続の準備状態を診断** で実行ファイル、CLI版、必要な安全設定／出力オプション、ログイン状態を確認します。診断はversion/help/auth statusだけを実行し、プロンプトを送りません。生の認証出力は表示・永続化しません。アカウントやモデルの利用可否は、既存の短いサンプルによる「接続テスト」で確認できます。

GitHub Releasesを配布先とします。設定 → **配布と更新** からリリース一覧と、公開後の更新確認を利用できます。privateの間はブラウザでGitHubにログインし、リポジトリのアクセス権を持つ人がダウンロードします。アプリにGitHubトークンは保存せず、自動インストールも行いません。

[配布手順](RELEASING.md)にUniversal ZIP、Developer ID署名、公証、検証、履歴なしソースの公開準備をまとめています。[Agentバッジと資産の扱い](BRAND_ASSETS.md)も参照してください。

## 現時点の制限

- バージョン管理対象は **SKILL.md本文**。scripts / references / assetsはスナップショットしません。
- 履歴は上記の形式と読取根拠に限るbest-effort取込です。正式hooks、Skillのagent実行、evalは未接続です。
- frontmatterはname / descriptionの簡易読取で、完全なYAMLパーサではありません。元の本文は加工せず保持します。
- Markdown previewは見出し・インライン装飾・段落中心の簡易表示です。厳密な確認にはSourceを使えます。
- SQLiteは小規模向けのスナップショット保存。大量runでは正規化テーブル・索引・ページングに移行する想定です。
- 同じライブラリの同時編集はロックで拒否します。大量データの差分更新や複数writerの協調編集は未対応です。
- ファイル監視は未実装。起動時・⌘R・project追加/削除時に再検出します。
- UIは4言語。標準のmacOSメニューやファイル選択ダイアログはOS言語に従う場合があります。本文やユーザーデータは原文を保持します。
- サンドボックス化、公証、App Store配布は未対応です。

## 次の実装候補

1. **Hooksによるrun capture**: agent別のhook adapter / JSONイベント取込、重複防止キー、run開始・終了、artifact収集。プロンプトをログから推定せず実行時のSkill版hashを確定する。
2. **Eval / regression**: 保存runを評価fixtureへ変換。旧版と候補版を同一promptで実行し、形式・正確性・コスト・latencyを比較。改善案をPublish前に検証する。
3. **Cross-agent comparison**: 共有Skillの共通IDとagent別配置を分離。Claude / Codex / Geminiで同一fixtureを実行し、出力と評価を並べる。
4. **AI接続の拡張**: 今回の接続設定をSkill収集にも利用。Gemini、互換API、streaming、費用表示、構造化された改善案に対応する。
5. **Skill bundle versioning**: 本文だけでなくassets・scriptsを含むcontent-addressed snapshot、Git連携、3-way merge、ファイル監視。
6. **配布品質**: 翻訳品質のレビュー、アクセシビリティ監査、UI自動テスト、sandbox bookmarks、Developer ID署名と公証。

## 検証コマンド

```sh
swift test
swift run Attune --scan-report
```

`--scan-report` はDBを開かず、実際に検出したagent別件数と警告を標準出力へ出して終了します。Skill内容は出力しません。

## License / OSS公開

[MIT License](LICENSE)。著作権表示は `Agent Skill Studio contributors`。第三者のSkillや生成結果をこのライセンスで再配布する権利まで付与するものではありません。

ビルドスクリプトは配布バイナリからデバッグ用パスを除去し、アプリ全体を検査してから署名します。

`python3 scripts/check-privacy.py` で追跡ファイルの既知の秘密情報パターン・個人のホームパス・会話ID・データファイルを検査できます。これはヒューリスティックで、検出漏れの可能性とGit履歴が対象外である点に注意してください。GitHub ActionsのCIは未登録です。build/testとこのチェックはローカルで実行できます。

`bash scripts/export-source.sh` はコミット済みのクリーンなHEADから `dist/Attune-source.zip` を作ります。`.git` や開発用生成物を含めませんが、privacy検査だけで全情報の安全を保証するものではありません。repository公開前には、main・他のremote refs・Git履歴のmetadata・GitHub上のPRやRelease等を別に監査し、公開可否を判断してください。ソース公開と、署名・公証を含む正式アプリ配布は別です。詳しくは [CONTRIBUTING.md](CONTRIBUTING.md) と [RELEASING.md](RELEASING.md)。
