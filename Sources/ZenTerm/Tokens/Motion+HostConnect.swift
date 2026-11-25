import Foundation

extension Motion {
    // The SSH host Connect screen's choreography, from Connect through the emblem's answer to the terminal.
    enum HostConnect {
        static let minimumRain: TimeInterval = 0.7
        static let letGoWindow: TimeInterval = 0.85
        static let dropGap: ClosedRange<TimeInterval> = 0.055...0.195
        static let dropRise: TimeInterval = 0.2
        static let cellFade: ClosedRange<TimeInterval> = 0.65...1.45
        static let colorCycle: TimeInterval = 1.35
        static let claimSpan: TimeInterval = 0.65
        static let settleUp: TimeInterval = 0.2
        static let settleDownLongest: TimeInterval = 0.9
        static let colorSettle: TimeInterval = 0.32
        static let answerDelay: TimeInterval = 0.72
        static let statusEntrance: TimeInterval = 0.32
        static let actionDelay: TimeInterval = 0.08
        static let settledToHandOff: TimeInterval = 0.55
        static let handOffFadeOut: TimeInterval = 0.35
        static let handOffScale: CGFloat = 0.985
        static let terminalFadeIn: TimeInterval = 0.45
        static let terminalDelay: TimeInterval = 0.18
        static let reducedCrossfade: TimeInterval = 0.2
        static let reducedTerminalFade: TimeInterval = 0.15
    }
}
