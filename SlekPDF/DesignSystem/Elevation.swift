import SwiftUI

/// One Figma drop shadow. `radius` is Figma's blur value.
struct DSShadow {
    let color: Color
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
}

extension View {
    /// Applies a Figma elevation. SwiftUI's shadow radius is roughly half of Figma's blur.
    func dsElevation(_ elevation: DSElevation) -> some View {
        elevation.shadows.reduce(AnyView(self)) { view, shadow in
            AnyView(view.shadow(color: shadow.color, radius: shadow.radius / 2, x: shadow.x, y: shadow.y))
        }
    }
}
