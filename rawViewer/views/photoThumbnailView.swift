/*
Author: wilbur
Version: 2.1
Date: 2026-06-10
Description: 修复 checkbox 点击被 NSClickGestureRecognizer 拦截的问题：为 cell 手势添加 NSGestureRecognizerDelegate，当点击位置落在 checkbox frame 内时拒绝接收事件
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

// MARK: - NSGestureRecognizerDelegate

extension photoThumbnailView: NSGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let cell = gestureRecognizer.view as? photoThumbnailCellView else { return true }
        let location = gestureRecognizer.location(in: cell)
        return !cell.checkbox.frame.contains(location)
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
        click.delegate = self
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
        let location = gesture.location(in: cell)
        if cell.checkbox.frame.contains(location) { return }
        let index = cell.thumbIndex
        guard photos.indices.contains(index) else { return }
        setCurrentIndex(index)
        delegate?.thumbnailDidSelect(index: index)
    }
}
