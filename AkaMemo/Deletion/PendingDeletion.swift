import SwiftUI

enum PendingDeletion: Identifiable, Equatable {
    case session(UUID)
    case chunk(UUID, sessionID: UUID)
    case all

    var id: String {
        switch self {
        case .session(let id):
            "session-\(id.uuidString)"
        case .chunk(let id, _):
            "chunk-\(id.uuidString)"
        case .all:
            "all"
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .session:
            "deletion.title.session"
        case .chunk:
            "deletion.title.chunk"
        case .all:
            "deletion.title.all"
        }
    }

    var messageKey: LocalizedStringKey {
        switch self {
        case .session:
            "deletion.message.session"
        case .chunk:
            "deletion.message.chunk"
        case .all:
            "deletion.message.all"
        }
    }
}
