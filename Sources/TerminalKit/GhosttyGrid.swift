import GhosttyKit

// Reads go through the owning surface's pointer, so every one fails closed once it is freed.
final class GhosttyGrid: TerminalGrid {
    private final class Handle {
        var pointer: ghostty_mark_t?
        init(_ pointer: ghostty_mark_t) { self.pointer = pointer }
    }

    private weak var surface: GhosttySurface?
    private var handles: [ObjectIdentifier: Handle] = [:]

    init(surface: GhosttySurface) {
        self.surface = surface
    }

    private var surfacePtr: ghostty_surface_t? { surface?.surfacePtr }

    private var state: ghostty_grid_s? {
        guard let surfacePtr else { return nil }
        var grid = ghostty_grid_s()
        return ghostty_surface_grid(surfacePtr, &grid) ? grid : nil
    }

    var rowCount: Int { state.map { Int($0.total_rows) } ?? 0 }

    var viewportTop: Int { state.map { Int($0.viewport_top) } ?? 0 }

    var cursorPoint: TerminalGridPoint? { state.map { Self.point($0.cursor) } }

    var selectionBounds: ClosedRange<TerminalGridPoint>? {
        guard let state, state.has_selection else { return nil }
        return Self.point(state.selection.top_left)...Self.point(state.selection.bottom_right)
    }

    func row(_ index: Int) -> TerminalGridRow? {
        guard let surfacePtr, let y = UInt32(exactly: index) else { return nil }
        var row = ghostty_row_s()
        guard ghostty_surface_read_row(surfacePtr, y, &row) else { return nil }
        defer { ghostty_surface_free_row(surfacePtr, &row) }
        let text = row.text.map {
            UnsafeBufferPointer(
                start: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), count: Int(row.text_len))
        }
        let cells = UnsafeBufferPointer(start: row.cells, count: Int(row.cells_len)).map { cell in
            let bytes = text.map { Array($0[Int(cell.text_offset)..<Int(cell.text_offset + cell.text_len)]) } ?? []
            return TerminalGridCell(
                text: String(decoding: bytes, as: UTF8.self), width: Int(cell.width), kind: Self.kind(cell.content))
        }
        return TerminalGridRow(
            cells: cells, wraps: row.wrap, continues: row.wrap_continuation, prompt: Self.prompt(row.prompt))
    }

    func text(from start: TerminalGridPoint, to end: TerminalGridPoint) -> String? {
        guard let surfacePtr, let first = Self.screenPoint(min(start, end)),
            let last = Self.screenPoint(max(start, end))
        else { return nil }
        var text = ghostty_text_s()
        let range = ghostty_selection_s(top_left: first, bottom_right: last, rectangle: false)
        guard ghostty_surface_read_text(surfacePtr, range, &text) else { return nil }
        defer { ghostty_surface_free_text(surfacePtr, &text) }
        return text.text.map { String(cString: $0) }
    }

    func mark(_ point: TerminalGridPoint) -> TerminalGridMark? {
        guard let surfacePtr, let at = Self.screenPoint(point),
            let pointer = ghostty_surface_mark_new(surfacePtr, at)
        else { return nil }
        let handle = Handle(pointer)
        let key = ObjectIdentifier(handle)
        handles[key] = handle
        return TerminalGridMark(
            read: { [weak self] in self?.place(of: handle) ?? .gone },
            release: { [weak self] in
                self?.free(handle)
                self?.handles[key] = nil
            })
    }

    func setSelection(_ range: ClosedRange<TerminalGridPoint>?) {
        guard let surfacePtr else { return }
        guard let range else {
            ghostty_surface_clear_selection(surfacePtr)
            return
        }
        guard let first = Self.screenPoint(range.lowerBound), let last = Self.screenPoint(range.upperBound) else {
            return
        }
        _ = ghostty_surface_set_selection(
            surfacePtr, ghostty_selection_s(top_left: first, bottom_right: last, rectangle: false))
    }

    // Takes the pointer because it runs in the surface's deinit too, where the weak surface already reads nil.
    func releaseMarks(_ surfacePtr: ghostty_surface_t) {
        for handle in handles.values {
            guard let pointer = handle.pointer else { continue }
            handle.pointer = nil
            ghostty_surface_mark_free(surfacePtr, pointer)
        }
        handles = [:]
    }

    private func place(of handle: Handle) -> TerminalGridMark.Place {
        guard let surfacePtr, let pointer = handle.pointer else { return .gone }
        var point = ghostty_point_s()
        switch ghostty_surface_mark_read(surfacePtr, pointer, &point) {
        case GHOSTTY_MARK_LIVE: return .at(Self.point(point))
        case GHOSTTY_MARK_ASIDE: return .aside
        default: return .gone
        }
    }

    private func free(_ handle: Handle) {
        guard let pointer = handle.pointer else { return }
        handle.pointer = nil
        guard let surfacePtr else { return }
        ghostty_surface_mark_free(surfacePtr, pointer)
    }

    private static func point(_ point: ghostty_point_s) -> TerminalGridPoint {
        TerminalGridPoint(row: Int(point.y), column: Int(point.x))
    }

    private static func screenPoint(_ point: TerminalGridPoint) -> ghostty_point_s? {
        guard let x = UInt32(exactly: point.column), let y = UInt32(exactly: point.row) else { return nil }
        return ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_EXACT, x: x, y: y)
    }

    private static func kind(_ content: ghostty_cell_content_e) -> TerminalGridCell.Kind {
        switch content {
        case GHOSTTY_CELL_INPUT: .input
        case GHOSTTY_CELL_PROMPT: .prompt
        default: .output
        }
    }

    private static func prompt(_ prompt: ghostty_row_prompt_e) -> TerminalGridRow.Prompt {
        switch prompt {
        case GHOSTTY_ROW_PROMPT: .start
        case GHOSTTY_ROW_PROMPT_CONTINUATION: .continuation
        default: .none
        }
    }
}
