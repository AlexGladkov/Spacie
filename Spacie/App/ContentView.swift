import SwiftUI

// MARK: - ActivePanel

/// Identifies which feature panel is currently displayed in the main content area.
enum ActivePanel: String, Sendable, CaseIterable, Identifiable {
    case visualization
    case largeFiles
    case duplicates
    case smartCategories
    case oldFiles

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .visualization: "Visualization"
        case .largeFiles: "Large Files"
        case .duplicates: "Duplicates"
        case .smartCategories: "Smart Clean"
        case .oldFiles: "Old Files"
        }
    }

    var systemImage: String {
        switch self {
        case .visualization: "circle.circle"
        case .largeFiles: "doc.fill"
        case .duplicates: "doc.on.doc.fill"
        case .smartCategories: "wand.and.stars"
        case .oldFiles: "clock.fill"
        }
    }
}

// MARK: - AppViewModel

/// Primary view model for a single tab / scan session.
///
/// Orchestrates the scan lifecycle, manages navigation state, and holds
/// references to the active file tree and visualization parameters.
@MainActor
@Observable
final class AppViewModel {

    // MARK: - State

    /// The volume currently selected for scanning.
    var volume: VolumeInfo?

    /// Current state of the scan pipeline.
    var scanState: ScanState = .idle

    /// The resulting file tree after a successful scan.
    var tree: FileTree?

    /// The active visualization mode (sunburst or treemap).
    var vizMode: VisualizationMode {
        didSet { UserDefaults.standard.set(vizMode.rawValue, forKey: "defaultVisualizationMode") }
    }

    /// Whether sizes display logical or physical values.
    var sizeMode: SizeMode {
        didSet { UserDefaults.standard.set(sizeMode.rawValue, forKey: "defaultSizeMode") }
    }

    /// Which feature panel is currently active in the main content area.
    var activePanel: ActivePanel = .visualization

    /// User-entered search query for filtering files.
    var searchQuery: String = ""

    /// Visualization navigation state shared with visualization views.
    var vizState: VisualizationState?

    /// Whether the FDA banner should be displayed.
    var showFDABanner: Bool = false

    /// Whether the "go to folder" sheet is presented.
    var showGoToFolder: Bool = false

    /// Path entered by the user in the Go to Folder dialog.
    var goToFolderPath: String = ""

    /// Timestamp of the last completed scan.
    var lastScanDate: Date?

    /// Whether FSEvents have detected changes since the last scan.
    var dataIsStale: Bool = false

    // MARK: - Private

    private let scanner = DiskScanner()
    private var scanTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        let savedViz = UserDefaults.standard.string(forKey: "defaultVisualizationMode") ?? VisualizationMode.sunburst.rawValue
        self.vizMode = VisualizationMode(rawValue: savedViz) ?? .sunburst

        let savedSize = UserDefaults.standard.string(forKey: "defaultSizeMode") ?? SizeMode.logical.rawValue
        self.sizeMode = SizeMode(rawValue: savedSize) ?? .logical
    }

    // MARK: - Scan

    /// Initiates a full scan of the selected volume.
    ///
    /// Creates a ``ScanConfiguration`` from the current volume and feeds events
    /// from ``DiskScanner`` into a new ``FileTree``. Updates ``scanState``
    /// throughout the process so the UI can reflect progress.
    func startScan() async {
        guard let volume else { return }

        cancelScan()
        scanState = .scanning(ScanProgress(
            filesScanned: 0,
            directoriesScanned: 0,
            totalSizeScanned: 0,
            currentPath: volume.mountPoint.path,
            elapsedTime: 0,
            estimatedTotalFiles: nil
        ))

        let newTree = FileTree()
        tree = newTree

        let rootIndex = newTree.rootIndex
        vizState = VisualizationState(rootIndex: rootIndex, sizeMode: sizeMode)

        let configuration = ScanConfiguration(
            rootPath: volume.mountPoint,
            volumeId: volume.id
        )

        let stream = scanner.scan(configuration: configuration)

        scanTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }

                switch event {
                case .fileFound(let rawNode):
                    newTree.insert(rawNode)

                case .progress(let progress):
                    self?.scanState = .scanning(progress)

                case .completed(let stats):
                    newTree.aggregateSizes()
                    newTree.finalizeBuild()
                    self?.scanState = .completed(stats)
                    self?.lastScanDate = Date()
                    self?.dataIsStale = false

                case .restricted:
                    self?.showFDABanner = true

                case .directoryEntered, .directoryCompleted:
                    break

                case .error:
                    break
                }
            }

            if Task.isCancelled {
                self?.scanState = .cancelled
            }
        }
    }

    /// Cancels the currently running scan, if any.
    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if scanState.isScanning {
            scanState = .cancelled
        }
    }

    /// Discards the current tree and rescans the same volume from scratch.
    func rescan() async {
        tree = nil
        vizState = nil
        scanState = .idle
        dataIsStale = false
        await startScan()
    }

    /// Navigates the visualization to the parent of the current root.
    func navigateToParent() {
        guard let vizState, let tree else { return }
        guard let currentNode = tree.node(at: vizState.currentRootIndex) else { return }
        if currentNode.parentIndex != UInt32.max && currentNode.parentIndex != vizState.currentRootIndex {
            vizState.drillDown(to: currentNode.parentIndex)
        }
    }
}

// MARK: - ContentView

/// Root view for a single Spacie window/tab.
///
/// Displays one of three screens depending on the scan state:
/// 1. **Start screen** -- a grid of available volumes when no scan is active.
/// 2. **Scanning screen** -- live progress during a scan.
/// 3. **Results screen** -- visualization and feature panels after a scan completes.
struct ContentView: View {

    @State private var viewModel = AppViewModel()
    @Environment(VolumeManager.self) private var volumeManager
    @Environment(PermissionManager.self) private var permissionManager

    var body: some View {
        VStack(spacing: 0) {
            // FDA banner
            if viewModel.showFDABanner && !permissionManager.hasFullDiskAccess {
                fdaBanner
            }

            // Main content
            mainContent
        }
        .toolbar { toolbarContent }
        .navigationTitle(navigationTitle)
        .onReceive(NotificationCenter.default.publisher(for: .spacieSetVisualization)) { notification in
            if let mode = notification.object as? VisualizationMode {
                viewModel.vizMode = mode
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spacieRescan)) { _ in
            Task { await viewModel.rescan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spacieNavigateBack)) { _ in
            viewModel.vizState?.navigateBack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .spacieNavigateForward)) { _ in
            viewModel.vizState?.navigateForward()
        }
        .onReceive(NotificationCenter.default.publisher(for: .spacieNavigateParent)) { _ in
            viewModel.navigateToParent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .spacieGoToFolder)) { _ in
            viewModel.showGoToFolder = true
        }
        .sheet(isPresented: $viewModel.showGoToFolder) {
            goToFolderSheet
        }
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        if let volume = viewModel.volume {
            return volume.name
        }
        return "Spacie"
    }

    // MARK: - FDA Banner

    private var fdaBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(SpacieColors.warningForeground)
            Text("Some directories are restricted. Grant Full Disk Access for a complete scan.")
                .font(.callout)
            Spacer()
            Button("Open Settings") {
                permissionManager.openFullDiskAccessSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                withAnimation { viewModel.showFDABanner = false }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SpacieColors.warningBackground)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        switch viewModel.scanState {
        case .idle:
            startScreen

        case .scanning(let progress):
            scanningScreen(progress: progress)

        case .completed:
            resultsScreen

        case .cancelled:
            startScreen

        case .error(let message):
            errorScreen(message: message)
        }
    }

    // MARK: - Start Screen

    private var startScreen: some View {
        VolumePickerView(volumes: volumeManager.volumes) { volume in
            viewModel.volume = volume
            Task { await viewModel.startScan() }
        }
    }

    // MARK: - Scanning Screen

    private func scanningScreen(progress: ScanProgress) -> some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                ProgressView(value: progress.estimatedProgress ?? 0)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 400)

                HStack(spacing: 20) {
                    Label(progress.filesScanned.formattedCount + " files", systemImage: "doc")
                    Label(progress.totalSizeScanned.formattedSize, systemImage: "internaldrive")
                    Label(progress.elapsedTime.formattedDuration, systemImage: "clock")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Text(progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 500)

                Button("Cancel") {
                    viewModel.cancelScan()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()

            Spacer()

            InfoBarView(viewModel: viewModel)
        }
    }

    // MARK: - Results Screen

    private var resultsScreen: some View {
        VStack(spacing: 0) {
            // Breadcrumb bar
            if let vizState = viewModel.vizState, let tree = viewModel.tree {
                breadcrumbBar(vizState: vizState, tree: tree)
            }

            // Main panel
            panelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Info bar
            InfoBarView(viewModel: viewModel)
        }
    }

    // MARK: - Breadcrumb Bar

    /// Delegates to the shared ``BreadcrumbView`` implemented in the Visualization module.
    private func breadcrumbBar(vizState: VisualizationState, tree: FileTree) -> some View {
        BreadcrumbView(tree: tree, state: vizState)
    }

    // MARK: - Panel Content

    @ViewBuilder
    private var panelContent: some View {
        switch viewModel.activePanel {
        case .visualization:
            visualizationPlaceholder
        case .largeFiles:
            placeholderPanel(name: "Large Files", icon: "doc.fill")
        case .duplicates:
            placeholderPanel(name: "Duplicates", icon: "doc.on.doc.fill")
        case .smartCategories:
            placeholderPanel(name: "Smart Categories", icon: "wand.and.stars")
        case .oldFiles:
            placeholderPanel(name: "Old Files", icon: "clock.fill")
        }
    }

    /// Visualization area that will host VisualizationContainer when implemented by another agent.
    /// Shows a temporary representation until that view is wired in.
    @ViewBuilder
    private var visualizationPlaceholder: some View {
        if viewModel.tree != nil {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                VStack(spacing: 12) {
                    Image(systemName: viewModel.vizMode.systemImage)
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(viewModel.vizMode.displayName)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Visualization renders here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            ContentUnavailableView("No scan data", systemImage: "questionmark.circle")
        }
    }

    /// Generic placeholder for panels implemented by other agents.
    private func placeholderPanel(name: String, icon: String) -> some View {
        ContentUnavailableView(name, systemImage: icon, description: Text("Panel will be connected when implemented"))
    }

    // MARK: - Error Screen

    private func errorScreen(message: String) -> some View {
        ContentUnavailableView {
            Label("Scan Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await viewModel.rescan() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Go to Folder Sheet

    private var goToFolderSheet: some View {
        VStack(spacing: 16) {
            Text("Go to Folder")
                .font(.headline)

            TextField("Enter path...", text: $viewModel.goToFolderPath)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
                .onSubmit {
                    performGoToFolder()
                }

            HStack {
                Button("Cancel") {
                    viewModel.showGoToFolder = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Go") {
                    performGoToFolder()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.goToFolderPath.isEmpty)
            }
        }
        .padding(24)
    }

    private func performGoToFolder() {
        let path = (viewModel.goToFolderPath as NSString).expandingTildeInPath
        if let tree = viewModel.tree, let vizState = viewModel.vizState {
            // Linear search for the node matching the requested path.
            // FileTree does not expose a path-based index, so we iterate nodes.
            for i in 1...UInt32(tree.nodeCount) {
                if tree.fullPath(of: i) == path {
                    vizState.drillDown(to: i)
                    break
                }
            }
        }
        viewModel.showGoToFolder = false
        viewModel.goToFolderPath = ""
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Volume picker
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(volumeManager.volumes) { vol in
                    Button {
                        viewModel.volume = vol
                        Task { await viewModel.startScan() }
                    } label: {
                        Label(vol.name, systemImage: volumeIcon(for: vol))
                    }
                }
            } label: {
                Label(viewModel.volume?.name ?? "Select Volume", systemImage: "internaldrive")
            }
        }

        // Scan / Stop
        ToolbarItem(placement: .primaryAction) {
            if viewModel.scanState.isScanning {
                Button {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    Task { await viewModel.startScan() }
                } label: {
                    Label("Scan", systemImage: "play.fill")
                }
                .disabled(viewModel.volume == nil)
            }
        }

        // Visualization mode segmented
        ToolbarItem(placement: .principal) {
            Picker("Visualization", selection: $viewModel.vizMode) {
                ForEach(VisualizationMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
        }

        // Size mode
        ToolbarItem {
            Picker("Size", selection: $viewModel.sizeMode) {
                ForEach(SizeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
        }

        // Panel picker
        ToolbarItem {
            Picker("Panel", selection: $viewModel.activePanel) {
                ForEach(ActivePanel.allCases) { panel in
                    Label(panel.displayName, systemImage: panel.systemImage).tag(panel)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
        }

        // Search
        ToolbarItem {
            TextField("Search...", text: $viewModel.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
    }

    // MARK: - Helpers

    private func volumeIcon(for volume: VolumeInfo) -> String {
        switch volume.volumeType {
        case .internal: "internaldrive"
        case .external: "externaldrive"
        case .network: "network"
        case .disk_image: "opticaldisc"
        }
    }
}
