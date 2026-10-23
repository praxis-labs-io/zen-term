import AppKit

enum ChromeType {
    enum Role: CaseIterable {
        case display, title, body, small, caption

        var pointSize: CGFloat {
            switch self {
            case .display: 22
            case .title: 15
            case .body: 13
            case .small: 12
            case .caption: 11
            }
        }

        var weight: Weight {
            switch self {
            case .display, .title: .semibold
            case .body, .small, .caption: .regular
            }
        }
    }

    enum Weight {
        case regular, medium, semibold

        var nsWeight: NSFont.Weight {
            switch self {
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            }
        }
    }

    enum Face {
        case text, mono, digits
    }

    static let sectionLabel = font(.small, weight: .medium)

    static func font(_ role: Role, weight: Weight? = nil, face: Face = .text) -> NSFont {
        let size = role.pointSize
        let weight = (weight ?? role.weight).nsWeight
        switch face {
        case .text: return .systemFont(ofSize: size, weight: weight)
        case .mono: return .monospacedSystemFont(ofSize: size, weight: weight)
        case .digits: return .monospacedDigitSystemFont(ofSize: size, weight: weight)
        }
    }
}
