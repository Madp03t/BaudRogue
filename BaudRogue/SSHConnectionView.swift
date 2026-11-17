
import SwiftUI

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

    @State private var bridge = TerminalBridge()
    @State private var session: SSHSession?
    @State private var password = ""
    @State private var showingPassword = false
    @State private var pendingApproval: PendingHostApproval?
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @State private var isConnected = false

    var body: some View {
        BaudRogueTerminalView(bridge: bridge)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )
            .onAppear {
                bridge.onInput = { data in
                    session?.send(data)
                }

                showingPassword = true
            }
            .onDisappear {
                pendingApproval?.respond(false)
                pendingApproval = nil

                session?.disconnect()
                session = nil
                bridge.onInput = nil

                isConnected = false
                onConnectionChanged(false)
            }
            .sheet(isPresented: $showingPassword) {
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
                        .textContentType(.password)
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
        session = newSession

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
            isConnecting = false
            isConnected = false
            onConnectionChanged(false)
        }

        newSession.connect(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: suppliedPassword
        ) { result in
            isConnecting = false

            switch result {
            case .success:
                isConnected = true
                onConnectionChanged(true)

            case .failure(let error):
                isConnected = false
                onConnectionChanged(false)
                errorMessage = error.localizedDescription
            }
        }
    }
}
