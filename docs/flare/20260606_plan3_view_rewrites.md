# View Rewrites 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 photoThumbnailView 从 NSStackView 全量重建改为 NSTableView 增量刷新；将 groupGridViewController 从 NSGridView 全量重建改为 NSCollectionView 自动布局；修复 columnCount 未扣除滚动条宽度的 BUG

**Architecture:** NSTableView 单列固定行高，cell 自管理缩略图异步加载 Task，setCurrentIndex 只刷新两行；NSCollectionView + NSCollectionViewFlowLayout 自动列数计算，item 复用池管理卡片生命周期

**Tech Stack:** Swift, AppKit

**Depends on:** Plan 1（photoImageService.loadThumbnail 返回 NSImage）

---

### Task 1: Create photoThumbnailCellView + Rewrite photoThumbnailView

**Goal:** 新建 NSTableCellView 子类自管理缩略图加载 Task（dequeue 时取消旧 task）；将 photoThumbnailView 改为 NSTableView，setCurrentIndex 只刷新两行而非全量重建

**Files touched:**

- `rawViewer/photoThumbnailCellView.swift` — TableView cell（新建）
- `rawViewer/photoThumbnailView.swift` — 改为 NSTableView（重写）

------

#### Step 1 — Implement photoThumbnailCellView

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-06
Description: 缩略图列表 NSTableCellView，包含 NSImageView + checkbox + 选中态边框，自管理异步缩略图加载 Task
*/

import AppKit

public final class photoThumbnailCellView: NSTableCellView {
    public let imageView = NSImageView()
    public let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var loadTask: Task<Void, Never>?

    public var thumbIndex: Int = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.clear.cgColor
        layer?.backgroundColor = NSColor.darkGray.cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3)
        ])
    }

    public func configure(
        photo: photoItem,
        index: Int,
        isSelected: Bool,
        isChecked: Bool,
        imageService: photoImageService?
    ) {
        thumbIndex = index
        cancelLoad()
        imageView.image = nil
        layer?.backgroundColor = NSColor.darkGray.cgColor
        layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        checkbox.state = isChecked ? .on : .off
        checkbox.tag = index

        guard let imageService = imageService else { return }
        let targetView = imageView
        loadTask = Task { [weak self, weak targetView] in
            let image = await imageService.loadThumbnail(for: photo)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self, let targetView = targetView, self.imageView === targetView else { return }
                if let image {
                    targetView.image = image
                    self.layer?.backgroundColor = NSColor.clear.cgColor
                }
            }
        }
    }

    public func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoad()
        imageView.image = nil
        layer?.backgroundColor = NSColor.darkGray.cgColor
        layer?.borderColor = NSColor.clear.cgColor
    }
}
```

------

#### Step 2 — Rewrite photoThumbnailView

```swift
/*
Author: wilbur
Version: 2.0
Date: 2026-06-06
Description: 缩略图列表 view，改用 NSTableView 单列布局；setCurrentIndex 仅刷新旧行和当前行；cell 自管理异步缩略图加载 Task；updatePhotos 时对 checkedIds 取与新 photo id 集合的交集
*/

import AppKit

public protocol photoThumbnailViewDelegate: AnyObject {
    func thumbnailDidSelect(index: Int)
    func thumbnailDidToggleCheck(photoId: String, isChecked: Bool)
    func thumbnailDidToggleAll(isChecked: Bool)
}

public final class photoThumbnailView: NSView {
    public weak var delegate: photoThumbnailViewDelegate?
    public private(set) var currentIndex: Int = 0
    public private(set) var checkedIds: Set<String> = []

    private var photos: [photoItem] = []
    private weak var imageService: photoImageService?

    private var scrollView = NSScrollView()
    private var tableView = NSTableView()
    private var allCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    public init(photos: [photoItem], imageService: photoImageService? = nil) {
        self.photos = photos
        self.imageService = imageService
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        allCheck.target = self
        allCheck.action = #selector(toggleAll(_:))
        allCheck.translatesAutoresizingMaskIntoConstraints = false
        let allLabel = NSTextField(labelWithString: "Select All")
        allLabel.font = .systemFont(ofSize: 11)
        allLabel.textColor = .secondaryLabelColor
        allLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(allCheck)
        header.addSubview(allLabel)
        NSLayoutConstraint.activate([
            allCheck.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 6),
            allCheck.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            allLabel.leadingAnchor.constraint(equalTo: allCheck.trailingAnchor, constant: 4),
            allLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(equalToConstant: 28)
        ])

        // TableView
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("thumb"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.style = .plain
        tableView.backgroundColor = NSColor.controlBackgroundColor
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))

        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        container.addSubview(header)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),

            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        updateAllCheckState()
    }

    // MARK: - Public API

    public func setCurrentIndex(_ index: Int) {
        guard photos.indices.contains(index) else { return }
        let oldIndex = currentIndex
        currentIndex = index
        let indices = oldIndex == index
            ? IndexSet(integer: index)
            : IndexSet([oldIndex, index])
        tableView.reloadData(forRowIndexes: indices, columnIndexes: IndexSet(integer: 0))
        tableView.scrollRowToVisible(index)
    }

    public func setCheckedIds(_ ids: Set<String>) {
        let allowedIds = Set(photos.map(\.photoId))
        checkedIds = ids.intersection(allowedIds)
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<photos.count), columnIndexes: IndexSet(integer: 0))
        updateAllCheckState()
    }

    public func updatePhotos(_ newPhotos: [photoItem]) {
        let newIds = Set(newPhotos.map(\.photoId))
        checkedIds = checkedIds.intersection(newIds)
        photos = newPhotos
        if !photos.indices.contains(currentIndex) {
            currentIndex = max(0, photos.count - 1)
        }
        tableView.reloadData()
        updateAllCheckState()
    }

    // MARK: - Actions

    @objc private func toggleAll(_ sender: NSButton) {
        let isChecked = sender.state == .on
        if isChecked {
            checkedIds = Set(photos.map(\.photoId))
        } else {
            checkedIds.removeAll()
        }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<photos.count), columnIndexes: IndexSet(integer: 0))
        delegate?.thumbnailDidToggleAll(isChecked: isChecked)
    }

    @objc private func rowDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard photos.indices.contains(row) else { return }
        setCurrentIndex(row)
        delegate?.thumbnailDidSelect(index: row)
    }

    private func updateAllCheckState() {
        allCheck.state = (!photos.isEmpty && checkedIds.count == photos.count) ? .on : .off
    }
}

// MARK: - NSTableViewDataSource

extension photoThumbnailView: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        photos.count
    }
}

// MARK: - NSTableViewDelegate

extension photoThumbnailView: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard photos.indices.contains(row) else { return nil }
        let cellId = NSUserInterfaceItemIdentifier("photoThumbnailCellView")
        let cell = (tableView.makeView(withIdentifier: cellId, owner: self) as? photoThumbnailCellView)
            ?? photoThumbnailCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 56))
        cell.identifier = cellId

        let photo = photos[row]
        let isChecked = checkedIds.contains(photo.photoId)
        cell.configure(photo: photo, index: row, isSelected: row == currentIndex, isChecked: isChecked, imageService: imageService)

        cell.checkbox.target = self
        cell.checkbox.action = #selector(toggleCheck(_:))

        let click = NSClickGestureRecognizer(target: self, action: #selector(thumbClicked(_:)))
        // 移除旧手势避免叠加
        cell.gestureRecognizers.removeAll()
        cell.addGestureRecognizer(click)

        return cell
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        56
    }

    @objc private func toggleCheck(_ sender: NSButton) {
        let index = sender.tag
        guard photos.indices.contains(index) else { return }
        let photoId = photos[index].photoId
        let isChecked = sender.state == .on
        if isChecked {
            checkedIds.insert(photoId)
        } else {
            checkedIds.remove(photoId)
        }
        updateAllCheckState()
        delegate?.thumbnailDidToggleCheck(photoId: photoId, isChecked: isChecked)
    }

    @objc private func thumbClicked(_ gesture: NSClickGestureRecognizer) {
        guard let cell = gesture.view as? photoThumbnailCellView else { return }
        let index = cell.thumbIndex
        guard photos.indices.contains(index) else { return }
        setCurrentIndex(index)
        delegate?.thumbnailDidSelect(index: index)
    }
}
```

------

#### Step 3 — Verify compilation

将 `photoThumbnailCellView.swift` 添加到 Xcode project target `rawViewer` 后执行：

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过。**Do not start the next task until this condition is met.**

------

### Task 2: Fix groupGridViewModel columnCount

**Goal:** columnCount 计算扣除滚动条宽度，修复网格最右侧卡片截断 BUG

**Files touched:**

- `rawViewer/groupGridViewModel.swift` — columnCount 扣除 scrollerWidth

------

#### Step 1 — Implement

修改 `columnCount(for:)` 方法，在可用宽度中扣除滚动条宽度：

```swift
/*
Author: wilbur
Version: 1.1
Date: 2026-06-06
Description: 分组网格视图模型，负责空组过滤、路由决策、预览取前几张以及响应式列数计算；columnCount 扣除滚动条宽度
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
        Array(group.photos.prefix(3))
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

#### Step 2 — Verify compilation

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过。**Do not start the next task until this condition is met.**

------

### Task 3: Create groupCollectionViewItem + Rewrite groupGridViewController

**Goal:** 新建 NSCollectionViewItem 子类复用卡片视图；将 groupGridViewController 从 NSGridView 全量重建改为 NSCollectionView，resize 时 invalidateLayout 而非重建

**Files touched:**

- `rawViewer/groupCollectionViewItem.swift` — CollectionView item（新建）
- `rawViewer/groupGridViewController.swift` — 改为 NSCollectionView（重写）

------

#### Step 1 — Implement groupCollectionViewItem

```swift
/*
Author: wilbur
Version: 1.0
Date: 2026-06-06
Description: NSCollectionViewItem 子类，封装 groupCardView，支持 prepareForReuse 取消缩略图加载 Task
*/

import AppKit

public final class groupCollectionViewItem: NSCollectionViewItem {
    private var cardView: groupCardView?

    public func configure(with group: photoGroup, imageService: photoImageService) {
        // 移除旧 cardView
        cardView?.removeFromSuperview()

        let previewPhotos = Array(group.photos.prefix(3))
        let card = groupCardView(group: group, previewPhotos: previewPhotos, imageService: imageService)
        card.translatesAutoresizingMaskIntoConstraints = false
        view.view.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.view.topAnchor),
            card.leadingAnchor.constraint(equalTo: view.view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.view.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: view.view.bottomAnchor)
        ])
        cardView = card
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        // groupCardView 的 deinit 会 cancel loadTasks
        cardView?.removeFromSuperview()
        cardView = nil
    }
}
```

------

#### Step 2 — Rewrite groupGridViewController

```swift
/*
Author: wilbur
Version: 4.0
Date: 2026-06-06
Description: 网格控制器改用 NSCollectionView + NSCollectionViewFlowLayout，resize 时 invalidateLayout 而非全量重建
*/

import AppKit

public func visibleGroupCards(from groups: [photoGroup]) -> [photoGroup] {
    groups.filter { !$0.photos.isEmpty }
}

public func route(for group: photoGroup) -> groupRoute {
    group.kind.isDuplicate ? .duplicateCompare : .browser
}

public final class groupGridViewController: NSViewController {
    public var onBack: (() -> Void)?
    public var onSelectGroup: ((photoGroup) -> Void)?

    private let viewModel: groupGridViewModel
    private let imageService: photoImageService

    private let toolbar = NSView()
    private let backButton = NSButton(title: "← Back", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "Groups")
    private var collectionView: NSCollectionView!
    private var flowLayout: NSCollectionViewFlowLayout!
    private var scrollView: NSScrollView!
    private var currentColumns: Int = 0

    public init(viewModel: groupGridViewModel, imageService: photoImageService) {
        self.viewModel = viewModel
        self.imageService = imageService
        super.init(nibName: nil, bundle: nil)
    }

    public convenience init(groups: [photoGroup], imageService: photoImageService) {
        self.init(viewModel: groupGridViewModel(groups: groups), imageService: imageService)
    }

    required init?(coder: NSCoder) {
        self.viewModel = groupGridViewModel(groups: [])
        self.imageService = photoImageService()
        super.init(coder: coder)
    }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // Toolbar
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(handleBack)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(backButton)
        toolbar.addSubview(titleLabel)
        root.addSubview(toolbar)

        // CollectionView
        flowLayout = NSCollectionViewFlowLayout()
        flowLayout.minimumInteritemSpacing = viewModel.columnSpacing
        flowLayout.minimumLineSpacing = viewModel.columnSpacing
        flowLayout.sectionInset = NSEdgeInsets(
            top: viewModel.horizontalPadding / 2,
            left: viewModel.horizontalPadding / 2,
            bottom: viewModel.horizontalPadding / 2,
            right: viewModel.horizontalPadding / 2
        )

        collectionView = NSCollectionView()
        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [NSColor.windowBackgroundColor]
        collectionView.register(groupCollectionViewItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("groupCard"))

        scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        view = root
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.bounds.width
        let columns = viewModel.columnCount(for: width)
        if columns != currentColumns {
            currentColumns = columns
            let cardWidth = viewModel.cardWidth(for: width)
            flowLayout.itemSize = NSSize(width: cardWidth, height: 180)
            collectionView.collectionViewLayout?.invalidateLayout()
        }
    }

    @objc private func handleBack() {
        onBack?()
    }
}

// MARK: - NSCollectionViewDataSource

extension groupGridViewController: NSCollectionViewDataSource {
    public func numberOfSections(in collectionView: NSCollectionView) -> Int {
        1
    }

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        viewModel.groups.count
    }

    public func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let identifier = NSUserInterfaceItemIdentifier("groupCard")
        let item = collectionView.makeItem(withIdentifier: identifier, for: indexPath) as! groupCollectionViewItem
        let group = viewModel.groups[indexPath.item]
        item.configure(with: group, imageService: imageService)

        // 点击回调（通过点击手势）
        if let card = item.view.view.subviews.first as? groupCardView {
            card.onTap = { [weak self] in
                self?.onSelectGroup?(group)
            }
        }

        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension groupGridViewController: NSCollectionViewDelegate {
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, indexPath.item < viewModel.groups.count else { return }
        let group = viewModel.groups[indexPath.item]
        onSelectGroup?(group)
        collectionView.deselectAll(nil)
    }
}
```

------

#### Step 3 — Verify compilation

将 `groupCollectionViewItem.swift` 添加到 Xcode project target `rawViewer` 后执行：

```bash
$ cd /Users/wilbur/project/rawViewer && xcodebuild -project rawViewer.xcodeproj -scheme rawViewer build 2>&1 | tail -5
# Expected output:
# ** BUILD SUCCEEDED **
```

------

✅ **Done when:** 项目编译通过。
