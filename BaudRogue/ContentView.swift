
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Connection Data

struct TerminalPreferences: Codable, Equatable {
    var ansiEnabled = true
    var encoding = "CP437"
    var musicEnabled = false
    var sizeMode = "Fixed 80 Columns"
}

struct SavedConnection: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 22
    var username = ""
    var isFavorite = false
    var lastConnected: Date?
    var terminal = TerminalPreferences()

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)

        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try values.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try values.decodeIfPresent(String.self, forKey: .username) ?? ""
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        lastConnected = try values.decodeIfPresent(Date.self, forKey: .lastConnected)
        terminal = try values.decodeIfPresent(
            TerminalPreferences.self,
            forKey: .terminal
        ) ?? TerminalPreferences()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username
        case isFavorite, lastConnected, terminal
    }
}

// MARK: - Local Storage

enum ConnectionStorage {
    static var fileURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("BaudRogue", isDirectory: true)
        .appendingPathComponent("connections.json")
    }

    static func load() -> [SavedConnection] {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode(
                [SavedConnection].self,
                from: data
              ) else {
            return []
        }
        return saved
    }

    static func save(_ connections: [SavedConnection]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try encoder.encode(connections).write(
            to: fileURL,
            options: .atomic
        )
    }
}

// MARK: - Import / Export

struct ConnectionExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var connections: [SavedConnection]

    init(connections: [SavedConnection]) {
        self.connections = connections
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        connections = try JSONDecoder().decode(
            [SavedConnection].self,
            from: data
        )
    }

    func fileWrapper(
        configuration: WriteConfiguration
    ) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        return FileWrapper(
            regularFileWithContents: try encoder.encode(connections)
        )
    }
}

// MARK: - Menu Actions

enum BaudRogueAction {
    static let add = Notification.Name("BaudRogue.add")
    static let edit = Notification.Name("BaudRogue.edit")
    static let duplicate = Notification.Name("BaudRogue.duplicate")
    static let delete = Notification.Name("BaudRogue.delete")
    static let connect = Notification.Name("BaudRogue.connect")
    static let importLibrary = Notification.Name("BaudRogue.import")
    static let exportLibrary = Notification.Name("BaudRogue.export")
    static let exportSelected = Notification.Name("BaudRogue.exportSelected")
}

enum LibrarySort: String, CaseIterable {
    case favorites = "Favorites First"
    case alphabetical = "Name"
    case recent = "Recently Connected"
}

// MARK: - Main Window

struct ContentView: View {
    private enum ConnectionStatus {
        case offline
        case connected
        case disconnected
    }

    @AppStorage("libraryFontSize")
    private var libraryFontSize = 14.0

    @AppStorage("librarySort")
    private var sortRaw = LibrarySort.favorites.rawValue

    @State private var connections = ConnectionStorage.load()
    @State private var selectedConnectionID: UUID?
    @State private var hoveredConnectionID: UUID?
    @State private var activeConnectionID: UUID?
    @State private var hoveringConnectionsButton = false
    @State private var connectionStatus: ConnectionStatus = .offline
    @State private var terminalColumns = 80
    @State private var terminalRows = 24
    @State private var searchText = ""

    @State private var showingEditor = false
    @State private var draft = SavedConnection()
    @State private var connectionToDelete: SavedConnection?

    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportConnections: [SavedConnection] = []
    @State private var exportFilename = "BaudRogue-Connections"

    @State private var pendingImport: [SavedConnection] = []
    @State private var showingImportOptions = false
    @State private var errorMessage: String?

    private var selectedConnection: SavedConnection? {
        connections.first { $0.id == selectedConnectionID }
    }

    private var activeConnection: SavedConnection? {
        connections.first { $0.id == activeConnectionID }
    }

    private var displayedConnections: [SavedConnection] {
        let filtered = connections.filter {
            searchText.isEmpty ||
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.host.localizedCaseInsensitiveContains(searchText) ||
            $0.username.localizedCaseInsensitiveContains(searchText)
        }

        switch LibrarySort(rawValue: sortRaw) ?? .favorites {
        case .favorites:
            return filtered.sorted {
                if $0.isFavorite != $1.isFavorite {
                    return $0.isFavorite
                }
                return $0.name.localizedStandardCompare($1.name)
                    == .orderedAscending
            }

        case .alphabetical:
            return filtered.sorted {
                $0.name.localizedStandardCompare($1.name)
                    == .orderedAscending
            }

        case .recent:
            return filtered.sorted {
                if $0.lastConnected != $1.lastConnected {
                    return ($0.lastConnected ?? .distantPast) >
                           ($1.lastConnected ?? .distantPast)
                }

                return $0.name.localizedStandardCompare($1.name)
                    == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let activeConnection {
                terminalSession(activeConnection)
            } else if connections.isEmpty {
                emptyLibrary
            } else {
                connectionLibrary
            }

            Divider()

            statusBar
        }
        .navigationTitle(
            "BaudRogue \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"
        )
        .frame(minWidth: 600, minHeight: 400)
        .toolbar {
            if activeConnectionID != nil {
                ToolbarItem {
                    Button {
                        activeConnectionID = nil
                        connectionStatus = .offline
                    } label: {
                        Text("Connections")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        hoveringConnectionsButton
                                            ? Color.accentColor.opacity(0.12)
                                            : Color.primary.opacity(0.07)
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringConnectionsButton = $0 }
                    .help("Connections")
                }
            } else {
                ToolbarItem {
                    Button {
                        addConnection()
                    } label: {
                        Label("Add Connection", systemImage: "plus")
                    }
                    .help("Add Connection (⌘N)")
                }

                if !connections.isEmpty {
                    ToolbarItem {
                        Menu {
                            Picker("Sort By", selection: $sortRaw) {
                                ForEach(
                                    LibrarySort.allCases,
                                    id: \.rawValue
                                ) { option in
                                    Text(option.rawValue)
                                        .tag(option.rawValue)
                                }
                            }
                        } label: {
                            Label(
                                "Sort Connections",
                                systemImage: "arrow.up.arrow.down"
                            )
                        }
                        .help("Sort Connections")
                    }
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            ConnectionEditor(connection: $draft) {
                saveConnection()
            }
        }
        .confirmationDialog(
            "Delete Connection?",
            isPresented: Binding(
                get: { connectionToDelete != nil },
                set: {
                    if !$0 {
                        connectionToDelete = nil
                    }
                }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let connectionToDelete {
                    connections.removeAll {
                        $0.id == connectionToDelete.id
                    }

                    if selectedConnectionID == connectionToDelete.id {
                        selectedConnectionID = nil
                    }

                    if activeConnectionID == connectionToDelete.id {
                        activeConnectionID = nil
                    }

                    persistConnections()
                }

                connectionToDelete = nil
            }

            Button("Cancel", role: .cancel) {
                connectionToDelete = nil
            }
        } message: {
            Text("This connection will be removed from Connections.")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json]
        ) { result in
            do {
                let url = try result.get()

                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                pendingImport = try JSONDecoder().decode(
                    [SavedConnection].self,
                    from: Data(contentsOf: url)
                )

                showingImportOptions = true
            } catch {
                errorMessage = "Unable to import connections: \(error.localizedDescription)"
            }
        }
        .confirmationDialog(
            "Import \(pendingImport.count) Connections?",
            isPresented: $showingImportOptions
        ) {
            Button("Add New, Skip Duplicates") {
                mergeImport(updating: false)
            }

            Button("Add New, Update Duplicates") {
                mergeImport(updating: true)
            }

            Button("Cancel", role: .cancel) {
                pendingImport = []
            }
        } message: {
            Text(
                "Duplicates are matched by hostname, port, and username. Credentials are not imported."
            )
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: ConnectionExportDocument(
                connections: exportConnections
            ),
            contentType: .json,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                errorMessage = "Unable to export connections: \(error.localizedDescription)"
            }
        }
        .alert(
            "BaudRogue",
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
        .onReceive(
            NotificationCenter.default.publisher(
                for: BaudRogueAction.add
            )
        ) { _ in
            addConnection()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: BaudRogueAction.edit
            )
        ) { _ in
            if let selectedConnection {
                editConnection(selectedConnection)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: BaudRogueAction.duplicate
            )
        ) { _ in
            if let selectedConnection {
                duplicateConnection(selectedConnection)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: BaudRogueAction.delete
            )
        ) { _ in
            if let selectedConnection {
                connectionToDelete = selectedConnection
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: BaudRogueAction.connect
            )
        ) { _ in
            if let selectedConnection {
                openTerminal(selectedConnection)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: BaudRogueAction.importLibrary
            )
        ) { _ in
            showingImporter = true
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: BaudRogueAction.exportLibrary
            )
        ) { _ in
            exportAll()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: BaudRogueAction.exportSelected
            )
        ) { _ in
            if let selectedConnection {
                exportSelectedConnection(selectedConnection)
            } else {
                errorMessage = "Select a connection to export."
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionStatus == .connected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)

            Text(
                connectionStatus == .connected ? "Connected" :
                connectionStatus == .disconnected ? "Disconnected" : "Offline"
            )
                .foregroundStyle(.secondary)

            if let activeConnection {
                Text("·")
                    .foregroundStyle(.secondary)

                Text(activeConnection.name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if activeConnectionID == nil {
                Text(
                    "\(connections.count) \(connections.count == 1 ? "Connection" : "Connections")"
                )
                .foregroundStyle(.secondary)
            } else {
                Text("\(terminalColumns) × \(terminalRows)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("SSH terminal size (columns × rows)")
            }
        }
        .font(.caption)
        .padding(12)
    }

    // MARK: - Terminal Display

    
    private func terminalSession(
        _ connection: SavedConnection
    ) -> some View {
        SSHConnectionView(
            connection: connection,
            onTerminalSizeChanged: { columns, rows in
                terminalColumns = columns
                terminalRows = rows
            },
            onConnectionChanged: { connected in
                connectionStatus = connected ? .connected : .disconnected
            }
        )
    }


    private func openTerminal(_ connection: SavedConnection) {
        selectedConnectionID = connection.id
        activeConnectionID = connection.id
        connectionStatus = .offline
        terminalColumns = 80
        terminalRows = 24
    }

    // MARK: - Empty Library

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label(
                "No Connections Yet",
                systemImage: "desktopcomputer"
            )
        } description: {
            Text(
                "Add a connection or import existing connections."
            )
        } actions: {
            HStack(spacing: 12) {
                Button("Add Connection") {
                    addConnection()
                }

                Button("Import Connections…") {
                    showingImporter = true
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }

    // MARK: - Connection Library

    private var connectionLibrary: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connections")
                    .font(.title2.weight(.semibold))

                Spacer()
            }
            .padding()

            List(selection: $selectedConnectionID) {
                ForEach(displayedConnections) { connection in
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.secondary)

                        VStack(
                            alignment: .leading,
                            spacing: 4
                        ) {
                            Text(connection.name)
                                .font(
                                    .system(
                                        size: libraryFontSize,
                                        weight: .medium
                                    )
                                )
                                .lineLimit(1)

                            Text(
                                "\(connection.host):\(String(connection.port))"
                            )
                            .font(
                                .system(
                                    size: max(
                                        11,
                                        libraryFontSize - 2
                                    )
                                )
                            )
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                            if !connection.username.isEmpty {
                                Text(connection.username)
                                    .font(
                                        .system(
                                            size: max(
                                                11,
                                                libraryFontSize - 2
                                            )
                                        )
                                    )
                                    .foregroundStyle(.secondary)
                            }

                            if let date = connection.lastConnected {
                                Text(
                                    "Last connected: \(date.formatted(date: .abbreviated, time: .shortened))"
                                )
                                .font(
                                    .system(
                                        size: max(
                                            11,
                                            libraryFontSize - 3
                                        )
                                    )
                                )
                                .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer(minLength: 12)

                        Button {
                            toggleFavorite(connection)
                        } label: {
                            Image(
                                systemName: connection.isFavorite
                                    ? "star.fill"
                                    : "star"
                            )
                            .foregroundStyle(
                                connection.isFavorite
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                        }
                        .buttonStyle(.borderless)
                        .help(
                            connection.isFavorite
                                ? "Remove Favorite"
                                : "Add Favorite"
                        )
                    }
                    .padding(10)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                selectedConnectionID == connection.id
                                    ? Color.accentColor.opacity(0.15)
                                    : hoveredConnectionID == connection.id
                                        ? Color.primary.opacity(0.07)
                                        : Color.clear
                            )
                    }
                    .contentShape(Rectangle())
                    .tag(connection.id)
                    .onTapGesture(count: 2) {
                        openTerminal(connection)
                    }
                    .onHover { hovering in
                        if hovering {
                            hoveredConnectionID = connection.id
                        } else if hoveredConnectionID == connection.id {
                            hoveredConnectionID = nil
                        }
                    }
                    .contextMenu {
                        Button("Connect") {
                            openTerminal(connection)
                        }

                        Button("Edit") {
                            editConnection(connection)
                        }

                        Button("Duplicate") {
                            duplicateConnection(connection)
                        }

                        Divider()

                        Button("Export Connection…") {
                            exportSelectedConnection(connection)
                        }

                        Divider()

                        Button(
                            "Delete",
                            role: .destructive
                        ) {
                            connectionToDelete = connection
                        }
                    }
                }
            }
            .listStyle(.plain)
            .onDeleteCommand {
                if let selectedConnection {
                    connectionToDelete = selectedConnection
                }
            }
            .searchable(
                text: $searchText,
                prompt: "Search Connections"
            )
            .overlay {
                if displayedConnections.isEmpty {
                    ContentUnavailableView.search(
                        text: searchText
                    )
                }
            }
        }
    }

    // MARK: - Connection Actions

    private func addConnection() {
        draft = SavedConnection()
        showingEditor = true
    }

    private func editConnection(
        _ connection: SavedConnection
    ) {
        selectedConnectionID = connection.id
        draft = connection
        showingEditor = true
    }

    private func saveConnection() {
        if let index = connections.firstIndex(where: {
            $0.id == draft.id
        }) {
            connections[index] = draft
        } else {
            connections.append(draft)
        }

        selectedConnectionID = draft.id
        persistConnections()
        showingEditor = false
    }

    private func duplicateConnection(
        _ connection: SavedConnection
    ) {
        var copy = connection
        copy.id = UUID()
        copy.name += " Copy"
        copy.lastConnected = nil

        connections.append(copy)
        selectedConnectionID = copy.id
        persistConnections()
    }

    private func toggleFavorite(
        _ connection: SavedConnection
    ) {
        guard let index = connections.firstIndex(where: {
            $0.id == connection.id
        }) else {
            return
        }

        connections[index].isFavorite.toggle()
        persistConnections()
    }

    private func exportAll() {
        exportFilename = "BaudRogue-Connections"
        exportConnections = connections
        showingExporter = true
    }

    private func exportSelectedConnection(
        _ connection: SavedConnection
    ) {
        exportFilename = connection.name
            .replacingOccurrences(
                of: "/",
                with: "-"
            )
            .replacingOccurrences(
                of: ":",
                with: "-"
            )

        exportConnections = [connection]
        showingExporter = true
    }

    private func mergeImport(updating: Bool) {
        for item in pendingImport {
            let match = connections.firstIndex {
                $0.host.caseInsensitiveCompare(
                    item.host
                ) == .orderedSame &&
                $0.port == item.port &&
                $0.username.caseInsensitiveCompare(
                    item.username
                ) == .orderedSame
            }

            if let match {
                if updating {
                    var updated = item
                    updated.id = connections[match].id
                    connections[match] = updated
                }
            } else {
                var newItem = item
                newItem.id = UUID()
                connections.append(newItem)
            }
        }

        pendingImport = []
        persistConnections()
    }

    private func persistConnections() {
        do {
            try ConnectionStorage.save(connections)
        } catch {
            errorMessage =
                "Unable to save connections: \(error.localizedDescription)"
        }
    }
}

// MARK: - Connection Editor

struct ConnectionEditor: View {
    @Environment(\.dismiss)
    private var dismiss

    @Binding var connection: SavedConnection
    var onSave: () -> Void

    @State private var original: SavedConnection
    @State private var showingDiscardConfirmation = false

    init(
        connection: Binding<SavedConnection>,
        onSave: @escaping () -> Void
    ) {
        self._connection = connection
        self.onSave = onSave
        self._original = State(
            initialValue: connection.wrappedValue
        )
    }

    private var hasUnsavedChanges: Bool {
        connection != original
    }

    private var isValid: Bool {
        !connection.name.trimmingCharacters(
            in: .whitespaces
        ).isEmpty &&
        !connection.host.trimmingCharacters(
            in: .whitespaces
        ).isEmpty &&
        (1...65535).contains(connection.port)
    }

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 16
        ) {
            Text("Connection Settings")
                .font(.title2.weight(.semibold))

            Form {
                Section("Connection") {
                    TextField(
                        "Connection Name",
                        text: $connection.name
                    )

                    TextField(
                        "Hostname or IP Address",
                        text: $connection.host
                    )

                    TextField(
                        "SSH Port",
                        value: $connection.port,
                        format: .number.grouping(.never)
                    )

                    TextField(
                        "Username",
                        text: $connection.username
                    )

                    Toggle(
                        "Favorite",
                        isOn: $connection.isFavorite
                    )
                }

                Section("Terminal") {
                    Toggle(
                        "ANSI Graphics",
                        isOn: $connection.terminal.ansiEnabled
                    )

                    Picker(
                        "Character Encoding",
                        selection: $connection.terminal.encoding
                    ) {
                        Text("CP437").tag("CP437")
                        Text("UTF-8").tag("UTF-8")
                    }

                    Picker(
                        "Terminal Size",
                        selection: $connection.terminal.sizeMode
                    ) {
                        Text("Fixed 80 Columns")
                            .tag("Fixed 80 Columns")
                        Text("Automatic")
                            .tag("Automatic")
                    }

                    Toggle(
                        "ANSI Music",
                        isOn: $connection.terminal.musicEnabled
                    )
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()

                Button("Cancel") {
                    cancelEditing()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 480, height: 570)
        .interactiveDismissDisabled(
            hasUnsavedChanges
        )
        .confirmationDialog(
            "Discard Unsaved Changes?",
            isPresented: $showingDiscardConfirmation
        ) {
            Button(
                "Discard Changes",
                role: .destructive
            ) {
                dismiss()
            }

            Button(
                "Keep Editing",
                role: .cancel
            ) {}
        } message: {
            Text(
                "Your changes to this connection have not been saved."
            )
        }
    }

    private func cancelEditing() {
        if hasUnsavedChanges {
            showingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }
}

// MARK: - Application Settings

struct BaudRogueSettingsView: View {
    @AppStorage("libraryFontSize")
    private var libraryFontSize = 14.0

    @AppStorage("librarySort")
    private var sortRaw = LibrarySort.favorites.rawValue

    var body: some View {
        Form {
            Section("Connections") {
                HStack {
                    Text("Font Size")

                    Spacer()

                    Button {
                        libraryFontSize = max(
                            11,
                            libraryFontSize - 1
                        )
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(libraryFontSize <= 11)
                    .help("Decrease Font Size")

                    Text("\(Int(libraryFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 45)

                    Button {
                        libraryFontSize = min(
                            26,
                            libraryFontSize + 1
                        )
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(libraryFontSize >= 26)
                    .help("Increase Font Size")

                    Button("Reset") {
                        libraryFontSize = 14
                    }
                }

                Picker(
                    "Default Sorting",
                    selection: $sortRaw
                ) {
                    ForEach(
                        LibrarySort.allCases,
                        id: \.rawValue
                    ) { option in
                        Text(option.rawValue)
                            .tag(option.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 230)
    }
}
