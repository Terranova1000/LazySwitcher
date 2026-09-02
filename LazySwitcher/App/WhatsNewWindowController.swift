import AppKit

/// Shows what changed in the version now running.
///
/// Appears by itself once after an update, and from the menu whenever anybody
/// wants it again. The text comes out of the bundle (`ReleaseNotes`), so this
/// window works offline and with update checking switched off.
///
/// The support section below the notes is present only when
/// `SupportPrompt.isEnabled`, which today it is not. It is laid out here rather
/// than in a window of its own on purpose: an application that has just told
/// you what it fixed has earned the sentence that follows, and a separate
/// banner arriving on its own schedule would be one interruption more.
final class WhatsNewWindowController: NSWindowController {

    private let notes: String
    private var onSupport: (() -> Void)?

    init(notes: String) {
        self.notes = notes
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("whatsnew.window.title")
        window.center()
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        guard let window else { return }

        let banner = NSImageView(image: NSImage(named: "Banner") ?? NSImage())
        banner.imageScaling = .scaleProportionallyUpOrDown
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 10
        banner.layer?.masksToBounds = true
        banner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            banner.widthAnchor.constraint(equalToConstant: 456),
            banner.heightAnchor.constraint(equalToConstant: 214),
        ])

        let title = NSTextField(labelWithString:
            String(format: L("whatsnew.title"), ReleaseNotes.currentVersion))
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        // A wrapping label inside the scroll view, not an `NSTextView`.
        //
        // The first version used a bare `NSTextView()`, and it shipped with the
        // window opening and no text in it. A text view created without a frame
        // has no size and does not grow to fit its content unless it is told to
        // — `isVerticallyResizable`, the text container's size, the tracking
        // flags. The string was there the whole time; there was nowhere to draw
        // it. A label wraps and reports its own height without any of that, and
        // it is what the rest of this application already uses.
        //
        // The verification failed the same way the code did: the test asserted
        // the window existed, which it did. It now looks for the text.
        let body = NSTextField(wrappingLabelWithString: notes)
        body.font = .systemFont(ofSize: 13)
        body.isSelectable = true
        body.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -4),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
            body.widthAnchor.constraint(equalToConstant: 440),
        ])

        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            scroll.widthAnchor.constraint(equalToConstant: 456),
        ])

        let stack = NSStackView(views: [banner, title, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Only when there is somewhere to send people. See `SupportPrompt`.
        if SupportPrompt.isEnabled {
            let ask = NSTextField(wrappingLabelWithString: L("support.body"))
            ask.font = .systemFont(ofSize: 13)
            ask.preferredMaxLayoutWidth = 452

            let support = NSButton(title: L("support.button"),
                                   target: self, action: #selector(openSupport(_:)))
            support.keyEquivalent = ""
            let never = NSButton(title: L("support.never"),
                                 target: self, action: #selector(silenceSupport(_:)))
            never.bezelStyle = .accessoryBarAction

            let row = NSStackView(views: [support, never])
            row.orientation = .horizontal
            row.spacing = 10

            // A plain view, not an NSBox: a default-initialised box draws a
            // titled frame captioned «Название», which is where the mystery
            // captions elsewhere in this app came from. A test enforces this.
            let separator = NSView()
            separator.wantsLayer = true
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
            separator.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                separator.widthAnchor.constraint(equalToConstant: 456),
                separator.heightAnchor.constraint(equalToConstant: 1),
            ])

            stack.addArrangedSubview(separator)
            stack.addArrangedSubview(ask)
            stack.addArrangedSubview(row)
            SupportPrompt.noteAsked()
        }

        let done = NSButton(title: L("whatsnew.done"), target: self, action: #selector(close(_:)))
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        content.addSubview(done)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            done.topAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 14),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            done.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
    }

    @objc private func openSupport(_ sender: Any?) {
        if let url = SupportPrompt.destination { NSWorkspace.shared.open(url) }
        SupportPrompt.noteAsked()
        close(nil)
    }

    @objc private func silenceSupport(_ sender: Any?) {
        SupportPrompt.silence()
        close(nil)
    }

    @objc private func close(_ sender: Any?) {
        window?.close()
    }

    /// Diagnostic: is the text actually taking up space on screen?
    ///
    /// Exists because "the window opened" was mistaken for "the window works"
    /// once already, and the difference was invisible from outside.
    var notesAreVisible: Bool {
        guard let root = window?.contentView else { return false }
        var stack = [root]
        while let view = stack.popLast() {
            if let field = view as? NSTextField, field.stringValue == notes {
                return field.frame.height > 1 && field.frame.width > 1
            }
            stack.append(contentsOf: view.subviews)
        }
        return false
    }
}
