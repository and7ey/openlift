import AppKit

/// One tab in a pane's tab bar.
final class TabItemView: NSView {
    let index: Int
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    init(index: Int, title: String) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        closeButton.isBordered = false
        closeButton.bezelStyle = .inline
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 150),

            closeButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 12),
            closeButton.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: titleLabel.intrinsicContentSize.width + 36, height: 22)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(index)
    }

    /// The title label would otherwise swallow clicks, so the whole tab selects.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === closeButton ? closeButton : self
    }

    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = selected
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        titleLabel.textColor = selected ? .labelColor : .secondaryLabelColor
        titleLabel.font = .systemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: selected ? .medium : .regular
        )
    }

    @objc private func closeTapped() {
        onClose?(index)
    }
}

/// Horizontal tab strip shown at the top of each pane.
public final class PaneTabBarView: NSView {
    public var onSelect: ((Int) -> Void)?
    public var onClose: ((Int) -> Void)?
    public var onNew: (() -> Void)?

    private let stack = NSStackView()
    private let newButton = NSButton()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        newButton.isBordered = false
        newButton.bezelStyle = .inline
        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        newButton.imagePosition = .imageOnly
        newButton.contentTintColor = .secondaryLabelColor
        newButton.target = self
        newButton.action = #selector(newTapped)
        newButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(newButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            newButton.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 6),
            newButton.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newButton.widthAnchor.constraint(equalToConstant: 18),
            newButton.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func update(titles: [String], activeIndex: Int) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, title) in titles.enumerated() {
            let tab = TabItemView(index: index, title: title)
            tab.onSelect = { [weak self] index in self?.onSelect?(index) }
            tab.onClose = { [weak self] index in self?.onClose?(index) }
            tab.setSelected(index == activeIndex)
            stack.addArrangedSubview(tab)
        }
    }

    @objc private func newTapped() {
        onNew?()
    }
}
