import Foundation

/// Keep the entire top edge beneath the menu bar, including after content grows.
enum PopoverPlacement {
    static func origin(for frame: CGRect, inside available: CGRect) -> CGPoint {
        CGPoint(x: min(max(frame.minX, available.minX), available.maxX - frame.width),
                y: min(max(frame.minY, available.minY), available.maxY - frame.height))
    }
}
