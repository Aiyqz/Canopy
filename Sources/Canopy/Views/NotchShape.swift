// NotchShape.swift —— 贴合硬件刘海形状的黑色面板路径。
import SwiftUI

/// A black slab that extends the hardware notch: subtle rounding on top where it
/// meets the screen edge, generous rounding on the bottom where it hangs down.
struct NotchShape: Shape {
    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 20

    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: topRadius,
                bottomLeading: bottomRadius,
                bottomTrailing: bottomRadius,
                topTrailing: topRadius
            ),
            style: .continuous
        )
        .path(in: rect)
    }
}
