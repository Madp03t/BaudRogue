import SwiftUI
import SwiftTerm
import AppKit

// MARK: - Terminal Bridge

@MainActor
final class TerminalBridge {
    weak var terminalView: TerminalView?

    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    var encoding = "CP437"

    // IBM Code Page 437, characters 0x80 through 0xFF.
    private static let cp437Characters = Array(
        (
            "ÇüéâäàåçêëèïîìÄÅ" +
            "ÉæÆôöòûùÿÖÜ¢£¥₧ƒ" +
            "áíóúñÑªº¿⌐¬½¼¡«»" +
            "░▒▓│┤╡╢╖╕╣║╗╝╜╛┐" +
            "└┴┬├─┼╞╟╚╔╩╦╠═╬╧" +
            "╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀" +
            "αßΓπΣσµτΦΘΩδ∞φε∩" +
            "≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ "
        ).unicodeScalars
    )

    func receive(_ data: Data) {
        guard let terminalView else {
            return
        }

        if encoding == "UTF-8" {
            let bytes = Array(data)
            terminalView.feed(byteArray: bytes[...])
            return
        }

        var converted: [UInt8] = []
        converted.reserveCapacity(data.count * 2)

        for byte in data {
            if byte < 128 {
                converted.append(byte)
            } else {
                let scalar = Self.cp437Characters[
                    Int(byte) - 128
                ]

                let character = String(
                    String.UnicodeScalarView([scalar])
                )

                converted.append(contentsOf: character.utf8)
            }
        }

        terminalView.feed(byteArray: converted[...])
    }
}

// MARK: - Terminal Container

final class BaudRogueTerminalContainer: NSView {
    let terminalView: TerminalView

    var fixedSize = true {
        didSet {
            if oldValue != fixedSize {
                needsLayout = true
            }
        }
    }

    // Remember the original font size for automatic-mode restoration.
    private let baseFontSize: CGFloat = 14
    private var fittedFontSize: CGFloat = 14

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = true

        addSubview(terminalView)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()

        guard bounds.width > 0, bounds.height > 0 else { return }

        if fixedSize {
            // Change the font size, not the 80 x 24 character grid.
            // The font and the cell sizes scale together, like Icy Term.
            let optimal = terminalView.getOptimalFrameSize()
            let currentSize = terminalView.font.pointSize

            guard optimal.width > 0, optimal.height > 0 else { return }

            let horizontalFit = (bounds.width - 12) / optimal.width
            let verticalFit = (bounds.height - 12) / optimal.height
            let fit = max(0.1, min(horizontalFit, verticalFit))

            // Half-point increments prevent font-size thrashing during drags.
            let proposed = min(64, max(8, (currentSize * fit * 2).rounded(.down) / 2))

            if abs(proposed - fittedFontSize) >= 0.5 {
                fittedFontSize = proposed
                terminalView.font = NSFont.monospacedSystemFont(
                    ofSize: proposed,
                    weight: .regular
                )
                terminalView.resize(cols: 80, rows: 24)
            }

            let desired = terminalView.getOptimalFrameSize()
            terminalView.frame = NSRect(
                x: max(0, (bounds.width - desired.width) / 2),
                y: max(0, (bounds.height - desired.height) / 2),
                width: desired.width,
                height: desired.height
            )
        } else {
            if abs(terminalView.font.pointSize - baseFontSize) >= 0.5 {
                fittedFontSize = baseFontSize
                terminalView.font = NSFont.monospacedSystemFont(
                    ofSize: baseFontSize,
                    weight: .regular
                )
            }
            // Automatic mode follows the available view size.
            terminalView.frame = bounds
        }
    }

}

// MARK: - SwiftUI Terminal View

struct BaudRogueTerminalView: NSViewRepresentable {
    var bridge = TerminalBridge()
    var sizeMode = "Fixed 80 Columns"

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    func makeNSView(
        context: Context
    ) -> BaudRogueTerminalContainer {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        // Establish an authentic 80x24 BBS grid.
        terminal.resize(cols: 80, rows: 24)

        let container = BaudRogueTerminalContainer(
            terminalView: terminal
        )

        container.fixedSize = sizeMode != "Automatic"
        bridge.terminalView = terminal

        return container
    }

    func updateNSView(
        _ nsView: BaudRogueTerminalContainer,
        context: Context
    ) {
        nsView.fixedSize = sizeMode != "Automatic"
        nsView.needsLayout = true
        bridge.terminalView = nsView.terminalView
    }

    static func dismantleNSView(
        _ nsView: BaudRogueTerminalContainer,
        coordinator: Coordinator
    ) {
        nsView.terminalView.terminalDelegate = nil
        coordinator.bridge.terminalView = nil
    }

    // MARK: - Terminal Delegate

    final class Coordinator: NSObject, TerminalViewDelegate {
        let bridge: TerminalBridge

        init(bridge: TerminalBridge) {
            self.bridge = bridge
        }

        func send(
            source: TerminalView,
            data: ArraySlice<UInt8>
        ) {
            bridge.onInput?(Data(data))
        }

        func sizeChanged(
            source: TerminalView,
            newCols: Int,
            newRows: Int
        ) {
            bridge.onResize?(newCols, newRows)
        }

        func setTerminalTitle(
            source: TerminalView,
            title: String
        ) {}

        func scrolled(
            source: TerminalView,
            position: Double
        ) {}

        func clipboardCopy(
            source: TerminalView,
            content: Data
        ) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                String(decoding: content, as: UTF8.self),
                forType: .string
            )
        }

        func hostCurrentDirectoryUpdate(
            source: TerminalView,
            directory: String?
        ) {}

        func requestOpenLink(
            source: TerminalView,
            link: String,
            params: [String: String]
        ) {}

        func rangeChanged(
            source: TerminalView,
            startY: Int,
            endY: Int
        ) {}
    }
}
