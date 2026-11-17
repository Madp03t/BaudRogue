
import SwiftUI

struct HostKeyApprovalView: View {
    let hostname: String
    let port: Int
    let fingerprint: String
    let onDecision: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(
                "Unknown SSH Server",
                systemImage: "lock.shield"
            )
            .font(.title2.weight(.semibold))

            Text("BaudRogue hasn't connected to this server before. Verify its fingerprint before trusting it.")

            LabeledContent("Server", value: hostname)
            LabeledContent("Port", value: String(port))

            VStack(alignment: .leading, spacing: 8) {
                Text("SHA256 Fingerprint")
                    .font(.headline)

                Text(fingerprint)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            Spacer()

            HStack {
                Button("Reject") {
                    onDecision(false)
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Trust Server") {
                    onDecision(true)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500, height: 330)
    }
}
