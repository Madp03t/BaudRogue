
import SwiftUI

@main
struct MyApp: App {
    @AppStorage("libraryFontSize")
    private var libraryFontSize = 14.0

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

                Button("Increase Library Font Size") {
                    libraryFontSize = min(
                        26,
                        libraryFontSize + 1
                    )
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Decrease Library Font Size") {
                    libraryFontSize = max(
                        11,
                        libraryFontSize - 1
                    )
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Library Font Size") {
                    libraryFontSize = 14
                }
                .keyboardShortcut("0", modifiers: .command)
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

    private func send(_ action: Notification.Name) {
        NotificationCenter.default.post(
            name: action,
            object: nil
        )
    }
}
