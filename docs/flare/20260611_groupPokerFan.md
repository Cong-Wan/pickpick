# 分组缩略图扑克牌散开展示 实现计划

> **面向智能体工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 来逐任务实现此计划。步骤使用复选框（`- [ ]`）语法进行追踪。

**目标：** 将分组卡片缩略图从最多 3 张简单叠放改为最多 5 张宽扇形扑克牌散开展示。

**架构：** 保持现有分组网格、卡片点击、异步缩略图加载和复用清理逻辑不变。只在 `groupCardView` 内替换预览图布局算法，并在入口处把预览数量统一调整为 5 张。现有 `appDebugLogger` 已提供 `--debug` 控制的日志基础设施，本次 UI 改动不新增打印输出。

**技术栈：** Swift、AppKit、NSCollectionView、NSImageView、Auto Layout、CALayer transform。

---

## 文件结构

- `rawViewer/services/appDebugLogger.swift` — 已存在的 `--debug` 日志基础设施；本计划不新增日志，只验证该基础设施保持可用。
- `rawViewer/views/groupCardView.swift` — 分组卡片视图；负责渲染标题、数量、最多 5 张缩略图，以及扑克牌宽扇形布局。
- `rawViewer/views/groupCollectionViewItem.swift` — CollectionView item 容器；负责从分组中取前 5 张照片并创建 `groupCardView`。
- `rawViewer/groupGrid/groupGridViewModel.swift` — 分组网格 ViewModel；同步将 `previewPhotos(for:)` 从 3 张改为 5 张，避免未来调用路径不一致。

## 调试输出策略

用户选择不需要详细打印。本计划不新增任何打印输出。如果后续执行中确需临时诊断，只能通过已有 `appDebugLogger.log("message")` 输出，且该工具已由 `CommandLine.arguments.contains("--debug")` 控制。不允许新增不受 `--debug` 控制的 `print`、`NSLog` 或其它日志输出。

---

### Task 1: 确认 `--debug` 日志基础设施保持可用

**目标：** 项目中存在受 `--debug` 参数控制的日志基础设施，且本任务完成后项目可以编译。

**涉及的文件：**

- `rawViewer/services/appDebugLogger.swift` — 受 `--debug` 控制的轻量日志工具。

------

#### Step 1 — 实现

保持 `rawViewer/services/appDebugLogger.swift` 为以下内容。如果文件已经完全一致，不需要产生代码差异。

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-11
Description: 提供受 --debug 参数控制的轻量日志工具，用于关键路径调试输出
*/

import Foundation

public enum appDebugLogger {
    public static var isEnabled: Bool {
        CommandLine.arguments.contains("--debug")
    }

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[pickpick debug] %@", message())
    }
}
```

------

#### Step 2 — 运行验证

运行构建，确认项目仍然可以编译。

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
# 预期：输出包含 ** BUILD SUCCEEDED **；无 Swift 编译错误；无运行时步骤。
```

如果验证不通过，修复实现并重复运行命令，直到构建通过。

------

✅ **完成的标志：** 第二步验证通过 —— 构建通过，无异常退出，关键输出包含 `** BUILD SUCCEEDED **`。**在满足此条件之前不要开始下一个任务。**

------

### Task 2: 在 `groupCardView` 中实现宽扇形扑克牌布局

**目标：** 单个分组卡片最多可渲染 5 张缩略图，并按实际数量呈居中对称的宽扇形扑克牌效果。

**涉及的文件：**

- `rawViewer/views/groupCardView.swift` — 分组卡片视图，负责缩略图布局和异步加载。

------

#### Step 1 — 实现

用以下完整内容替换 `rawViewer/views/groupCardView.swift`。

```swift
/*
Author: wilbur
Version: 2.2
Date: 2026-06-11
Description: 将分组卡片预览图改为最多 5 张的扑克牌宽扇形布局，保留降采样缩略图加载与复用取消逻辑
*/

import AppKit
import CoreImage

private struct fanCardLayout {
    let rotationDegrees: CGFloat
    let xOffset: CGFloat
    let yOffset: CGFloat
    let zPosition: CGFloat
}

public final class groupCardView: NSView {
    public var onTap: (() -> Void)?

    private let stackContainer = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var previewImageViews: [NSImageView] = []
    private var loadTasks: [Task<Void, Never>] = []

    public init(group: photoGroup, previewPhotos: [photoItem], imageService: photoImageService) {
        super.init(frame: .zero)
        setupView(group: group, previewPhotos: previewPhotos, imageService: imageService)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        loadTasks.forEach { $0.cancel() }
    }

    private func setupView(group: photoGroup, previewPhotos: [photoItem], imageService: photoImageService) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 8

        stackContainer.wantsLayer = true
        stackContainer.layer?.masksToBounds = false
        stackContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackContainer)

        let count = min(5, previewPhotos.count)
        let layouts = fanLayouts(for: count)

        for index in 0..<count {
            let layout = layouts[index]
            let imgView = NSImageView()
            imgView.imageScaling = .scaleProportionallyUpOrDown
            imgView.imageAlignment = .alignCenter
            imgView.wantsLayer = true
            imgView.layer?.backgroundColor = NSColor.darkGray.cgColor
            imgView.layer?.cornerRadius = 6
            imgView.layer?.borderWidth = 1.5
            imgView.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
            imgView.layer?.shadowColor = NSColor.black.cgColor
            imgView.layer?.shadowOpacity = 0.28
            imgView.layer?.shadowOffset = CGSize(width: 0, height: -4)
            imgView.layer?.shadowRadius = 8
            imgView.layer?.zPosition = layout.zPosition
            imgView.translatesAutoresizingMaskIntoConstraints = false
            stackContainer.addSubview(imgView)
            previewImageViews.append(imgView)

            NSLayoutConstraint.activate([
                imgView.centerXAnchor.constraint(equalTo: stackContainer.centerXAnchor, constant: layout.xOffset),
                imgView.centerYAnchor.constraint(equalTo: stackContainer.centerYAnchor, constant: layout.yOffset),
                imgView.widthAnchor.constraint(equalToConstant: 82),
                imgView.heightAnchor.constraint(equalToConstant: 108)
            ])

            imgView.layer?.transform = CATransform3DMakeRotation(layout.rotationDegrees * .pi / 180, 0, 0, 1)

            let photo = previewPhotos[index]
            let targetView = imgView
            let task = Task { [weak self] in
                let image = await imageService.loadThumbnail(for: photo, maxWidth: 164, maxHeight: 216)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self = self, self.previewImageViews.contains(targetView) else { return }
                    targetView.image = image
                }
            }
            loadTasks.append(task)
        }

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = group.kind.title

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.stringValue = "\(group.photos.count)"
        countLabel.alignment = .right

        addSubview(nameLabel)
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            stackContainer.topAnchor.constraint(equalTo: topAnchor),
            stackContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackContainer.heightAnchor.constraint(equalToConstant: 120),

            nameLabel.topAnchor.constraint(equalTo: stackContainer.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            countLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 4)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
    }

    private func fanLayouts(for count: Int) -> [fanCardLayout] {
        switch count {
        case 1:
            return [
                fanCardLayout(rotationDegrees: 0, xOffset: 0, yOffset: 4, zPosition: 1)
            ]
        case 2:
            return [
                fanCardLayout(rotationDegrees: -12, xOffset: -24, yOffset: -2, zPosition: 1),
                fanCardLayout(rotationDegrees: 12, xOffset: 24, yOffset: -2, zPosition: 2)
            ]
        case 3:
            return [
                fanCardLayout(rotationDegrees: -18, xOffset: -38, yOffset: -6, zPosition: 1),
                fanCardLayout(rotationDegrees: 0, xOffset: 0, yOffset: 8, zPosition: 3),
                fanCardLayout(rotationDegrees: 18, xOffset: 38, yOffset: -6, zPosition: 2)
            ]
        case 4:
            return [
                fanCardLayout(rotationDegrees: -24, xOffset: -52, yOffset: -10, zPosition: 1),
                fanCardLayout(rotationDegrees: -8, xOffset: -16, yOffset: 4, zPosition: 3),
                fanCardLayout(rotationDegrees: 8, xOffset: 16, yOffset: 4, zPosition: 4),
                fanCardLayout(rotationDegrees: 24, xOffset: 52, yOffset: -10, zPosition: 2)
            ]
        default:
            return [
                fanCardLayout(rotationDegrees: -24, xOffset: -54, yOffset: -10, zPosition: 1),
                fanCardLayout(rotationDegrees: -12, xOffset: -28, yOffset: 2, zPosition: 3),
                fanCardLayout(rotationDegrees: 0, xOffset: 0, yOffset: 10, zPosition: 5),
                fanCardLayout(rotationDegrees: 12, xOffset: 28, yOffset: 2, zPosition: 4),
                fanCardLayout(rotationDegrees: 24, xOffset: 54, yOffset: -10, zPosition: 2)
            ]
        }
    }

    @objc private func handleClick() {
        onTap?()
    }
}
```

------

#### Step 2 — 运行验证

运行构建，确认新布局代码没有 Swift 编译错误。

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
# 预期：输出包含 ** BUILD SUCCEEDED **；无 Swift 编译错误；无运行时步骤。
```

如果验证不通过，修复 `groupCardView.swift` 并重复运行命令，直到构建通过。

------

✅ **完成的标志：** 第二步验证通过 —— 构建通过，无异常退出，关键输出包含 `** BUILD SUCCEEDED **`。**在满足此条件之前不要开始下一个任务。**

------

### Task 3: 将分组预览数量统一改为 5 张

**目标：** 分组卡片入口和 ViewModel 辅助方法都返回最多 5 张预览照片，不再保留 3 张限制。

**涉及的文件：**

- `rawViewer/views/groupCollectionViewItem.swift` — 将传给卡片的预览照片从前 3 张改为前 5 张。
- `rawViewer/groupGrid/groupGridViewModel.swift` — 将 `previewPhotos(for:)` 同步改为前 5 张。

------

#### Step 1 — 实现

用以下完整内容替换 `rawViewer/views/groupCollectionViewItem.swift`。

```swift
/*
Author: wilbur
Version: 1.1
Date: 2026-06-11
Description: NSCollectionViewItem 子类，封装 groupCardView，预览图最多传入 5 张并支持 prepareForReuse 取消缩略图加载 Task
*/

import AppKit

public final class groupCollectionViewItem: NSCollectionViewItem {
    private var cardView: groupCardView?

    public func configure(with group: photoGroup, imageService: photoImageService) {
        cardView?.removeFromSuperview()

        let previewPhotos = Array(group.photos.prefix(5))
        let card = groupCardView(group: group, previewPhotos: previewPhotos, imageService: imageService)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.topAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        cardView = card
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        cardView?.removeFromSuperview()
        cardView = nil
    }
}
```

用以下完整内容替换 `rawViewer/groupGrid/groupGridViewModel.swift`。

```swift
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
```

------

#### Step 2 — 运行验证

运行构建，确认两个入口的 5 张限制不会造成编译问题。

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
# 预期：输出包含 ** BUILD SUCCEEDED **；无 Swift 编译错误；无运行时步骤。
```

如果验证不通过，修复本任务涉及的文件并重复运行命令，直到构建通过。

------

✅ **完成的标志：** 第二步验证通过 —— 构建通过，无异常退出，关键输出包含 `** BUILD SUCCEEDED **`。**在满足此条件之前不要开始下一个任务。**

------

### Task 4: 最终构建与人工视觉验收

**目标：** 应用可以成功构建，分组页卡片在人工检查中符合最多 5 张宽扇形扑克牌散开展示。

**涉及的文件：**

- `rawViewer/views/groupCardView.swift` — 最终视觉验收对象。
- `rawViewer/views/groupCollectionViewItem.swift` — 最终预览数量入口。
- `rawViewer/groupGrid/groupGridViewModel.swift` — 最终预览数量辅助方法。

------

#### Step 1 — 实现

本任务不再修改代码。确认前三个任务的代码已经保留，并且没有新增不受 `--debug` 控制的打印输出。

------

#### Step 2 — 运行验证

先运行最终构建。

```bash
$ xcodebuild -project rawViewer.xcodeproj -scheme pickpick -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
# 预期：输出包含 ** BUILD SUCCEEDED **；无 Swift 编译错误；无运行时步骤。
```

然后从 Xcode 或 Finder 启动 Debug 构建产物，打开分组页进行人工视觉检查。

```bash
$ open ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/pickpick.app
# 预期：应用启动无 crash；进入分组页后，每个分组卡片最多显示 5 张缩略图。
```

人工检查标准：

1. 1 张照片的分组：显示单张居中卡牌。
2. 2 张照片的分组：显示左右对称轻微展开。
3. 3 张照片的分组：显示左 / 中 / 右展开。
4. 4 张照片的分组：显示宽扇形且不留空占位。
5. 5 张及以上照片的分组：最多显示 5 张，并呈明显宽扇形扑克牌效果。
6. 分组标题与数量仍可见。
7. 点击卡片仍进入原有详情页面。
8. 滚动与窗口 resize 后布局稳定。

如果构建或人工检查不通过，回到对应任务修复实现，再重新运行本任务验证。

------

✅ **完成的标志：** 最终构建通过，应用启动无异常，人工检查确认关键视觉输出符合预期。
