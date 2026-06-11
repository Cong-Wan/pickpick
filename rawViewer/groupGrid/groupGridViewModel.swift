/*
Author: wilbur
Version: 1.2
Date: 2026-06-11
Description: 分组网格视图模型，负责空组过滤、路由决策、预览取前 5 张以及响应式列数计算；columnCount 扣除滚动条宽度
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

    public func previewPhotos(for group: photoGroup) -> [photoItem] {
        Array(group.photos.prefix(5))
    }

    public func route(for group: photoGroup) -> groupRoute {
        group.kind.isDuplicate ? .duplicateCompare : .browser
    }

    public func update(groups newGroups: [photoGroup]) {
        groups = visibleGroupCards(from: newGroups)
    }
}
