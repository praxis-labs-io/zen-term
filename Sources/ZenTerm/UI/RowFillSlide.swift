import AppKit

// Carries the fill marking a list's current, focused or highlighted row from the row that loses it to the one that gains it.
final class RowFillSlide {
    enum Mark: CaseIterable {
        case current
        case focus
        case highlight
    }

    private final class Track {
        let layer = CALayer()
        weak var marked: ListRow?
        weak var arriving: ListRow?
        // A slide begun this turn has not reached the presentation layer, so a retarget starts from here.
        var uncommittedStart: Motion.FillStop?
        // Focus resigns before the next row takes it, and a render may clear a row before marking the next.
        var departedThisTurn: Motion.FillStop?
        weak var departedRow: ListRow?
        var generation = 0
    }

    private weak var host: NSView?
    private let rows = NSHashTable<ListRow>.weakObjects()
    private let tracks: [Mark: Track]
    private var placesInPlace = false

    init(host: NSView) {
        self.host = host
        host.wantsLayer = true
        var tracks: [Mark: Track] = [:]
        for mark in Mark.allCases {
            let track = Track()
            track.layer.cornerRadius = ChromeMetrics.Radius.control
            track.layer.zPosition = -1
            track.layer.isHidden = true
            host.layer?.insertSublayer(track.layer, at: 0)
            tracks[mark] = track
        }
        self.tracks = tracks
    }

    func adopt(_ row: ListRow) {
        rows.add(row)
        row.fillSlide = self
        rowMarkDidChange()
    }

    // A row a fill is still sliding to paints everything but that fill.
    func marks(_ row: ListRow, with mark: Mark) -> Bool {
        guard let track = tracks[mark] else { return false }
        return track.marked === row && track.arriving !== row
    }

    func placeInPlace(_ change: () -> Void) {
        placesInPlace = true
        change()
        placesInPlace = false
        for track in tracks.values {
            track.departedThisTurn = nil
            track.departedRow = nil
            if track.arriving != nil { land(track) }
        }
    }

    func rowMarkDidChange() {
        for mark in Mark.allCases { resolve(mark) }
    }

    func isSlidingForTesting(_ mark: Mark) -> Bool {
        tracks[mark]?.layer.animation(forKey: "slideFill.position") != nil
    }

    func slidingRowForTesting(_ mark: Mark) -> ListRow? { tracks[mark]?.arriving }

    func slideFrameForTesting(_ mark: Mark) -> CGRect { tracks[mark]?.layer.frame ?? .zero }

    func slideColorForTesting(_ mark: Mark) -> CGColor? { tracks[mark]?.layer.backgroundColor }

    func frameForTesting(of row: ListRow) -> CGRect { frame(of: row) ?? .zero }

    private static func carries(_ mark: Mark, _ row: ListRow) -> Bool {
        switch mark {
        case .current: return row.isCurrent
        case .focus: return row.hasKeyboardFocus
        case .highlight: return row.isHighlighted
        }
    }

    // A render can mark the next row before clearing the last, so the newcomer wins; marks bound for one row share a slide.
    private func resolve(_ mark: Mark) {
        guard let track = tracks[mark] else { return }
        let previous = track.marked
        let carriers = rows.allObjects.filter { $0.window != nil && Self.carries(mark, $0) }
        let next = carriers.first { $0 !== previous } ?? carriers.first
        guard next !== previous else { return }
        track.marked = next

        let held = track.arriving
        let start = placesInPlace ? nil : slideStart(of: track, from: previous, to: next)
        track.generation += 1
        let generation = track.generation
        guard let next, let start, let target = frame(of: next) else {
            settle(track)
            for row in [held, previous, next] { row?.refreshFill() }
            if next == nil, !placesInPlace { depart(track, row: previous, from: start, generation: generation) }
            return
        }
        for other in tracks.values where other !== track && other.arriving === next && other.uncommittedStart != nil {
            settle(other)
        }
        let targetColor = next.restingFill.cgColor
        let departed = track.departedRow
        track.arriving = next
        track.departedThisTurn = nil
        track.departedRow = nil
        setHidden(track.layer, false)
        let slides = Motion.slideFill(
            track.layer, from: start, to: Motion.FillStop(frame: target, color: targetColor)
        ) { [weak self, weak track] in
            guard let self, let track, track.generation == generation else { return }
            self.land(track)
        }
        guard slides else {
            settle(track)
            for row in [held, previous, departed, next] { row?.refreshFill() }
            return
        }
        track.uncommittedStart = start
        DispatchQueue.main.async { [weak track] in
            guard let track, track.generation == generation else { return }
            track.uncommittedStart = nil
        }
        previous?.passFillToSlide()
        departed?.passFillToSlide()
        held?.refreshFill()
        next.refreshFill()
    }

    private func depart(_ track: Track, row: ListRow?, from stop: Motion.FillStop?, generation: Int) {
        track.departedThisTurn = stop
        track.departedRow = row
        DispatchQueue.main.async { [weak track] in
            guard let track, track.generation == generation else { return }
            track.departedThisTurn = nil
            track.departedRow = nil
        }
    }

    private func slideStart(of track: Track, from previous: ListRow?, to next: ListRow?) -> Motion.FillStop? {
        if track.arriving != nil { return inFlightStop(of: track) }
        if let painted = previous.flatMap(paintedStop(of:)) { return painted }
        return track.departedRow === next ? nil : track.departedThisTurn
    }

    private func land(_ track: Track) {
        let landed = track.arriving
        let carried = track.layer.backgroundColor
        settle(track)
        guard let landed else { return }
        if let carried { landed.takeFill(fromSlide: carried) } else { landed.refreshFill() }
    }

    private func settle(_ track: Track) {
        track.arriving = nil
        track.uncommittedStart = nil
        track.layer.removeAllAnimations()
        setHidden(track.layer, true)
    }

    private func setHidden(_ layer: CALayer, _ hidden: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = hidden
        CATransaction.commit()
    }

    private func inFlightStop(of track: Track) -> Motion.FillStop? {
        if let start = track.uncommittedStart { return start }
        let shown = track.layer.presentation() ?? track.layer
        return Motion.FillStop(frame: shown.frame, color: shown.backgroundColor ?? NSColor.clear.cgColor)
    }

    private func paintedStop(of row: ListRow) -> Motion.FillStop? {
        guard let frame = frame(of: row), let color = row.layer?.backgroundColor, color.alpha > 0 else { return nil }
        return Motion.FillStop(frame: frame, color: color)
    }

    private func frame(of row: ListRow) -> CGRect? {
        guard let host, host.window != nil, row.window === host.window, let hostLayer = host.layer,
            let rowLayer = row.layer, !row.bounds.isEmpty
        else { return nil }
        return hostLayer.convert(rowLayer.bounds, from: rowLayer)
    }
}
