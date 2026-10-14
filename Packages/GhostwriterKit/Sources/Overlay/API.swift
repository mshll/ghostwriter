import CoreGraphics
import GWCore

public struct PickerItem: Sendable, Hashable {
    public var title: String
    public var detail: String?

    public init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

public struct OverlayAppearance: Sendable, Hashable {
    public var opacity: Double = 0.45
    public var useFieldColor: Bool = true

    public init() {}
}
