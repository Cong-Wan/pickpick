/*
Author: wilbur
Version: 1.1
Date: 2026-08-03
Description: 实现圆形进度界面和分析阶段、百分比、数量文本格式化逻辑；v1.1 彻底关闭曝光/虚焦检测：删除 rawAnalysis/jpgAnalysis 阶段文本
*/

import AppKit

public struct progressFormatter {
    public init() {}

    public func phaseText(for phase: analysisPhase) -> String {
        switch phase {
        case .scanning: return "Scanning"
        case .exifReading: return "Reading EXIF"
        case .duplicateGrouping: return "Grouping Duplicates"
        case .organizing: return "Organizing"
        case .completed: return "Completed"
        }
    }

    public func percentText(for progress: Double) -> String {
        let clamped = min(100, max(0, Int((progress * 100).rounded())))
        return "\(clamped)%"
    }

    public func countText(completed: Int, total: Int) -> String {
        "\(completed) / \(total)"
    }
}

public final class progressViewController: NSViewController {
    private let formatter = progressFormatter()
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let phaseLabel = NSTextField(labelWithString: "Scanning")
    private let countLabel = NSTextField(labelWithString: "0 / 0")
    private let indicator = NSProgressIndicator()

    public override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        indicator.style = .spinning
        indicator.controlSize = .large
        indicator.startAnimation(nil)

        let stack = NSStackView(views: [indicator, percentLabel, phaseLabel, countLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = .systemFont(ofSize: 32, weight: .semibold)
        phaseLabel.font = .systemFont(ofSize: 16)
        countLabel.font = .systemFont(ofSize: 13)
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    public func update(progress: analysisProgress) {
        percentLabel.stringValue = formatter.percentText(for: progress.overallProgress)
        phaseLabel.stringValue = formatter.phaseText(for: progress.phase)
        countLabel.stringValue = formatter.countText(completed: progress.completedCount, total: progress.totalCount)
    }
}
