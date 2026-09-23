# 検証と既知の制約

## 検証方法

macOS上で `swift build`、`swift test`、`python3 scripts/test-public-metadata.py`、`python3 scripts/check-privacy.py` を実行します。Git初期化前のexport treeは `python3 scripts/check-privacy.py --directory .` で検査できます。
アプリは `bash scripts/build-app.sh` で作成し、`STUDIO_TEST_BUNDLE="dist/Iterune.app" python3 scripts/test-public-metadata.py` と `dist/Iterune.app/Contents/MacOS/Iterune --verify-installation` で同梱情報を検証します。

テストは合成Skill・履歴と一時directory・隔離DBを使います。通常suiteでは実AI接続・実host履歴のopt-in testsを有効化しません。

## 対象範囲

- 4言語のキー・placeholder、AI翻訳・改善の送信形式、opt-in、厳密patch、固定した編集基準、下書き。
- 履歴の完全本文一致・複数候補・手動関連付け・旧未検証・不明、再取込時の関連付けと評価の保持。
- source origin保護、固定Publish要求、byte-exact比較、private backup、atomic replacement、部分失敗と外部変更下の編集保持。
- SQLite・旧backup互換、復元・競合・破損復旧。実ユーザーのDBやKeychainをテストに使いません。
- Iteruneのproduct/app表示・更新先、別repositoryや不正URLの拒否、404・通信失敗時の安全な扱い。

## 未検証・制約

native Intel、macOS 14実機、全言語の全画面、アクセシビリティ全体の監査は未完了です。Universal cross-compileはIntel実機確認の代わりではありません。
Developer ID署名・公証・ダウンロード後のGatekeeper動作、実AI APIのアカウント権限、全host実ログ形式は別途検証が必要です。
CLIやhostの形式は変わる可能性があり、fixtureの成功は全環境への対応保証ではありません。sourceとSQLiteの一括transactionや外部editorとの完全なcompare-and-swapは保証しません。
privacy scannerはヒューリスティックです。成功しても個人情報の完全不在を保証せず、Git metadataや公開添付物の確認は別途必要です。

## ローカル確認 — 2026-09-23

- `swift build`、native arm64の `bash scripts/build-app.sh` が成功。通常Release buildはproduction互換のbundle IDと保存先を維持。`Iterune.app`の同梱resourceを `--verify-installation` で確認。
- Swift suiteは127件: **122 PASS / 5 SKIP / 0 FAIL**。実履歴・CLI診断・短文翻訳・長文翻訳・AI改善のlive opt-in testsは無効のまま。通常suiteは合成fixtureのみ。
- Debug/Previewの明示root必須、productionとその子・親領域、同じphysical directoryの大文字小文字違い、symlink、hardlink、markerなし既存DBの拒否、独立したfixture DBの再読込とメモリ設定を検証。明示的なproduction設定でもDebugのDB guardは迂回できない。
- Python公開metadata検査は **8 PASS**（生成production app指定でも8 PASS）。3 READMEの言語切替・相対リンク・section、product/app名、4言語キー・placeholder、更新先とURL拒否の既存検査を維持。
- GUI launcherの合成filesystem検査は **4 PASS**。runごとのprivate root、誤ったbundleの拒否、DB/WAL/SHM fingerprint、所有するfixtureだけのcleanupを検証。shell構文検査もPASS。
- 生成物とGit管理情報を除いた87ファイルのsource export、通常Release appの10ファイル、開発appの10ファイルでprivacy検査が成功。Developer ID/公証は使用せずlocal ad-hoc署名のみ。
- 専用launcherで新規buildした開発appを起動。Accessibilityと画面で開発表示、合成Skillのみの一覧、合成run・feedbackと版の根拠、改善画面の参考run／基準版、run送信opt-in OFF、保護sourceのPublish無効を確認。通常DBはSQLiteで開かず、起動前後のDB/WAL/SHMのsize・mtime・SHA-256が一致。実AI・実履歴・source Publishは未実行。
- Xcode Preview canvas自体、全言語の全画面、長時間GUI操作は未検証。Preview環境フラグとfixture storeの起動拒否／許可は合成テストで確認。
- 環境: macOS 26.5.1、Apple M4 arm64、Swift 6.3.3、Xcode 26.6。正式署名・公証、Intel/macOS 14実機は未実施。

開発用markerと再検証は誤った起動先を防ぐための仕組みです。同じOSユーザー権限の別processに対するsandboxではありません。既存の古いbinaryには効かないため、GUI検証には専用launcherの新しいbundleを使います。
