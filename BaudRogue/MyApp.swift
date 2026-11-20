
import SwiftUI

@main
struct MyApp: App {
    @AppStorage("libraryFontSize")
    private var libraryFontSize = 14.0

    @AppStorage("fontControlContext")
    private var fontControlContext = "Connections"

    private var isTerminal: Bool {
        fontControlContext == "Terminal"
    }

    private var isFixedBBS: Bool {
        fontControlContext == "BBS"
    }

    private var fontLabel: String {
        isTerminal ? "Terminal" : "Connections"
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Connection") {
                    send(BaudRogueAction.add)
                }
                .keyboardShortcut("n")

                Divider()

                Button("Import Connection Library…") {
                    send(BaudRogueAction.importLibrary)
                }

                Button("Export Connection Library…") {
                    send(BaudRogueAction.exportLibrary)
                }

                Button("Export Selected Connection…") {
                    send(BaudRogueAction.exportSelected)
                }
            }

            CommandGroup(after: .toolbar) {
                Divider()

                Button("Increase \(fontLabel) Font Size") {
                    adjustFont(by: 1)
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(isFixedBBS)

                Button("Decrease \(fontLabel) Font Size") {
                    adjustFont(by: -1)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(isFixedBBS)

                Button("Reset \(fontLabel) Font Size") {
                    resetFont()
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(isFixedBBS)
            }

            CommandMenu("Connection") {
                Button("Connect") {
                    send(BaudRogueAction.connect)
                }
                .keyboardShortcut(.return, modifiers: [])

                Button("Edit") {
                    send(BaudRogueAction.edit)
                }
                .keyboardShortcut("e")

                Button("Duplicate") {
                    send(BaudRogueAction.duplicate)
                }

                Divider()

                Button("Delete") {
                    send(BaudRogueAction.delete)
                }
            }
        }

        Settings {
            BaudRogueSettingsView()
        }
    }

    private func adjustFont(by amount: Double) {
        if isTerminal {
            NotificationCenter.default.post(
                name: Notification.Name("BaudRogue.adjustTerminalFont"),
                object: nil,
                userInfo: ["amount": amount]
            )
        } else {
            libraryFontSize = min(
                26,
                max(11, libraryFontSize + amount)
            )
        }
    }

    private func resetFont() {
        if isTerminal {
            send(Notification.Name("BaudRogue.resetTerminalFont"))
        } else {
            libraryFontSize = 14
        }
    }

    private func send(_ action: Notification.Name) {
        NotificationCenter.default.post(
            name: action,
            object: nil
        )
    }
}
