# 検証と既知の制約

## 検証方法

macOS上で `swift build`、`swift test`、`python3 scripts/test-public-metadata.py`、`python3 scripts/check-privacy.py` を実行します。Git初期化前のexport treeは `python3 scripts/check-privacy.py --directory .` で検査できます。
アプリは `bash scripts/build-app.sh` で作成し、`STUDIO_TEST_BUNDLE="dist/Attune.app" python3 scripts/test-public-metadata.py` と `dist/Attune.app/Contents/MacOS/Attune --verify-installation` で同梱情報を検証します。

テストは合成Skill・履歴と一時directory・隔離DBを使います。通常suiteでは実AI接続・実host履歴のopt-in testsを有効化しません。

## 対象範囲

- 4言語のキー・placeholder、AI翻訳・改善の送信形式、opt-in、厳密patch、固定した編集基準、下書き。
- 履歴の完全本文一致・複数候補・手動関連付け・旧未検証・不明、再取込時の関連付けと評価の保持。
- source origin保護、固定Publish要求、byte-exact比較、private backup、atomic replacement、部分失敗と外部変更下の編集保持。
- SQLite・旧backup互換、復元・競合・破損復旧。実ユーザーのDBやKeychainをテストに使いません。
- Attuneのproduct/app表示・更新先、別repositoryや不正URLの拒否、404・通信失敗時の安全な扱い。

## 未検証・制約

native Intel、macOS 14実機、全言語の全画面、アクセシビリティ全体の監査は未完了です。Universal cross-compileはIntel実機確認の代わりではありません。
Developer ID署名・公証・ダウンロード後のGatekeeper動作、実AI APIのアカウント権限、全host実ログ形式は別途検証が必要です。
CLIやhostの形式は変わる可能性があり、fixtureの成功は全環境への対応保証ではありません。sourceとSQLiteの一括transactionや外部editorとの完全なcompare-and-swapは保証しません。
privacy scannerはヒューリスティックです。成功しても個人情報の完全不在を保証せず、Git metadataや公開添付物の確認は別途必要です。

## ローカル確認 — 2026-09-23

- `swift build` とnative arm64の `bash scripts/build-app.sh` が成功。product/executable/app表示はAttune、4言語resourceの同梱検証も成功。
- Swift suiteは111件: **106 PASS / 5 SKIP / 0 FAIL**。SKIPは明示opt-inが必要な実履歴・CLI診断・短文翻訳・長文翻訳・AI改善。実AI接続は行っていません。
- Python公開metadata検査は6 PASS（生成app指定でも6 PASS）。更新先・別repository拒否・404・通信失敗は合成HTTP応答で検証。
- source 78ファイル、app 10ファイルのprivacy検査は検出0。個人名のない一時build pathで生成し、Developer ID/公証は使用せずlocal ad-hoc署名のみ。
- 専用bundle/UserDefaults・DB・合成Skill・注入した探索root/資格情報/HTTPのGUIで、Attune表示、3agent切替・バッジのアクセシビリティ名、4言語の主画面、履歴根拠・編集基準・AI送信OFF、下書き保存、synced元へのPublish禁止とライブラリ改善の導線を確認。
- 更新設定画面のGUI確認は未完了です。履歴選択欄は言語切替直後に前の言語が残る場合があり、即時切替の全画面追従は未検証です。通常利用中のSkill/DB/Keychain/host設定は使用・変更していません。
- 環境: macOS 26.5.1、Apple M4 arm64、Swift 6.3.3、Xcode 26.6。正式署名・公証、Intel/macOS 14実機は未実施です。
