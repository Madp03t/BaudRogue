import SwiftUI
import AppKit

private struct PendingHostApproval: Identifiable {
    let id = UUID()
    let hostname: String
    let port: Int
    let fingerprint: String
    let respond: (Bool) -> Void
}

struct SSHConnectionView: View {
    let connection: SavedConnection
    let onConnectionChanged: (Bool) -> Void
    let onTerminalSizeChanged: (Int, Int) -> Void
    let onTerminalFontSizeChanged: (Double) -> Void

    init(
        connection: SavedConnection,
        onTerminalSizeChanged: @escaping (Int, Int) -> Void = { _, _ in },
        onTerminalFontSizeChanged: @escaping (Double) -> Void = { _ in },
        onConnectionChanged: @escaping (Bool) -> Void
    ) {
        self.connection = connection
        self.onTerminalSizeChanged = onTerminalSizeChanged
        self.onTerminalFontSizeChanged = onTerminalFontSizeChanged
        self.onConnectionChanged = onConnectionChanged
    }

    @State private var bridge = TerminalBridge()
    @State private var session: SSHSession?
    @State private var password = ""
    @State private var showingPassword = false
    @State private var pendingApproval: PendingHostApproval?
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @State private var isConnected = false
    @State private var terminalColumns = 80
    @State private var terminalRows = 24
    @State private var sshFontSize = 14.0
    @State private var showingConnectionLost = false
    @State private var showingSessionEnded = false
    @State private var reconnectAfterAlert = false
    @State private var closingView = false
    @State private var hasEstablishedConnection = false
    @State private var sessionToken: UUID?

    @FocusState private var passwordFocused: Bool

    var body: some View {
        BaudRogueTerminalView(
            bridge: bridge,
            sizeMode: connection.terminal.sizeMode,
            fontSize: sshFontSize
        )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            .onAppear {
                closingView = false
                bridge.encoding = connection.terminal.encoding
                sshFontSize = connection.terminal.fontSize ?? 14

                bridge.onInput = { data in
                    session?.send(data)
                }

                bridge.onResize = { columns, rows in
                    let safeColumns = max(1, columns)
                    let safeRows = max(1, rows)
                    terminalColumns = safeColumns
                    terminalRows = safeRows
                    onTerminalSizeChanged(safeColumns, safeRows)

                    // BBS mode never sends resize requests to the server.
                    // Automatic mode is intended for regular SSH administration.
                    if connection.terminal.sizeMode == "Automatic" && isConnected {
                        session?.resizeTerminal(columns: safeColumns, rows: safeRows)
                    }
                }

                showingPassword = true
            }
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("BaudRogue.adjustTerminalFont")
            )) { notification in
                guard connection.terminal.sizeMode == "Automatic",
                      let amount = notification.userInfo?["amount"] as? Double else {
                    return
                }
                updateSSHFontSize(sshFontSize + amount)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("BaudRogue.resetTerminalFont")
            )) { _ in
                guard connection.terminal.sizeMode == "Automatic" else { return }
                updateSSHFontSize(14)
            }
            .onDisappear {
                closingView = true
                pendingApproval?.respond(false)
                pendingApproval = nil

                session?.disconnect()
                session = nil
                sessionToken = nil
                bridge.onInput = nil
                bridge.onResize = nil

                isConnected = false
                onConnectionChanged(false)
            }
            .sheet(
                isPresented: $showingPassword,
                onDismiss: {
                    if isConnected {
                        focusTerminal()
                    }
                }
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Connect to \(connection.name)")
                        .font(.title2.weight(.semibold))

                    Text(
                        verbatim: connection.host + ":" +
                            String(connection.port)
                    )
                    .foregroundStyle(.secondary)

                    Text(connection.username)
                        .font(.callout)

                    SecureField("SSH Password", text: $password)
                        .textContentType(nil)
                        .focused($passwordFocused)
                        .onSubmit {
                            connect()
                        }

                    HStack {
                        Button("Cancel") {
                            showingPassword = false
                        }
                        .keyboardShortcut(.cancelAction)

                        Spacer()

                        Button("Connect") {
                            connect()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isConnecting)
                    }
                }
                .padding(24)
                .frame(width: 400)
                .onAppear {
                    passwordFocused = true
                }
            }
            .sheet(
                isPresented: $showingConnectionLost,
                onDismiss: {
                    if reconnectAfterAlert && !closingView {
                        reconnectAfterAlert = false
                        showingPassword = true
                    }
                }
            ) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.yellow)
                            .font(.title2)

                        Text("Connection Lost")
                            .font(.title2.weight(.semibold))
                    }

                    Text("The SSH connection to \(connection.name) was unexpectedly disconnected.")
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button("Reconnect to Last") {
                            reconnectAfterAlert = true
                            showingConnectionLost = false
                        }
                        .keyboardShortcut(.defaultAction)

                        Button("Saved Connections") {
                            showingConnectionLost = false
                            NotificationCenter.default.post(
                                name: Notification.Name("BaudRogue.showConnections"),
                                object: nil
                            )
                        }
                    }
                }
                .padding(24)
                .frame(width: 460)
                .interactiveDismissDisabled()
            }
            .sheet(
                isPresented: $showingSessionEnded,
                onDismiss: {
                    if reconnectAfterAlert && !closingView {
                        reconnectAfterAlert = false
                        showingPassword = true
                    }
                }
            ) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.green)
                            .font(.title2)

                        Text("Session Ended")
                            .font(.title2.weight(.semibold))
                    }

                    Text("The SSH session with \(connection.name) has ended normally.")
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button("Reconnect") {
                            reconnectAfterAlert = true
                            showingSessionEnded = false
                        }
                        .keyboardShortcut(.defaultAction)

                        Button("Saved Connections") {
                            showingSessionEnded = false
                            NotificationCenter.default.post(
                                name: Notification.Name("BaudRogue.showConnections"),
                                object: nil
                            )
                        }
                    }
                }
                .padding(24)
                .frame(width: 460)
                .interactiveDismissDisabled()
            }
            .sheet(item: $pendingApproval) { approval in
                HostKeyApprovalView(
                    hostname: approval.hostname,
                    port: approval.port,
                    fingerprint: approval.fingerprint
                ) { trusted in
                    approval.respond(trusted)
                    pendingApproval = nil
                }
                .interactiveDismissDisabled()
            }
            .alert(
                "SSH Connection Error",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: {
                        if !$0 {
                            errorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func updateSSHFontSize(_ requestedSize: Double) {
        let newSize = min(26, max(11, requestedSize))
        guard newSize != sshFontSize else { return }

        sshFontSize = newSize
        onTerminalFontSizeChanged(newSize)
        // The terminal view applies this value in Automatic mode.
    }

    private func focusTerminal() {
        guard let terminal = bridge.terminalView,
              let window = terminal.window else {
            return
        }

        window.makeFirstResponder(terminal)
    }

    private func connect() {
        guard !isConnecting else {
            return
        }

        let suppliedPassword = password
        password = ""
        showingPassword = false
        isConnecting = true
        isConnected = false

        let newSession = SSHSession()
        let token = UUID()
        sessionToken = token
        session = newSession
        hasEstablishedConnection = false
        showingConnectionLost = false
        showingSessionEnded = false

        newSession.onOutput = { data in
            bridge.receive(data)
        }

        newSession.onHostKeyApprovalRequested = {
            hostname, port, fingerprint, respond in

            pendingApproval = PendingHostApproval(
                hostname: hostname,
                port: port,
                fingerprint: fingerprint,
                respond: respond
            )
        }

        newSession.onDisconnected = {
            guard sessionToken == token else { return }

            let wasEstablished = hasEstablishedConnection && !closingView
            let unexpectedDrop = wasEstablished && !newSession.endedNormally
            let normalExit = wasEstablished && newSession.endedNormally
            hasEstablishedConnection = false
            isConnecting = false
            isConnected = false
            onConnectionChanged(false)

            if unexpectedDrop {
                showingConnectionLost = true
            } else if normalExit {
                showingSessionEnded = true
            }
        }

        newSession.connect(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: suppliedPassword
        ) { result in
            guard sessionToken == token, !closingView else { return }
            isConnecting = false

            switch result {
            case .success:
                hasEstablishedConnection = true
                isConnected = true
                onConnectionChanged(true)

                if connection.terminal.sizeMode == "Automatic" {
                    newSession.resizeTerminal(
                        columns: terminalColumns,
                        rows: terminalRows
                    )
                }

                DispatchQueue.main.async {
                    focusTerminal()
                }

            case .failure(let error):
                hasEstablishedConnection = false
                isConnected = false
                onConnectionChanged(false)
                errorMessage = error.localizedDescription
            }
        }
    }
}
