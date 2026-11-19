// SPDX-License-Identifier: Apache-2.0
// The desert study's one shape for the app: the niche, a round arch over a straight wall. It is used for the
// app's mark and for the one panel that holds the promise. Never on covers, the way-out line, buttons or fields.
import CoreGraphics

enum Niche {
    /// A niche in `r`. `arch` is how far the arch rises above the walls (half the width gives a full half-circle;
    /// less gives a gentler, elliptical arch); `corner` rounds the two lower corners. `topAtMinY` is true in a
    /// flipped (y down) view.
    static func path(_ r: CGRect, arch: CGFloat, corner: CGFloat, topAtMinY: Bool) -> CGPath {
        let a = min(arch, r.height - corner), k: CGFloat = 0.5523   // cubic approximation of a quarter ellipse
        let top = topAtMinY ? r.minY : r.maxY, bottom = topAtMinY ? r.maxY : r.minY
        let down: CGFloat = topAtMinY ? 1 : -1, shoulder = top + down * a
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.midX, y: bottom))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: bottom), tangent2End: CGPoint(x: r.minX, y: top), radius: corner)
        p.addLine(to: CGPoint(x: r.minX, y: shoulder))
        p.addCurve(to: CGPoint(x: r.midX, y: top), control1: CGPoint(x: r.minX, y: shoulder - down * k * a),
                   control2: CGPoint(x: r.midX - k * r.width / 2, y: top))
        p.addCurve(to: CGPoint(x: r.maxX, y: shoulder), control1: CGPoint(x: r.midX + k * r.width / 2, y: top),
                   control2: CGPoint(x: r.maxX, y: shoulder - down * k * a))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: bottom), tangent2End: CGPoint(x: r.midX, y: bottom), radius: corner)
        p.closeSubpath()
        return p
    }
}
