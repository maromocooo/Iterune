# GitHub Releasesへの配布

配布先: https://github.com/maromocooo/Attune/releases

ソース公開と正式アプリ配布は別の判断です。正式配布前に以下の検証と署名・公証を行います。
リポジトリの公開設定、push、タグ作成、release公開はビルドスクリプトから行いません。
App Store用のsandboxや審査対応は今回の配布経路に不要です。

## 1. ローカル開発版

```sh
swift build
swift test
STUDIO_UNIVERSAL=1 bash scripts/build-app.sh
bash scripts/package-release.sh
```

`dist/Attune-<version>-macOS-universal.zip` と `.sha256` を作ります。
開発版はad-hoc署名です。`--verify-installation` でDBやSkillを開かず、4言語の同梱を検証します。Agentは画像を使わない文字バッジで表示します。
GitHub ActionsのCIは未登録です。現在は上記のローカル確認を使います。CIを導入する場合もlive testsは有効化しません。

## 2. Developer ID署名と公証

GitHub配布でもDeveloper ID署名とAppleの公証を行うと、他のMacで通常の起動ができます。
Apple Developer Programの有効なDeveloper ID Application証明書・秘密鍵をKeychainへ用意します。
証明書、秘密鍵、パスワードをこのリポジトリに保存しません。

```sh
security find-identity -v -p codesigning
STUDIO_UNIVERSAL=1 STUDIO_SIGN_IDENTITY='Developer ID Application: YOUR IDENTITY' bash scripts/build-app.sh
```

`notarytool store-credentials` で対話的に公証用Keychain profileを準備し、以下を実行します。
アカウント情報やパスワードをコマンド履歴・スクリプトに直書きしないでください。

```sh
xcrun notarytool store-credentials attune-notary
STUDIO_NOTARY_PROFILE=attune-notary bash scripts/package-release.sh
```

この場合はDeveloper ID署名を検査してから、ZIPをAppleへ送信・公証完了を待機・staple・検証し、
staple済みアプリでZIPとSHA-256を再作成します。公証失敗時は終了し、その成果物を公証済みとして配布しません。
実際のDeveloper ID署名と公証は未検証です。証明書や認証情報の準備と利用は、通常のlocal buildとは別に行います。

参照: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

## 3. 公開前の確認

- 使い捨てのライブラリで初回起動、デモ、CLI未インストール、翻訳・改善の接続エラー、バックアップ復元を確認。
- 対象macOS 14以降とIntel実機で確認。Universalのcross-compileだけでは実機確認の代わりになりません。
- OpenAI/Anthropic APIの実アカウント・モデル権限で短いfixtureを確認。HTTP fixtureテストだけで実接続を検証したと扱いません。
- `python3 scripts/check-privacy.py`、同梱資産の出所・条件、`VERIFICATION.md` の未検証事項を確認。
- ブラウザからダウンロードしたZIPで起動、公証、バージョン表示、更新ページを確認。

## 4. 履歴なしソースとリリース作成

```sh
bash scripts/export-source.sh
```

クリーンでcommit済みのHEADからGit履歴を含まないソースZIPを作ります。生成物にもprivacy検査を行いますが、個人情報がないことを保証するものではありません。

ソース公開とアプリ配布は別の判断です。repositoryを公開する前に、現在のmainと他のremote refs、削除済みファイルを含むGit履歴、author/committer/tagger metadata、PR・Issue・Release・Actions・添付物も確認します。最新treeの修正やnoreply設定だけでは過去の情報は消えません。公開用identityと履歴の扱いを確認し、監査の詳細はrepo外のprivate領域へ保存してください。履歴の変更や公開操作は別途承認の対象です。

更新確認は手動opt-inで `maromocooo/Attune` のlatest releaseのみ照会します。PrivateまたはReleaseなしで404の場合は利用不可として案内し、別repositoryへ問い合わせ直しません。自動インストールは行いません。

GitHubでdraft releaseを作り、アプリZIP・SHA-256・ソースZIPを添付し、検証範囲と既知の制限を書きます。
repositoryがPrivateの場合、Releaseを閲覧できるのはreadアクセス権を持つユーザーです。

参照: [GitHub releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)。
