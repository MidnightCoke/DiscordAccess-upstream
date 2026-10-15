import Foundation

/// What the menu bar shows (Windows `TrayHost`): the status line and which actions can be chosen.
public struct MenuState: Equatable {
    public enum Phase: Equatable {
        case connecting
        case ready
        case failed
        case closed
        case closing
    }

    public var phase: Phase

    public init(_ phase: Phase) {
        self.phase = phase
    }

    public var status: String {
        switch phase {
        case .connecting: return "Bağlantı hazırlanıyor..."
        case .ready: return "Bağlantı hazır"
        case .failed: return "Bağlantı kurulamadı"
        case .closed: return "Bağlantı kapalı"
        case .closing: return "Kapatılıyor..."
        }
    }

    /// The status item's tooltip.
    public var tooltip: String {
        "DiscordAccess — " + status.lowercased(with: Locale(identifier: "tr_TR"))
    }

    public var canOpenDiscord: Bool { phase == .ready }
    public var canCheck: Bool { phase == .ready }
    public var canReconnect: Bool { phase == .failed || phase == .closed }
    public var canQuit: Bool { phase != .closing }
}
