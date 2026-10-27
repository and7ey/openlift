import AppKit
import OpenLiftCore

/// Connection sheet for SFTP / FTP / FTPS.
///
/// Passwords stay in memory for this session (an empty password uses the SSH
/// agent or keys for SFTP). Nothing is written to disk.
@MainActor
public final class RemoteConnectionWindowController: NSWindowController {
    public var onConnect: ((RemoteConnection, _ save: Bool) -> Void)?

    private let protocolPopup = NSPopUpButton()
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let pathField = NSTextField()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let saveBookmarkButton = NSButton(
        checkboxWithTitle: "Save this connection in the Servers menu",
        target: nil,
        action: nil
    )
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)

    private var lastDefaultPort: Int = RemoteProtocol.sftp.defaultPort

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Connect to Server"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        TestWindowPlacement.place(window)
        super.init(window: window)
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func present(on parent: NSWindow?, prefill: RemoteConnection? = nil) {
        let proto = prefill?.proto ?? .sftp
        protocolPopup.selectItem(
            at: RemoteProtocol.allCases.firstIndex(of: proto) ?? 0
        )
        hostField.stringValue = prefill?.host ?? ""
        portField.stringValue = "\(prefill?.port ?? proto.defaultPort)"
        userField.stringValue = prefill?.username ?? ""
        passwordField.stringValue = ""
        pathField.stringValue = prefill?.path ?? "/"
        saveBookmarkButton.state = .off
        lastDefaultPort = proto.defaultPort
        updateHint()
        updateConnectState()
        showWindow(nil)
        if let parent, let window {
            parent.beginSheet(window)
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        window?.makeFirstResponder(hostField)
    }

    // MARK: - Layout

    private func configureContent() {
        guard let content = window?.contentView else { return }

        protocolPopup.addItems(withTitles: RemoteProtocol.allCases.map(\.title))
        protocolPopup.target = self
        protocolPopup.action = #selector(protocolChanged(_:))
        protocolPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true

        hostField.placeholderString = "host or IP"
        hostField.delegate = self
        hostField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        portField.placeholderString = "port"
        portField.delegate = self
        portField.widthAnchor.constraint(equalToConstant: 70).isActive = true

        userField.placeholderString = "username (optional)"
        userField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        passwordField.placeholderString = "password (empty = SSH agent/keys)"
        passwordField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        pathField.placeholderString = "initial path"
        pathField.stringValue = "/"
        pathField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let protocolRow = NSStackView(views: [
            label("Protocol:"), protocolPopup,
            label("Port:"), portField
        ])
        let hostRow = NSStackView(views: [label("Host:"), hostField])
        let userRow = NSStackView(views: [label("User:"), userField])
        let passwordRow = NSStackView(views: [label("Password:"), passwordField])
        let pathRow = NSStackView(views: [label("Path:"), pathField])

        for row in [protocolRow, hostRow, userRow, passwordRow, pathRow] {
            row.orientation = .horizontal
            row.spacing = 8
            row.alignment = .centerY
        }

        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor

        connectButton.target = self
        connectButton.action = #selector(connect(_:))
        connectButton.keyEquivalent = "\r"
        connectButton.bezelStyle = .rounded

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let form = NSStackView(views: [
            protocolRow,
            hostRow,
            userRow,
            passwordRow,
            pathRow,
            saveBookmarkButton,
            hintLabel
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(form)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            form.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),

            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return field
    }

    // MARK: - Actions

    @objc private func protocolChanged(_ sender: NSPopUpButton) {
        let proto = selectedProtocol
        if let port = Int(portField.stringValue), port == lastDefaultPort {
            portField.stringValue = "\(proto.defaultPort)"
        }
        lastDefaultPort = proto.defaultPort
        updateHint()
        updateConnectState()
    }

    @objc private func connect(_ sender: Any?) {
        guard let connection else { return }
        let save = saveBookmarkButton.state == .on
        dismiss()
        onConnect?(connection, save)
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss()
    }

    private var selectedProtocol: RemoteProtocol {
        let index = max(0, protocolPopup.indexOfSelectedItem)
        return RemoteProtocol.allCases[min(index, RemoteProtocol.allCases.count - 1)]
    }

    private var connection: RemoteConnection? {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        let port = Int(portField.stringValue) ?? selectedProtocol.defaultPort
        var path = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { path = "/" }
        return RemoteConnection(
            proto: selectedProtocol,
            host: host,
            port: port,
            username: userField.stringValue,
            password: passwordField.stringValue,
            path: path
        )
    }

    private func updateHint() {
        switch selectedProtocol {
        case .sftp:
            hintLabel.stringValue = "SFTP uses SSH. Leave the password empty to use the SSH agent or keys. The host key is trusted on first use."
        case .ftp, .ftps:
            hintLabel.stringValue = "FTP/FTPS credentials are used for this session only and are not saved."
        case .webdav, .webdavs:
            hintLabel.stringValue = "WebDAV uses HTTP basic authentication over HTTP/HTTPS. Credentials are not saved."
        }
    }

    private func updateConnectState() {
        connectButton.isEnabled = connection != nil
    }

    private func dismiss() {
        if let parent = window?.sheetParent {
            parent.endSheet(window!)
        } else {
            window?.close()
        }
    }
}

extension RemoteConnectionWindowController: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        updateConnectState()
    }
}
