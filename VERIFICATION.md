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

- `swift build`、native arm64の `bash scripts/build-app.sh` が成功。product/executable/display nameはIterune、`Iterune.app`の4言語resourceを `--verify-installation` で確認。
- Swift suiteは111件: **106 PASS / 5 SKIP / 0 FAIL**。実履歴・CLI診断・短文翻訳・長文翻訳・AI改善のlive opt-in testsは無効のまま。通常suiteは合成fixtureを使用。
- Python公開metadata検査は **8 PASS**（生成app指定でも8 PASS）。3 READMEの言語切替・相対リンク・section構成、product/app/予定archive名を検証。更新先、別repository・不正URLの拒否、404・通信失敗は合成HTTPで検証。
- Git管理情報・生成物を含まない内容exportの80ファイルと、生成appの10ファイルでprivacy検査が成功。検出0はヒューリスティックの確認範囲に限る。Developer ID/公証は使用せずlocal ad-hoc署名のみ。
- GUI smokeはテスト用の隔離設定が成立しなかったため中断。GUI検証成功とは扱わない。window/menu/About、Agent切替、履歴・改善・Publish保護、設定の更新リンクについて今回の隔離GUI確認は未完了。
- 環境: macOS 26.5.1、Apple M4 arm64、Swift 6.3.3、Xcode 26.6。正式署名・公証、Intel/macOS 14実機は未実施。
