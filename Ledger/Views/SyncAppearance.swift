import SwiftUI

/// Display only: whether something is waiting, needs attention, or is being sent.
enum SyncAppearance: Equatable {
    case synced, waiting, offline, held, failed, syncing

    init(state: SyncState, waiting: Bool, held: Bool, failed: Bool) {
        if state == .syncing { self = .syncing }
        else if state == .error || failed { self = .failed }
        else if held { self = .held }
        else if state == .offline { self = .offline }
        else if waiting { self = .waiting }
        else { self = .synced }
    }

    var symbol: String {
        switch self {
        case .synced: return "checkmark.icloud"
        case .waiting: return "icloud.and.arrow.up"
        case .offline: return "icloud.slash"
        case .held: return "pause.circle"
        case .failed: return "exclamationmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        }
    }

    var color: Color {
        switch self {
        case .synced, .waiting, .offline: return .secondary
        case .held: return .warn
        case .failed: return .loss
        case .syncing: return .jadeInk
        }
    }

    var title: String {
        switch self {
        case .synced: return LS("已同步")
        case .waiting: return LS("等待上传")
        case .offline: return LS("离线")
        case .held: return LS("暂存本机")
        case .failed: return LS("同步出错")
        case .syncing: return LS("同步中")
        }
    }
}

extension Store {
    var syncAppearance: SyncAppearance {
        SyncAppearance(state: syncState, waiting: !pending.isEmpty,
                       held: pending.contains { $0.held != nil }, failed: pending.contains { $0.failed != nil })
    }
}
