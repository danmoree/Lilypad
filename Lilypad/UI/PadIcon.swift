//
//  PadIcon.swift
//  Lilypad
//
//  The lily pad mark, in two forms: a SwiftUI `Shape` for the big button in the
//  menu, and an `NSImage` renderer for the status item itself.
//
//  The status item image is drawn rather than shipped as an asset so it can
//  carry live state — the pad fills from the bottom as the case cools, so a
//  glance at the menu bar tells you how far along you are.
//

import AppKit
import SwiftUI

/// Geometry for the lily pad mark, shared by both renderers so the menu bar
/// icon and the on-screen pad can't drift apart.
///
/// `notchHeading` follows the standard maths convention: degrees
/// counter-clockwise from the +x axis in a **y-up** space, which is what
/// `NSBezierPath` uses. SwiftUI's `Path` lives in a y-down space where positive
/// angles sweep clockwise on screen, so `PadShape` negates it. Without that
/// correction the two marks come out mirrored across the horizontal axis —
/// the notch points down-right in the menu bar and up-right in the panel.
nonisolated enum PadGeometry {
    /// Angular width of the notch.
    static let notchDegrees: Double = 42
    /// Direction the notch points. -35° puts it at the lower right.
    static let notchHeading: Double = -35

    /// Highest fill the pad shows while still working. A completely full pad is
    /// reserved for "target reached", so there is always a visible sliver left
    /// until the goal is actually met — at 16pt this leaves ~2.5px of gap.
    static let workingFillCeiling: Double = 0.85

    /// Converts a progress fraction into the fill *height* whose circular
    /// segment covers that fraction of the pad's **area**.
    ///
    /// Filling a disc bottom-up by height is perceptually misleading: at 86% of
    /// the height a circle is already ~93% covered, so a pad that is nearly but
    /// not quite done reads as completely full. Inverting by area keeps what
    /// you see in step with the actual number.
    ///
    /// Solves `covered(u) = 1 - (acos u - u·√(1-u²)) / π` for u, where u is the
    /// fill line's height relative to the centre, then maps u back to 0...1.
    static func fillHeight(forAreaFraction fraction: Double) -> Double {
        let target = fraction.clamped(to: 0...1)
        if target <= 0 { return 0 }
        if target >= 1 { return 1 }

        var low = -1.0
        var high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let covered = 1 - (acos(mid) - mid * (1 - mid * mid).squareRoot()) / .pi
            if covered < target { low = mid } else { high = mid }
        }
        return ((low + high) / 2 + 1) / 2
    }

    /// Fill height to draw for a session, honouring the "only full when done"
    /// rule.
    static func displayFillHeight(progress: Double, reachedTarget: Bool) -> Double {
        guard !reachedTarget else { return 1 }
        return min(fillHeight(forAreaFraction: progress), workingFillCeiling)
    }
}

/// A lily pad: a disc with a wedge cut out of one side.
struct PadShape: Shape {
    var notchDegrees: Double = PadGeometry.notchDegrees
    var notchHeading: Double = PadGeometry.notchHeading

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let half = notchDegrees / 2
        // Negated for SwiftUI's y-down coordinate space. See PadGeometry.
        let heading = -notchHeading

        var path = Path()
        path.move(to: centre)
        path.addArc(center: centre, radius: radius,
                    startAngle: .degrees(heading + half),
                    endAngle: .degrees(heading - half + 360),
                    clockwise: false)
        path.closeSubpath()
        return path
    }
}

nonisolated enum PadIcon {

    /// Builds the status item image.
    ///
    /// - Parameters:
    ///   - progress: 0...1 fill level, shown only while a session is running.
    ///   - active: whether a cooling session is under way.
    ///   - reachedTarget: true once the case is at or below target. Only then
    ///     does the pad fill completely.
    ///   - label: optional temperature text drawn to the right of the pad.
    @MainActor
    static func statusItemImage(progress: Double, active: Bool,
                                reachedTarget: Bool, label: String?) -> NSImage {
        let padSize: CGFloat = 16
        let spacing: CGFloat = 3
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        var textSize = CGSize.zero
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        if let label {
            textSize = (label as NSString).size(withAttributes: attributes)
        }

        let width = padSize + (label == nil ? 0 : spacing + ceil(textSize.width))
        let image = NSImage(size: CGSize(width: width, height: padSize))

        image.lockFocus()
        defer { image.unlockFocus() }

        let padRect = CGRect(x: 0, y: 0, width: padSize, height: padSize)
        // Inset so the stroke sits inside the bounds rather than being clipped.
        let padPath = bezierPad(in: padRect.insetBy(dx: 1.2, dy: 1.2))

        NSColor.black.setStroke()
        NSColor.black.setFill()
        padPath.lineWidth = 1.4

        if active {
            // Fill bottom-up to show how close the case is to the target.
            let fraction = PadGeometry.displayFillHeight(progress: progress,
                                                         reachedTarget: reachedTarget)
            NSGraphicsContext.saveGraphicsState()
            padPath.addClip()
            let fillHeight = padRect.height * CGFloat(fraction)
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: padSize, height: fillHeight)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        padPath.stroke()

        if let label {
            let origin = CGPoint(x: padSize + spacing,
                                 y: (padSize - textSize.height) / 2)
            (label as NSString).draw(at: origin, withAttributes: attributes)
        }

        // Template images inherit the menu bar's colour, so they stay correct in
        // light mode, dark mode, and when the menu bar is tinted by wallpaper.
        image.isTemplate = true
        return image
    }

    private static func bezierPad(in rect: CGRect) -> NSBezierPath {
        let radius = min(rect.width, rect.height) / 2
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // NSBezierPath is already y-up, so the heading is used as declared.
        let heading = CGFloat(PadGeometry.notchHeading)
        let half = CGFloat(PadGeometry.notchDegrees / 2)

        let path = NSBezierPath()
        path.move(to: centre)
        path.appendArc(withCenter: centre, radius: radius,
                       startAngle: heading + half,
                       endAngle: heading - half + 360,
                       clockwise: false)
        path.close()
        path.lineJoinStyle = .round
        return path
    }
}
