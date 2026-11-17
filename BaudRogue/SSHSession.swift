
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

// MARK: - SSH Errors

enum BaudRogueSSHError: LocalizedError {
    case authenticationUnavailable
    case hostKeyNotTrusted
    case hostKeyChanged
    case invalidChannelType

    var errorDescription: String? {
        switch self {
        case .authenticationUnavailable:
            return "Password authentication is unavailable."

        case .hostKeyNotTrusted:
            return "This SSH server has not been trusted."

        case .hostKeyChanged:
            return "The server's SSH host key has changed. Connection blocked."

        case .invalidChannelType:
            return "The server did not open a valid SSH session."
        }
    }
}

// MARK: - Password Authentication

nonisolated final class BaudRoguePasswordAuth:
    NIOSSHClientUserAuthenticationDelegate {

    private let username: String
    private let password: String
    private var attempted = false

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !attempted else {
            nextChallengePromise.succeed(nil)
            return
        }

        guard availableMethods.contains(.password) else {
            nextChallengePromise.fail(
                BaudRogueSSHError.authenticationUnavailable
            )
            return
        }

        attempted = true

        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: .password(.init(password: password))
        )

        nextChallengePromise.succeed(offer)
    }
}

// MARK: - Host Verification

nonisolated final class BaudRogueHostVerification:
    NIOSSHClientServerAuthenticationDelegate {

    private let lock = NSLock()

    private var handler:
        (@Sendable (String, EventLoopPromise<Void>) -> Void)?

    var verifyFingerprint:
        (@Sendable (String, EventLoopPromise<Void>) -> Void)? {

        get {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }

        set {
            lock.lock()
            defer { lock.unlock() }
            handler = newValue
        }
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let fingerprint = TrustedHosts.fingerprint(for: hostKey)

        guard !fingerprint.isEmpty,
              let verifyFingerprint else {
            validationCompletePromise.fail(
                BaudRogueSSHError.hostKeyNotTrusted
            )
            return
        }

        verifyFingerprint(
            fingerprint,
            validationCompletePromise
        )
    }
}

// MARK: - Host Approval Router

@MainActor
final class SSHHostApprovalRouter {
    var onApprovalRequested:
        ((String, Int, String, @escaping (Bool) -> Void) -> Void)?

    func requestApproval(
        host: String,
        port: Int,
        fingerprint: String,
        promise: EventLoopPromise<Void>
    ) {
        guard let onApprovalRequested else {
            promise.fail(BaudRogueSSHError.hostKeyNotTrusted)
            return
        }

        onApprovalRequested(host, port, fingerprint) { approved in
            guard approved else {
                promise.fail(BaudRogueSSHError.hostKeyNotTrusted)
                return
            }

            do {
                try TrustedHosts.shared.trust(
                    hostname: host,
                    port: port,
                    fingerprint: fingerprint
                )

                promise.succeed(())
            } catch {
                promise.fail(error)
            }
        }
    }
}

// MARK: - Incoming Terminal Data

nonisolated final class BaudRogueSSHDataHandler:
    ChannelInboundHandler {

    typealias InboundIn = SSHChannelData

    private let onReceive: (Data) -> Void

    init(onReceive: @escaping (Data) -> Void) {
        self.onReceive = onReceive
    }

    func channelRead(
        context: ChannelHandlerContext,
        data: NIOAny
    ) {
        let message = unwrapInboundIn(data)

        switch message.data {
        case .byteBuffer(var buffer):
            if let bytes = buffer.readBytes(
                length: buffer.readableBytes
            ), !bytes.isEmpty {
                onReceive(Data(bytes))
            }

        case .fileRegion:
            break
        }
    }

    func errorCaught(
        context: ChannelHandlerContext,
        error: Error
    ) {
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}

// MARK: - SSH Session

final class SSHSession {
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var connectionChannel: Channel?
    private var sessionChannel: Channel?

    private let hostVerification = BaudRogueHostVerification()
    private let approvalRouter = SSHHostApprovalRouter()

    private var reportedDisconnected = false

    var onError: ((Error) -> Void)?
    var onOutput: ((Data) -> Void)?
    var onDisconnected: (() -> Void)?

    var onHostKeyApprovalRequested:
        ((String, Int, String, @escaping (Bool) -> Void) -> Void)? {

        get {
            approvalRouter.onApprovalRequested
        }

        set {
            approvalRouter.onApprovalRequested = newValue
        }
    }

    func connect(
        host: String,
        port: Int,
        username: String,
        password: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        reportedDisconnected = false

        let group = MultiThreadedEventLoopGroup(
            numberOfThreads: 1
        )

        eventLoopGroup = group

        let authentication = BaudRoguePasswordAuth(
            username: username,
            password: password
        )

        let router = approvalRouter

        hostVerification.verifyFingerprint = { fingerprint, promise in
            Task { @MainActor in
                let result = TrustedHosts.shared.verify(
                    hostname: host,
                    port: port,
                    fingerprint: fingerprint
                )

                switch result {
                case .trusted:
                    promise.succeed(())

                case .unknown:
                    router.requestApproval(
                        host: host,
                        port: port,
                        fingerprint: fingerprint,
                        promise: promise
                    )

                case .changed:
                    promise.fail(
                        BaudRogueSSHError.hostKeyChanged
                    )
                }
            }
        }

        let verification = hostVerification

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let ssh = NIOSSHHandler(
                    role: .client(
                        .init(
                            userAuthDelegate: authentication,
                            serverAuthDelegate: verification
                        )
                    ),
                    allocator: channel.allocator,
                    inboundChildChannelInitializer: nil
                )

                do {
                    try channel.pipeline.syncOperations.addHandler(ssh)
                    return channel.eventLoop.makeSucceededFuture(())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .connectTimeout(.seconds(15))

        bootstrap.connect(
            host: host,
            port: port
        ).flatMap { [weak self] channel in

            channel.pipeline.handler(
                type: NIOSSHHandler.self
            ).flatMap { sshHandler in

                let promise = channel.eventLoop.makePromise(
                    of: Channel.self
                )

                sshHandler.createChannel(promise) {
                    childChannel, channelType in

                    guard channelType == .session else {
                        return childChannel.eventLoop.makeFailedFuture(
                            BaudRogueSSHError.invalidChannelType
                        )
                    }

                    let dataHandler = BaudRogueSSHDataHandler {
                        [weak self] receivedData in

                        DispatchQueue.main.async {
                            self?.onOutput?(receivedData)
                        }
                    }

                    return childChannel.pipeline.addHandler(
                        dataHandler
                    ).flatMap {
                        childChannel.setOption(
                            ChannelOptions.allowRemoteHalfClosure,
                            value: true
                        )
                    }
                }

                return promise.futureResult.flatMap { childChannel in

                    let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                        wantReply: true,
                        term: "xterm",
                        terminalCharacterWidth: 80,
                        terminalRowHeight: 24,
                        terminalPixelWidth: 0,
                        terminalPixelHeight: 0,
                        terminalModes: SSHTerminalModes([:])
                    )

                    return childChannel.triggerUserOutboundEvent(
                        pty
                    ).flatMap {

                        let shell = SSHChannelRequestEvent.ShellRequest(
                            wantReply: true
                        )

                        return childChannel.triggerUserOutboundEvent(
                            shell
                        )
                    }.map {
                        (channel, childChannel)
                    }
                }
            }
        }
        .whenComplete { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                switch result {
                case .success(let channels):
                    self.connectionChannel = channels.0
                    self.sessionChannel = channels.1

                    self.watchForDisconnection(
                        connection: channels.0,
                        session: channels.1
                    )

                    completion(.success(()))

                case .failure(let error):
                    self.onError?(error)
                    self.disconnect()
                    completion(.failure(error))
                }
            }
        }
    }

    // MARK: - Detect Remote Disconnect

    private func watchForDisconnection(
        connection: Channel,
        session: Channel
    ) {
        connection.closeFuture.whenComplete { [weak self] _ in
            DispatchQueue.main.async {
                self?.remoteDisconnected()
            }
        }

        session.closeFuture.whenComplete { [weak self] _ in
            DispatchQueue.main.async {
                self?.remoteDisconnected()
            }
        }
    }

    private func remoteDisconnected() {
        guard !reportedDisconnected else {
            return
        }

        reportedDisconnected = true
        onDisconnected?()
        disconnect()
    }

    // MARK: - Send Keyboard Input

    func send(_ data: Data) {
        guard let channel = sessionChannel,
              channel.isActive else {
            return
        }

        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(
                capacity: data.count
            )

            buffer.writeBytes(data)

            let message = SSHChannelData(
                type: .channel,
                data: .byteBuffer(buffer)
            )

            channel.writeAndFlush(message, promise: nil)
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        reportedDisconnected = true

        let session = sessionChannel
        let connection = connectionChannel
        let group = eventLoopGroup

        sessionChannel = nil
        connectionChannel = nil
        eventLoopGroup = nil

        session?.close(promise: nil)

        if let connection, let group {
            connection.closeFuture.whenComplete { _ in
                group.shutdownGracefully { _ in }
            }

            connection.close(promise: nil)

        } else if let group {
            group.shutdownGracefully { _ in }
        }
    }
}
