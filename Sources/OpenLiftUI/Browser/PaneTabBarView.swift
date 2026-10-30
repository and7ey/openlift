import AppKit

/// One tab in a pane's tab bar: a flat, full-height segment with a title and a
/// close button. Tabs are rectangular and share the strip's width evenly.
final class TabItemView: NSView {
    let index: Int
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let separator = NSView()

    init(index: Int, title: String, showsCloseButton: Bool, showsSeparator: Bool) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true

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
        closeButton.isHidden = !showsCloseButton
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.isHidden = !showsSeparator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        let closeWidth: CGFloat = showsCloseButton ? 14 : 0
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -2),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: closeWidth),
            closeButton.heightAnchor.constraint(equalToConstant: 12),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16).cgColor
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
///
/// Tabs are rectangular and divide the strip evenly, so one tab fills it
/// completely. A short accent bar along the bottom edge marks the active pane.
public final class PaneTabBarView: NSView {
    public var onSelect: ((Int) -> Void)?
    public var onClose: ((Int) -> Void)?
    public var onNew: (() -> Void)?

    private let stack = NSStackView()
    private let newButton = NSButton()
    private let accentBar = NSView()
    private var isActive = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        stack.orientation = .horizontal
        stack.spacing = 0
        stack.distribution = .fillEqually
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

        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        accentBar.isHidden = true
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.trailingAnchor.constraint(equalTo: newButton.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: accentBar.topAnchor),

            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            newButton.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            newButton.widthAnchor.constraint(equalToConstant: 20),
            newButton.heightAnchor.constraint(equalToConstant: 20),

            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.heightAnchor.constraint(equalToConstant: 2)
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

        let showsClose = titles.count > 1
        for (index, title) in titles.enumerated() {
            let tab = TabItemView(
                index: index,
                title: title,
                showsCloseButton: showsClose,
                showsSeparator: index > 0
            )
            tab.onSelect = { [weak self] index in self?.onSelect?(index) }
            tab.onClose = { [weak self] index in self?.onClose?(index) }
            tab.setSelected(index == activeIndex)
            stack.addArrangedSubview(tab)
        }
    }

    /// Shows or hides the accent bar that marks the active pane.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        accentBar.isHidden = !active
    }

    @objc private func newTapped() {
        onNew?()
    }
}
