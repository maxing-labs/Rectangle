/// HalvesPreserveOtherAxisSize.swift

import Foundation

/// Makes Left Half, Right Half, Top Half and Bottom Half behave like keyboard tiling on Windows or
/// KDE: each action only changes the axis it belongs to (Left/Right → width, Top/Bottom → height)
/// and keeps the other axis as it is, so that Left Half followed by Top Half lands on the top left
/// quarter, Top Half followed by Left Half does the same, and Bottom Half then takes that window
/// back to Left Half.
///
/// Along its own axis an action docks the window to its edge when the window spans the whole axis,
/// expands the window to the whole axis when it is docked to the opposite edge, and cycles the window
/// through the cycle sizes along that axis when it is already docked to that edge inside a quarter
/// (if repeated commands resize; otherwise it leaves the window alone). One exception lets windows
/// tile in three columns (or rows): a window that is docked to the opposite edge at two thirds of the
/// axis shrinks to the middle third instead of expanding, so that Left Half, Left Half, Right Half
/// parks the window in the center column, and Right Half then docks it to the right edge as usual.
/// Windows that are not tiled at all, and plain halves that get the same action again, behave exactly
/// as without the feature (including cycling sizes or moving across displays on repeated executions).
///
/// Opt-in via the `halvesPreserveOtherAxisSize` default.
enum HalvesPreserveOtherAxisSize {

    /// Where a window sits along one axis of the screen.
    enum AxisState: Equatable {
        /// Spans the whole axis, or has an extent that no half action produces (floating windows).
        case full
        /// Docked to one edge. The rect carries the ungapped extent along that axis.
        case docked(HalfSplitSide, CGRect)
        /// The middle third of the axis. The rect carries the ungapped extent along that axis.
        case centered(CGRect)
    }

    enum Axis {
        case horizontal, vertical
    }

    /// Slack for windows that can't take an exact frame, e.g. terminals that resize in character cells.
    static let matchingTolerance: CGFloat = 10

    /// The rect a half action produces with the feature enabled, or nil when the action should behave
    /// exactly as it does without the feature: the window is not tiled, or it is a plain half that is
    /// docked to the action's edge already, in which case Rectangle's usual repeated execution applies.
    static func rect(for params: RectCalculationParameters) -> RectResult? {
        guard let (axis, side) = axisAndSide(of: params.action) else { return nil }

        let visibleFrame = params.visibleFrameOfScreen
        var horizontal = axisState(of: params.window.rect, along: .horizontal, in: visibleFrame)
        var vertical = axisState(of: params.window.rect, along: .vertical, in: visibleFrame)
        let own = axis == .horizontal ? horizontal : vertical
        let other = axis == .horizontal ? vertical : horizontal

        let newOwn: AxisState
        switch own {
        case .full:
            // Not tiled along this axis: dock to the edge, unless the window is not tiled at all
            // (then the plain half is exactly what the action does anyway).
            guard other != .full else { return nil }
            newOwn = .docked(side, dockedRect(along: axis, side: side, in: visibleFrame))
        case .docked(let dockedSide, let currentRect) where dockedSide == side:
            // Already docked to this edge: a plain half repeats as usual (cycle sizes, move across
            // displays); inside a quarter the window cycles sizes along this axis if repeated commands
            // resize, and stays as it is otherwise.
            guard other != .full else { return nil }
            if Defaults.subsequentExecutionMode.resizes, let next = nextCycleSize(after: currentRect, along: axis, side: side, in: visibleFrame) {
                newOwn = .docked(side, dockedRect(along: axis, side: side, fraction: next.fraction, in: visibleFrame))
            } else {
                newOwn = own
            }
        case .docked(let dockedSide, let currentRect):
            // Docked to the opposite edge: expand along this axis, except that a two thirds wide
            // window shrinks to the middle third so that windows can tile in three columns or rows.
            if matches(currentRect, dockedRect(along: axis, side: dockedSide, fraction: CycleSize.twoThirds.fraction, in: visibleFrame), along: axis) {
                newOwn = .centered(centeredThirdRect(along: axis, in: visibleFrame))
            } else {
                newOwn = .full
            }
        case .centered:
            // In the middle third: dock to the edge, like a window that spans the whole axis.
            newOwn = .docked(side, dockedRect(along: axis, side: side, in: visibleFrame))
        }

        if axis == .horizontal {
            horizontal = newOwn
        } else {
            vertical = newOwn
        }
        return compose(horizontal: horizontal, vertical: vertical, in: visibleFrame)
    }

    /// The state of `window` along `axis`: docked if its position and extent match (within tolerance)
    /// an edge-docked rect that Rectangle's half actions produce, at the active split ratio or any cycle
    /// size, with or without gaps applied; centered if they match the middle third of the axis.
    static func axisState(of window: CGRect, along axis: Axis, in visibleFrame: CGRect) -> AxisState {
        guard !window.isNull, !visibleFrame.isNull, visibleFrame.width > 0, visibleFrame.height > 0 else {
            return .full
        }

        let ratio = splitRatio(along: axis, in: visibleFrame)
        let gapSize = Defaults.gapSize.value

        for side in [HalfSplitSide.leading, .trailing] {
            let fractions = [side == .leading ? ratio : 1 - ratio] + CycleSize.allCases.map { $0.fraction }

            for fraction in fractions {
                let docked = dockedRect(along: axis, side: side, fraction: fraction, in: visibleFrame)
                guard extent(of: docked, along: axis) < extent(of: visibleFrame, along: axis) - matchingTolerance else {
                    continue
                }

                var candidates = [docked]
                if gapSize > 0 {
                    candidates.append(GapCalculation.applyGaps(docked,
                                                               dimension: axis == .horizontal ? .horizontal : .vertical,
                                                               sharedEdges: sharedEdge(along: axis, side: side),
                                                               gapSize: gapSize,
                                                               skipTopGap: Defaults.skipGapTopEdge.enabled))
                }

                if candidates.contains(where: { matches(window, $0, along: axis) }) {
                    return .docked(side, docked)
                }
            }
        }

        let centered = centeredThirdRect(along: axis, in: visibleFrame)
        var centeredCandidates = [centered]
        if gapSize > 0 {
            centeredCandidates.append(GapCalculation.applyGaps(centered,
                                                               dimension: axis == .horizontal ? .horizontal : .vertical,
                                                               sharedEdges: axis == .horizontal ? [.left, .right] : [.top, .bottom],
                                                               gapSize: gapSize,
                                                               skipTopGap: Defaults.skipGapTopEdge.enabled))
        }
        if centeredCandidates.contains(where: { matches(window, $0, along: axis) }) {
            return .centered(centered)
        }

        return .full
    }

    /// The cycle size that follows `currentRect` in the cycling order: the one after the size the rect
    /// has, or the first one when the rect has a size that is not selected for cycling (e.g. a custom
    /// split ratio). Nil when no cycle sizes are selected.
    private static func nextCycleSize(after currentRect: CGRect, along axis: Axis, side: HalfSplitSide, in visibleFrame: CGRect) -> CycleSize? {
        let sizes = CycleSize.sortedSelectedSizes()
        guard !sizes.isEmpty else { return nil }

        let currentIndex = sizes.firstIndex { size in
            matches(currentRect, dockedRect(along: axis, side: side, fraction: size.fraction, in: visibleFrame), along: axis)
        }
        guard let currentIndex else { return sizes[0] }
        return sizes[(currentIndex + 1) % sizes.count]
    }

    private static func compose(horizontal: AxisState, vertical: AxisState, in visibleFrame: CGRect) -> RectResult {
        var rect = visibleFrame
        if let column = horizontal.rect {
            rect.origin.x = column.minX
            rect.size.width = column.width
        }
        if let row = vertical.rect {
            rect.origin.y = row.minY
            rect.size.height = row.height
        }

        // Report the action that produces this rect so gaps and history match it.
        switch (horizontal, vertical) {
        case (.full, .full):
            return RectResult(rect, resultingAction: .maximize)
        case (.docked(.leading, _), .full):
            return RectResult(rect, resultingAction: .leftHalf)
        case (.docked(.trailing, _), .full):
            return RectResult(rect, resultingAction: .rightHalf)
        case (.centered, .full):
            return RectResult(rect, resultingAction: .centerThird, subAction: .centerVerticalThird)
        case (.full, .docked(.leading, _)):
            return RectResult(rect, resultingAction: .topHalf)
        case (.full, .docked(.trailing, _)):
            return RectResult(rect, resultingAction: .bottomHalf)
        case (.full, .centered):
            return RectResult(rect, resultingAction: .middleVerticalThird, subAction: .centerHorizontalThird)
        case (.docked(.leading, _), .docked(.leading, _)):
            return RectResult(rect, resultingAction: .topLeft, subAction: .topLeftQuarter)
        case (.docked(.trailing, _), .docked(.leading, _)):
            return RectResult(rect, resultingAction: .topRight, subAction: .topRightQuarter)
        case (.docked(.leading, _), .docked(.trailing, _)):
            return RectResult(rect, resultingAction: .bottomLeft, subAction: .bottomLeftQuarter)
        case (.docked(.trailing, _), .docked(.trailing, _)):
            return RectResult(rect, resultingAction: .bottomRight, subAction: .bottomRightQuarter)
        // Center column or middle row combined with a half: borrow the sixths and ninths that share
        // the same edges, so gaps come out right.
        case (.centered, .docked(.leading, _)):
            return RectResult(rect, resultingAction: .topCenterSixth, subAction: .topCenterSixthLandscape)
        case (.centered, .docked(.trailing, _)):
            return RectResult(rect, resultingAction: .bottomCenterSixth, subAction: .bottomCenterSixthLandscape)
        case (.docked(.leading, _), .centered):
            return RectResult(rect, resultingAction: .middleLeftNinth, subAction: .middleLeftNinth)
        case (.docked(.trailing, _), .centered):
            return RectResult(rect, resultingAction: .middleRightNinth, subAction: .middleRightNinth)
        case (.centered, .centered):
            return RectResult(rect, resultingAction: .middleCenterNinth, subAction: .middleCenterNinth)
        }
    }

    private static func axisAndSide(of action: WindowAction) -> (Axis, HalfSplitSide)? {
        switch action {
        case .leftHalf: return (.horizontal, .leading)
        case .rightHalf: return (.horizontal, .trailing)
        case .topHalf: return (.vertical, .leading)
        case .bottomHalf: return (.vertical, .trailing)
        default: return nil
        }
    }

    private static func splitRatio(along axis: Axis, in visibleFrame: CGRect) -> Float {
        axis == .horizontal
            ? ActiveSideSplitRatios.shared.horizontalRatio(for: visibleFrame)
            : ActiveSideSplitRatios.shared.verticalRatio(for: visibleFrame)
    }

    private static func dockedRect(along axis: Axis, side: HalfSplitSide, in visibleFrame: CGRect) -> CGRect {
        let ratio = splitRatio(along: axis, in: visibleFrame)
        return dockedRect(along: axis, side: side, fraction: side == .leading ? ratio : 1 - ratio, in: visibleFrame)
    }

    private static func dockedRect(along axis: Axis, side: HalfSplitSide, fraction: Float, in visibleFrame: CGRect) -> CGRect {
        axis == .horizontal
            ? HalfSplitFrameCalculation.horizontalRect(in: visibleFrame, side: side, fraction: fraction)
            : HalfSplitFrameCalculation.verticalRect(in: visibleFrame, side: side, fraction: fraction)
    }

    /// The middle third of `visibleFrame` along `axis`, spanning the other axis (as Center Third and
    /// Middle Vertical Third produce it).
    private static func centeredThirdRect(along axis: Axis, in visibleFrame: CGRect) -> CGRect {
        var rect = visibleFrame
        switch axis {
        case .horizontal:
            rect.origin.x = visibleFrame.minX + floor(visibleFrame.width / 3.0)
            rect.size.width = visibleFrame.width / 3.0
        case .vertical:
            rect.origin.y = visibleFrame.minY + floor(visibleFrame.height / 3.0)
            rect.size.height = visibleFrame.height / 3.0
        }
        return rect
    }

    private static func sharedEdge(along axis: Axis, side: HalfSplitSide) -> Edge {
        switch (axis, side) {
        case (.horizontal, .leading): return .right
        case (.horizontal, .trailing): return .left
        case (.vertical, .leading): return .bottom
        case (.vertical, .trailing): return .top
        }
    }

    private static func extent(of rect: CGRect, along axis: Axis) -> CGFloat {
        axis == .horizontal ? rect.width : rect.height
    }

    private static func matches(_ window: CGRect, _ candidate: CGRect, along axis: Axis) -> Bool {
        switch axis {
        case .horizontal:
            return abs(window.minX - candidate.minX) <= matchingTolerance
                && abs(window.width - candidate.width) <= matchingTolerance
        case .vertical:
            return abs(window.minY - candidate.minY) <= matchingTolerance
                && abs(window.height - candidate.height) <= matchingTolerance
        }
    }
}

private extension HalvesPreserveOtherAxisSize.AxisState {
    /// The ungapped rect along the axis, or nil when the window spans the whole axis.
    var rect: CGRect? {
        switch self {
        case .full: return nil
        case .docked(_, let rect), .centered(let rect): return rect
        }
    }
}
