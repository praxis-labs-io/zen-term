import Foundation

// One run of the emblem's motion: its signature breaking up into rain, then settling into a glyph.
final class HostEmblemMotion {
    struct Cell: Equatable {
        var level: Double
        var accentMix: Double
        var glyphMix: Double
    }

    private struct Drop {
        let start: TimeInterval
        let cell: Int
    }

    private struct Resolve {
        let glyph: [Bool]
        let start: TimeInterval
        let claims: [TimeInterval]
    }

    private typealias Timing = Motion.HostConnect

    static let cellCount = HostSignature.side * HostSignature.side
    private static let goldenAngle = 2.39996
    private static let spiralStep = 0.6
    private static let goldenRatioConjugate = 0.6180339887

    private let signature: [Bool]
    private var generator: SeededGenerator
    private let order: [Int]
    private let rank: [Int]
    private let letGo: [TimeInterval]
    private let fade: [TimeInterval]
    private let dropSeed: Double
    private var drops: [Drop] = []
    private var nextDropAt: TimeInterval = 0
    private var resolve: Resolve?

    init(signature: [Bool], seed: UInt64) {
        self.signature = signature
        var generator = SeededGenerator(seed: seed)
        order = Self.spiralOrder(rotation: Double.random(in: 0..<(2 * .pi), using: &generator))
        var rank = Array(repeating: 0, count: Self.cellCount)
        for (place, cell) in order.enumerated() { rank[cell] = place }
        self.rank = rank
        var letGo: [TimeInterval] = []
        var fade: [TimeInterval] = []
        for _ in 0..<Self.cellCount {
            letGo.append(TimeInterval.random(in: 0...Timing.letGoWindow, using: &generator))
            fade.append(TimeInterval.random(in: Timing.cellFade, using: &generator))
        }
        self.letGo = letGo
        self.fade = fade
        dropSeed = Double.random(in: 0..<1, using: &generator)
        self.generator = generator
    }

    var settledAt: TimeInterval? {
        guard let resolve else { return nil }
        return (0..<Self.cellCount).map { settleEnd(of: $0, in: resolve) }.max()
    }

    func resolve(to glyph: HostEmblemGlyph, at start: TimeInterval) {
        let outsideIn = order.reversed()
        var claims = Array(repeating: start, count: Self.cellCount)
        for (place, cell) in outsideIn.enumerated() {
            claims[cell] = start + Timing.claimSpan * Double(place) / Double(Self.cellCount - 1)
        }
        resolve = Resolve(glyph: glyph.cells, start: start, claims: claims)
    }

    func cell(_ index: Int, at time: TimeInterval) -> Cell {
        let mix = accentMix(of: index, at: time)
        guard let resolve, time >= resolve.claims[index] else {
            return Cell(level: rainLevel(of: index, at: time), accentMix: mix, glyphMix: 0)
        }
        let claim = resolve.claims[index]
        let from = rainLevel(of: index, at: claim)
        let target: Double = resolve.glyph[index] ? 1 : 0
        let span = settleSpan(from: from, to: target)
        let progress = span > 0 ? min(1, (time - claim) / span) : 1
        let glyphMix = min(1, (time - claim) / Timing.colorSettle)
        return Cell(level: from + (target - from) * progress, accentMix: mix, glyphMix: glyphMix)
    }

    private func settleSpan(from: Double, to target: Double) -> TimeInterval {
        target > from ? Timing.settleUp * (target - from) : Timing.settleDownLongest * (from - target)
    }

    private func settleEnd(of index: Int, in resolve: Resolve) -> TimeInterval {
        let claim = resolve.claims[index]
        let from = rainLevel(of: index, at: claim)
        let span = settleSpan(from: from, to: resolve.glyph[index] ? 1 : 0)
        return claim + max(span, Timing.colorSettle)
    }

    private func rainLevel(of index: Int, at time: TimeInterval) -> Double {
        var level = 0.0
        if signature[index] {
            level = time < letGo[index] ? 1 : max(0, 1 - (time - letGo[index]) / fade[index])
        }
        let lastStart = min(time, resolve?.start ?? time)
        dropsStarting(through: lastStart)
        let earliest = time - Timing.dropRise - fade[index]
        for drop in drops.reversed() {
            if drop.start < earliest { break }
            guard drop.cell == index, drop.start <= lastStart else { continue }
            level = max(level, dropLevel(startedAt: drop.start, fade: fade[index], at: time))
        }
        return level
    }

    private func dropLevel(startedAt start: TimeInterval, fade: TimeInterval, at time: TimeInterval) -> Double {
        let age = time - start
        if age < Timing.dropRise { return age / Timing.dropRise }
        return max(0, 1 - (age - Timing.dropRise) / fade)
    }

    private func dropsStarting(through time: TimeInterval) {
        while nextDropAt <= time {
            let k = Double(drops.count)
            let place = (dropSeed + k * Self.goldenRatioConjugate).truncatingRemainder(dividingBy: 1)
            drops.append(Drop(start: nextDropAt, cell: order[Int(place * Double(Self.cellCount))]))
            nextDropAt += TimeInterval.random(in: Timing.dropGap, using: &generator)
        }
    }

    private func accentMix(of index: Int, at time: TimeInterval) -> Double {
        let phase = (Double(rank[index]) * Self.goldenRatioConjugate).truncatingRemainder(dividingBy: 1)
        return 0.5 + 0.5 * sin(2 * .pi * (time / Timing.colorCycle + phase))
    }

    private static func spiralOrder(rotation: Double) -> [Int] {
        let side = HostSignature.side
        let center = Double(side - 1) / 2
        var order: [Int] = []
        var n = 0
        while order.count < cellCount, n < cellCount * 8 {
            let radius = spiralStep * Double(n).squareRoot()
            let angle = Double(n) * goldenAngle + rotation
            let column = Int((center + radius * cos(angle)).rounded())
            let row = Int((center + radius * sin(angle)).rounded())
            n += 1
            guard (0..<side).contains(column), (0..<side).contains(row) else { continue }
            let cell = row * side + column
            if !order.contains(cell) { order.append(cell) }
        }
        let rest = (0..<cellCount).filter { !order.contains($0) }.sorted { distance($0, center) < distance($1, center) }
        return order + rest
    }

    private static func distance(_ cell: Int, _ center: Double) -> Double {
        let row = Double(cell / HostSignature.side) - center
        let column = Double(cell % HostSignature.side) - center
        return (row * row + column * column).squareRoot()
    }

    var orderForTesting: [Int] { order }
}
