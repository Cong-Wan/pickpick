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
