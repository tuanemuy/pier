# アーキテクチャ — Pier

最終更新: 2026-07-11
関連ファイル: `OVERVIEW.md`（概要）、`USER_STORIES.md`（要件）、`DESIGN.md`（設計書）

## 方針

ヘキサゴナルアーキテクチャ（ports & adapters）を採る。依存は内向きのみ。

- コア（Domain / Application）はUI・SSHライブラリ・永続化のいずれにも依存しない
- ポート（protocol）はコア側が定義し、アダプターが外側からそれを実装する
- SPMターゲットを分割し、依存方向を規約ではなくコンパイラに強制させる（コアのターゲットはアダプターを `import` できない）

`DESIGN.md` §3 の3層構成（App → TmuxKit → ConnectionKit）を精緻化したものであり、コンセプトは変えていない。TmuxKit の中身は Domain と Application に分かれ、ConnectionKit は `TransportPort` を実装する CitadelAdapter となる。依存の矢印は TmuxKit → ConnectionKit ではなく、CitadelAdapter → コアの向きに反転する。

## レイヤー

### Domain

純粋なビジネスロジック。I/Oなし、フレームワークなし、環境時刻・乱数への直接アクセスなし。

- tmuxプロトコルがこのアプリのドメインの中心。`TmuxParser`（1行 → `TmuxMessage` の純関数）、セッション→ウィンドウ→ペインのツリー、`PaneGrid`（カードデッキのグリッド座標計算）はすべてここに置く
- スワイプ方向から `split-window -h/-v/-b` のどれを発行するかの判定など、UIに見えて実はドメインである座標ロジックもここでテストする
- feature固有のリポジトリポート（`HostRepositoryPort` 等）は該当featureの `Ports/` に置く

### Application

ドメインを編成するユースケースと、長生きするアプリケーション状態。

- ユースケースは1個1ファイル（`attachSession`, `splitPane`, `reconnectAndRestore`, `runCommand`, `saveRemoteFile` …）
- 横断的関心事のポート（`TransportPort`, `Clock`, `Logger` 等）はここの `Ports/` に置く
- `TmuxGateway`（actor。コマンド送信FIFOと `%begin`/`%end` 応答の突き合わせ、非同期通知のディスパッチ）と `SessionModel`（通知を畳み込んだ観測可能な状態）もこの層。詳細は後述の「長生きするアプリケーション状態」

### Adapters

ポートの具象実装。プロバイダごとにターゲットを分ける。

- ドライバ固有のエラー（Citadel例外等）はアダプター内で共有エラー契約に翻訳する。コアはprovider-nativeなエラーを見ない
- ドライバレベルの一時エラー（再送で解決する類）はアダプター内でリトライする

### App（composition root）

SwiftUIのアプリターゲット。ヘキサゴナルにおける driving adapter そのもの。

- 全アダプターとコアの結線（DI）はここで行う。結線は Live / Preview / Test の3系統
- カードデッキ・チャットUI・エディタ・サイドバー等のViewと、SwiftTerm統合（`PaneRendererPort` の実装）を持つ
- エディタは `RemoteFileEditor` プロトコルの裏に置いて差し替え可能にする（`DESIGN.md` §5）。これはUI内部の差し替え点であり、コアのポートではない

### Support（レイヤーではない）

共通エラー基底などの構造的プリミティブ。レイヤーツリーの外に置くことで、全レイヤーが内向き規則を破らずに依存できる。

## ディレクトリ構成

```
Pier/
├── App/                        # Xcodeアプリターゲット（composition root）
│   ├── DI/                     # Live / Preview / Test の結線
│   ├── Views/                  # カードデッキ / チャット / エディタ / サイドバー
│   └── Terminal/               # SwiftTerm統合（PaneRendererPort実装）
└── PierCore/                   # SPMパッケージ（複数ターゲット）
    ├── Sources/
    │   ├── Support/            # レイヤー外の共通基盤（エラー基底など）
    │   ├── Domain/
    │   │   ├── Common/         # 共通VO（PaneID, GridPosition など）
    │   │   ├── Tmux/           # TmuxParser, TmuxMessage, セッションツリー, PaneGrid
    │   │   ├── Hosts/          # Host, SSHKey / Ports: HostRepositoryPort, KeyStorePort
    │   │   ├── Blocks/         # CommandBlock（OSC 133 のブロックモデル）
    │   │   └── Files/          # RemoteFile
    │   ├── Application/
    │   │   ├── Ports/          # TransportPort, FileTransferPort, PaneRendererPort, Clock, Logger
    │   │   ├── Session/        # TmuxGateway, SessionModel, attachSession, splitPane, reconnectAndRestore …
    │   │   ├── Hosts/          # registerHost, generateKey, connectToHost
    │   │   ├── Blocks/         # runCommand, rerunCommand
    │   │   └── Files/          # openRemoteFile, saveRemoteFile
    │   ├── CitadelAdapter/     # TransportPort + FileTransferPort（SSH / SFTP）
    │   ├── KeychainAdapter/    # KeyStorePort（Secure Enclave / Keychain）
    │   └── PersistenceAdapter/ # HostRepositoryPort（SwiftData）
    └── Tests/
        ├── DomainTests/        # TmuxParser のフィクスチャテスト
        └── ApplicationTests/   # FakeTransport + 実サーバートランスクリプト
```

ターゲットの依存関係:

```
Domain        → Support
Application   → Domain, Support
各Adapter     → Application, Domain, Support
App           → 全部（結線のため）
```

## ポート一覧

| ポート | 配置 | 役割 | MVP実装 | 将来 |
|---|---|---|---|---|
| `TransportPort` | Application/Ports | SSH経由のバイトストリーム送受信、接続/切断イベント | CitadelAdapter | Rustサーバーエージェント |
| `FileTransferPort` | Application/Ports | リモートファイルの読み書き | CitadelAdapter（SFTP） | Rustエージェントの高速API |
| `PaneRendererPort` | Application/Ports | デコード済み `%output` バイトの供給先 | App（SwiftTermの `feed()`） | — |
| `Clock` / `Logger` | Application/Ports | 実行時間計測・再接続バックオフ・ログ | App標準実装 | — |
| `KeyStorePort` | Domain/Hosts/Ports | 鍵の生成・署名（秘密鍵は外に出ない） | KeychainAdapter | — |
| `HostRepositoryPort` | Domain/Hosts/Ports | ホスト設定の永続化 | PersistenceAdapter | iCloud同期（I6） |

feature固有のポートは Domain の該当featureに、横断的なポートは Application に置く。

## 長生きするアプリケーション状態

Pierは常時接続のストリーミングアプリであり、1回呼んで終わるユースケースだけでは構造を表現できない。接続の生存期間だけ生きる状態に明示的な居場所を与える。

- `TmuxGateway`（actor）と `SessionModel` はユースケースではなく、接続の生存期間だけ生きるアプリケーション状態。`Application/Session/` に置く
- ユースケースは「生きているGatewayに対するコマンド」になる（`splitPane` は Gateway に `split-window` を送る操作）
- `SessionModel` は `@Observable` でSwiftUIから直接観測する。Observationフレームワークへの依存はコアの純度より実利を取って許容する

## DI

結線は実行文脈ごとに3系統に分ける。

- Live: Citadel / Keychain / SwiftData の実アダプター
- Preview: SwiftUIプレビュー用のインメモリ実装
- Test: `FakeTransport`（トランスクリプト再生）ほかのFake群

## テスト戦略

実機・実サーバーなしで大半を検証できることをアーキテクチャで保証する。

- `TmuxParser`: 実サーバーのトランスクリプトをフィクスチャにした単体テスト（`DESIGN.md` の方針どおり）。実装フェーズ1の起点
- `TmuxGateway` + ユースケース: `FakeTransport` にトランスクリプトを流す統合テスト
- `reconnectAndRestore`: 再接続 → 再アタッチ → `capture-pane -e -p` による復元、という最も壊れやすいフロー（A5 / F1）を重点的にFakeで検証する。このテスト可能性がポート分離の最大の動機
- `PaneGrid`: スワイプ方向と分割コマンドの対応を含む座標ロジックの単体テスト

## 意図的に持ち込まないもの

| 持ち込まないもの | 理由 |
|---|---|
| 独立したpresentation層 | SwiftUIのApp層が driving adapter を兼ねる。HTTP境界が存在しない |
| Unit of Work / ドメインイベント配送 | DBトランザクションもイベント配送も存在しない。持ち込むと過剰設計になる |

## パフォーマンス上の注意

`%output` → デコード → `PaneRendererPort` → SwiftTermの `feed()` はホットパスである。

- `PaneRendererPort` は「デコード済み `Data` を渡すだけ」の薄い口に保ち、抽象の層を重ねない
- 非フォーカスカードの描画停止（`DESIGN.md` §4.2）と組み合わせてGPU・CPU負荷を抑える
- カードデッキのジオメトリ定数（PEEK, UNDER 等）は純粋なプレゼンテーション関心事としてApp層に置く
