# CLAUDE.md

このリポジトリで作業するためのガイド。

## プロジェクト概要

Pier — SSH先のマシンをモバイルネイティブUIで操作するiOSアプリ（tmuxコントロールモード前提）。仕様と設計は `spec/` 配下にある。

- `spec/overview.md` — 概要と技術判断の要約
- `spec/user-stories.md` — 要件（恒久IDつきユーザーストーリー、MVP = 23件）
- `spec/design.md` — UI仕様・技術ノート・実装フェーズ
- `spec/architecture.md` — レイヤー構成・ポート・ディレクトリ（本ドキュメントのアーキテクチャ節の詳細）

## 原則

- 型安全を最優先し、Swiftの型システムに全面的に頼る。不正な状態はランタイムチェックの前に、まずenum・structで型レベルで表現不可能にする
- Domain / Application はステートレスで純粋な関数型のコードを基本とする。状態を持つものはactorに閉じ込める（`TmuxGateway` が代表例）
- バリデーションは境界の2点のみ: transport境界（tmuxの生バイト → `TmuxMessage`）と値オブジェクト構築（業務不変条件）。その間は静的型を信頼する
- 時刻・ID生成・ログなどの横断的関心事はポートの裏に置き、Domain / Application を決定的でテスト可能に保つ
- コメントはデフォルトで書かない。WHYが非自明なとき（隠れた制約、不変条件、回避策）だけ書く。公開APIのdocコメントは歓迎
- 環境時刻（`Date()`）・乱数への直接アクセスをコアに書かない。`Clock` ポートを経由する

## 実装指針

原則（方針・WHY）に対する具体的な実装テクニック（HOW）。

- プリミティブは意味のある型でラップする（`struct UserId`）
- OR関係は enum（associated values付き）、AND関係は struct
- `!` による強制アンラップ禁止
- 未検証型と検証済み型を分ける（Parse, don't validate）
- イニシャライザは private にし、`static func parse -> Result` 経由で生成
- ドメインエラーは enum で列挙し、`Result` か typed throws で返す
- `switch` は `default` を避けて網羅する
- 状態遷移は型を変える純粋関数で表す
- ドメインロジックは純粋関数・値型で書き、副作用はエッジに押し出す
- `let` + 値型でイミュータブル、更新は新しい値の生成
- ドメイン型は `Sendable` に準拠させる

## 開発環境とコマンド

Nix devShell（direnv）でツールが入る。XcodeとSwiftツールチェーンはNix管理外（システムのXcodeを使う）。

- `xcodegen generate` — Xcodeプロジェクト生成
- `swift test` — PierCoreパッケージのテスト（UI非依存なのでmacOS上で実行できる）
- `xcodebuild ... | xcbeautify` — アプリターゲットのビルド
- シミュレータへのインストール・起動は通常署名で行う。`CODE_SIGNING_ALLOWED=NO` はコンパイル確認専用（Keychainを利用できない）
- `swiftformat . && swiftlint` — 変更後に実行する

## アーキテクチャ

ヘキサゴナルアーキテクチャ。依存は内向きのみ: App → Adapters → Application → Domain。ポートはコア側が定義し、アダプターが実装する。詳細は `spec/architecture.md`。

### レイヤー

- **Domain**（`PierCore/Sources/Domain/`） — 純粋なビジネスロジック。tmuxプロトコル（`TmuxParser`、セッションツリー、`PaneGrid`）、ホスト・鍵・ブロック・ファイルのモデル。I/Oなし、フレームワークなし。feature固有のリポジトリポートは各featureの `Ports/` に置く
- **Application**（`PierCore/Sources/Application/`） — ユースケース（1個1ファイル）と長生きする状態（`TmuxGateway`, `SessionModel`）。横断的ポート（`TransportPort`, `Clock`, `Logger` 等）はここの `Ports/` に置く
- **Adapters**（`PierCore/Sources/{Citadel,Keychain,Persistence}Adapter/`） — ポートの具象実装。プロバイダごとにSPMターゲットを分ける
- **App**（`App/`） — SwiftUI。composition root（DI結線は Live / Preview / Test の3系統）。SwiftTerm統合とすべてのViewを持つ

### レイヤーではないもの

- `PierCore/Sources/Support/` — 共通エラー基底などの構造的プリミティブ。レイヤーツリーの外に置くことで、全レイヤーが内向き規則を破らずに依存できる

### 依存方向の強制

SPMターゲット分割により、コアがアダプターを `import` するとコンパイルエラーになる。新しい外部依存（ライブラリ・OSサービス）を足すときは、必ずポートを定義して新アダプターターゲットに置く。

### 長生きする状態

Pierは常時接続のストリーミングアプリであり、リクエスト/レスポンス型ではない。`TmuxGateway`（actor）と `SessionModel`（`@Observable`）は接続の生存期間だけ生きるアプリケーション状態で、ユースケースは「生きているGatewayに対するコマンド」になる。

## エラー処理

- エラーは共有契約（Support層の基底 + 各レイヤーのエラー型）で表現し、ユーザー向け表示への変換はApp層でのみ行う

### クロスレイヤーのcatchポリシー

- **adapter → application**: アダプターがドライバ固有エラー（Citadel例外等）をcatchし、共有エラー契約に翻訳する。コアはprovider-nativeなエラーを見ない。ドライバレベルの一時エラーのリトライもアダプター内で行う
- **domain → application**: ドメインエラー（不変条件違反）はユースケースを素通しする。ユースケース境界で再翻訳しない
- **application → App**: App層の境界でcatchしてユーザー向け表示に変換する。ユースケース自身は表示を知らない
- 広い `try/catch`（`catch {}`）は上記の明示的な境界だけに許す

## テスト

実機・実サーバーなしで大半を検証できることをアーキテクチャで保証している。この性質を壊さない。

- `TmuxParser` は実サーバーのトランスクリプトをフィクスチャにした単体テストで開発する（フィクスチャファーストで進める）
- `TmuxGateway` とユースケースは `FakeTransport`（トランスクリプト再生）でテストする
- 再接続復元（`reconnectAndRestore`, A5 / F1）はこのアプリの生命線なので、テストを厚くする
- 新しいポートを足したら、Test結線用のFakeを必ずセットで用意する

## パフォーマンス

`%output` → `PaneRendererPort` → SwiftTermの `feed()` はホットパス。抽象の層を重ねない・ホットパス上でアロケーションを増やさない。
