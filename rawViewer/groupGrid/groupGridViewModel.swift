/*
Author: wilbur
Version: 1.3
Date: 2026-06-25
Description: 分组网格视图模型负责空组过滤与响应式列数计算，删除无调用方的路由和预览辅助方法
*/

import AppKit

public final class groupGridViewModel {
    public private(set) var groups: [photoGroup]
    public let minimumCardWidth: CGFloat
    public let maximumCardWidth: CGFloat
    public let columnSpacing: CGFloat
    public let horizontalPadding: CGFloat

    public init(
        groups: [photoGroup],
        minimumCardWidth: CGFloat = 200,
        maximumCardWidth: CGFloat = 320,
        columnSpacing: CGFloat = 16,
        horizontalPadding: CGFloat = 32
    ) {
        self.groups = visibleGroupCards(from: groups)
        self.minimumCardWidth = minimumCardWidth
        self.maximumCardWidth = maximumCardWidth
        self.columnSpacing = columnSpacing
        self.horizontalPadding = horizontalPadding
    }

    public convenience init(records: [photoItem]) {
        self.init(groups: makeVisiblePhotoGroups(from: records))
    }

    public func columnCount(for availableWidth: CGFloat) -> Int {
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        let contentWidth = max(0, availableWidth - horizontalPadding - scrollerWidth)
        let candidateWidth = minimumCardWidth + columnSpacing
        if contentWidth <= minimumCardWidth {
            return 1
        }
        let rawCount = Int((contentWidth + columnSpacing) / candidateWidth)
        return max(1, rawCount)
    }

    public func cardWidth(for availableWidth: CGFloat) -> CGFloat {
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        let contentWidth = max(0, availableWidth - horizontalPadding - scrollerWidth)
        let columns = columnCount(for: availableWidth)
        guard columns > 0 else { return minimumCardWidth }
        return (contentWidth - CGFloat(columns - 1) * columnSpacing) / CGFloat(columns)
    }


    public func update(groups newGroups: [photoGroup]) {
        groups = visibleGroupCards(from: newGroups)
    }
}
