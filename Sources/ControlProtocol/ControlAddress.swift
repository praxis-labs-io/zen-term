/// The text forms of window and tab addresses. Ids are minted per window, so a tab address carries both.
public enum ControlAddress {
    public static func window(_ window: Int) -> String { "w\(window)" }

    public static func tab(window: Int, tab: Int) -> String { "w\(window).t\(tab)" }
}
