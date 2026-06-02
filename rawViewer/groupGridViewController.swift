/*
Author: wilbur
Version: 1.0
Date: 2026-06-02
Description: 显示分析结果分组卡片，并提供空分组过滤、代表图选择和分组路由辅助逻辑
*/

import AppKit

public enum groupRoute: Equatable {
    case browser
    case duplicateCompare
}

public func visibleGroupCards(from groups: [photoGroup]) -> [photoGroup] {
    groups.filter { !$0.photos.isEmpty }
}

public func route(for group: photoGroup) -> groupRoute {
    group.kind.isDuplicate ? .duplicateCompare : .browser
}

public final class groupGridViewController: NSViewController {
    public var groups: [photoGroup]
    public var onSelectGroup: ((photoGroup) -> Void)?

    public init(groups: [photoGroup]) {
        self.groups = visibleGroupCards(from: groups)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.groups = []
        super.init(coder: coder)
    }

    public override func loadView() {
        let scroll = NSScrollView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        for group in groups {
            let button = NSButton(title: "\(group.kind.title) · \(group.photos.count)", target: self, action: #selector(selectGroup(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(group.id)
            stack.addArrangedSubview(button)
        }

        scroll.documentView = stack
        view = scroll
    }

    @objc private func selectGroup(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let group = groups.first(where: { $0.id == id }) else { return }
        onSelectGroup?(group)
    }
}
