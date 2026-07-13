import Foundation
import PierApplication

enum UserFacingError {
    static func message(for error: Error) -> String {
        message(for: SessionFailure.classify(error))
    }

    static func message(for failure: SessionFailure) -> String {
        switch failure {
        case let .attach(error):
            switch error {
            case .timedOut:
                "接続がタイムアウトしました。ネットワークとtmuxの状態を確認してください。"
            case let .sessionNotFound(name):
                "tmuxセッション「\(name)」が見つかりません。"
            }
        case .sessionTree:
            "tmuxから受信したセッション情報を読み取れませんでした。"
        case .startup:
            "tmuxコントロールモードを開始できませんでした。"
        case .commandProtocol, .tmuxParse:
            "tmuxとの通信内容を読み取れませんでした。再接続してください。"
        case .commandWrite:
            "tmuxへ操作を送信できませんでした。接続状態を確認して再試行してください。"
        case .connection:
            "別の接続処理と競合しました。少し待ってから再試行してください。"
        case let .command(error):
            switch error {
            case .disconnected:
                "tmuxに接続されていません。再接続してからお試しください。"
            case .staleGeneration:
                "接続が切り替わったため操作を完了できませんでした。もう一度お試しください。"
            case .createdWindowCountMismatch:
                "作成したtmuxウィンドウを特定できませんでした。セッションを再読み込みしてください。"
            }
        case let .transport(error):
            switch error {
            case .transport:
                "SSH接続に失敗しました。ホスト、鍵、ネットワークを確認してください。"
            case .authentication:
                "SSH鍵で認証できませんでした。登録した鍵と接続先の設定を確認してください。"
            case .unavailable:
                "現在この操作を利用できません。接続状態を確認してください。"
            case .persistence:
                "データを保存または読み込みできませんでした。もう一度お試しください。"
            case .invalidResponse:
                "接続先から予期しない応答を受信しました。再接続してください。"
            }
        case .cancelled:
            "操作をキャンセルしました。"
        case .unclassified:
            "操作に失敗しました。もう一度お試しください。"
        }
    }
}
