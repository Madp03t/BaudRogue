
import SwiftUI
import SwiftTerm
import AppKit

// MARK: - Terminal Bridge

@MainActor
final class TerminalBridge {
    weak var terminalView: TerminalView?

    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?

    func receive(_ data: Data) {
        let bytes = Array(data)
        terminalView?.feed(byteArray: bytes[...])
    }
}

// MARK: - SwiftUI Terminal View

struct BaudRogueTerminalView: NSViewRepresentable {
    var bridge = TerminalBridge()

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    func makeNSView(context: Context) -> TerminalView {
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        bridge.terminalView = terminal
        return terminal
    }

    func updateNSView(
        _ nsView: TerminalView,
        context: Context
    ) {
        bridge.terminalView = nsView
    }

    static func dismantleNSView(
        _ nsView: TerminalView,
        coordinator: Coordinator
    ) {
        nsView.terminalDelegate = nil
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
