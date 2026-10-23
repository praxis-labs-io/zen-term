import XCTest

@testable import ZenTerm

final class GalleryButtonsTests: XCTestCase {
    func test_theGalleryShowsEveryAppButtonVariant() {
        let shown = GalleryButtons.variants
        let every: [AppButton.Variant] = [.primary, .secondary, .muted, .destructive, .segment, .link]
        for variant in every {
            switch variant {
            case .primary, .secondary, .muted, .destructive, .segment, .link:
                XCTAssertTrue(
                    shown.contains(variant),
                    "\(GalleryButtons.title(for: variant)) has no row in the gallery, so its states go unseen")
            }
        }
        XCTAssertEqual(Set(shown).count, shown.count, "a variant is listed in the gallery twice")
    }
}
