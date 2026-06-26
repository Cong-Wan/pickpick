/*
Author: wilbur
Version: 1.3
Date: 2026-06-25
Description: NSCollectionViewItem 子类持有并复用 groupCardView，通过 configure/update 更新分组卡片数据；v1.3 prepareForReuse 清理 groupCardView 的任务和旧闭包
*/

import AppKit

public final class groupCollectionViewItem: NSCollectionViewItem {
    private var cardView: groupCardView?

    public func configure(imageService: photoImageService) {
        if cardView == nil {
            let card = groupCardView(imageService: imageService)
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
    }

    public func update(group: photoGroup) {
        let previewPhotos = Array(group.photos.prefix(5))
        cardView?.configure(group: group, previewPhotos: previewPhotos)
    }

    public func setOnTap(_ handler: @escaping () -> Void) {
        cardView?.onTap = handler
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        cardView?.resetForReuse()
    }
}
