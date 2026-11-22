// Only a fall counts as an exit: a surface polled before its program starts has not been busy yet.
struct BusyFallWatch {
    private var busy: Set<SurfaceID> = []

    mutating func fell(_ id: SurfaceID, isBusy: Bool) -> Bool {
        guard !isBusy else {
            busy.insert(id)
            return false
        }
        return busy.remove(id) != nil
    }

    mutating func forget(_ id: SurfaceID) { busy.remove(id) }
}
