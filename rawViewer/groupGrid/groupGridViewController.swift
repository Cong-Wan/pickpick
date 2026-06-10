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

        if let card = item.view.subviews.first as? groupCardView {
            card.onTap = { [weak self] in
                self?.onSelectGroup?(group)
            }
        }

        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension groupGridViewController: NSCollectionViewDelegate {
}
