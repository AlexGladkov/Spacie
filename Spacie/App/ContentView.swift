import SwiftUI
import CoreServices

// MARK: - ContentView

/// Root view for a single Spacie window/tab.
///
/// Displays one of three screens depending on the scan state:
/// 1. **Start screen** -- a grid of available volumes when no scan is active.
/// 2. **Scanning screen** -- live progress during a scan.
/// 3. **Results screen** -- visualization and feature panels after a scan completes.
struct ContentView: View {

    var onDismiss: (() -> Void)? = nil

    @State private var viewModel = AppViewModel()
    @State private var showRescanConfirmation = false
    @Environment(VolumeManager.self) private var volumeManager
    @Environment(PermissionManager.self) private var permissionManager
    @Environment(\.openSettings) private var openSettings

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
        .onReceive(NotificationCenter.default.publisher(for: .spacieSaveCacheOnTerminate)) { _ in
            viewModel.saveCurrentStateToCache()
        }
        .sheet(isPresented: $viewModel.showGoToFolder) {
            goToFolderSheet
        }
        .task {
            // Auto-start scan on boot volume when no volume is selected
            try? await Task.sleep(for: .seconds(0.5))
            if viewModel.volume == nil {
                if let bootVol = volumeManager.volumes.first(where: { $0.isBoot }) {
                    viewModel.volume = bootVol
                    await viewModel.startScan()
                }
            }
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

        case .preparing(let message):
            preparingScreen(message: message)

        case .scanning(let progress):
            if progress.phase == .red {
                scanningScreen(progress: progress)
            } else {
                // Yellow phase -- show results screen with approximate data.
                resultsScreen
            }

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

    /// Indeterminate-spinner screen for the pre-scan transition
    /// (cache load, WAL replay, draining a previous run).
    private func preparingScreen(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
            Text(message)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("This may take a few seconds for large volumes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Scanning progress screen shown during Phase 1 (Red) -- fast directory traversal.
    private func scanningScreen(progress: ScanProgress) -> some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)

                Text("Scanning directory structure...")
                    .font(.headline)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 20) {
                        Label(progress.directoriesScanned.formattedCount + " directories", systemImage: "folder")
                        Label(scanElapsed(at: context.date).formattedDuration, systemImage: "clock")
                        if progress.skippedDirectories > 0 {
                            Label(progress.skippedDirectories.formattedCount + " skipped", systemImage: "eye.slash")
                                .foregroundStyle(.orange)
                        }
                    }
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

    /// Wall-clock elapsed time since the scan started.
    private func scanElapsed(at now: Date) -> TimeInterval {
        guard let start = viewModel.scanStartDate else { return 0 }
        return now.timeIntervalSince(start)
    }

    // MARK: - Results Screen

    private var resultsScreen: some View {
        VStack(spacing: 0) {
            // Main panel
            panelContent
                .id(viewModel.activePanel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Info bar
            InfoBarView(viewModel: viewModel)
        }
    }

    // MARK: - Panel Content

    @ViewBuilder
    private var panelContent: some View {
        switch viewModel.activePanel {
        case .visualization:
            visualizationPlaceholder
        case .largeFiles:
            LargeFilesView(
                viewModel: viewModel.largeFilesVM,
                tree: viewModel.tree,
                sizeMode: viewModel.sizeMode
            )
            .onAppear {
                if let tree = viewModel.tree {
                    viewModel.largeFilesVM.refresh(tree: tree, sizeMode: viewModel.sizeMode)
                }
            }
            .onChange(of: viewModel.sizeMode) { _, newMode in
                if let tree = viewModel.tree {
                    viewModel.largeFilesVM.refresh(tree: tree, sizeMode: newMode)
                }
            }
        case .duplicates:
            DuplicateFinderView(
                viewModel: viewModel.duplicateFinderVM,
                dropZoneViewModel: nil,
                tree: viewModel.tree
            )
            .onChange(of: viewModel.scanState) { _, state in
                if case .completed = state, let tree = viewModel.tree {
                    viewModel.duplicateFinderVM.onTreeChanged(tree: tree)
                }
            }
        case .smartCategories:
            placeholderPanel(name: "Smart Categories", icon: "wand.and.stars")
        case .oldFiles:
            placeholderPanel(name: "Old Files", icon: "clock.fill")
        }
    }

    /// Split-layout browser: folder list on the left, file type distribution on the right.
    @ViewBuilder
    private var visualizationPlaceholder: some View {
        if let tree = viewModel.tree, let vizState = viewModel.vizState {
            VStack(spacing: 0) {
                BreadcrumbView(tree: tree, state: vizState)
                Divider()
                StorageBrowserView(
                    tree: tree,
                    state: vizState,
                    sizeMode: viewModel.sizeMode,
                    scanPhase: viewModel.scanPhase,
                    treeVersion: viewModel.treeVersion,
                    onNodeTrashed: { index in viewModel.handleNodeTrashed(index: index) },
                    volumeUsedSpace: viewModel.volume?.usedSpace
                )
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
        viewModel.showGoToFolder = false
        viewModel.goToFolderPath = ""

        // Offload the linear search to a detached task — walking up to 5M
        // nodes on MainActor previously froze the UI for multiple seconds
        // when the user typed a path near the end of the tree.
        guard let tree = viewModel.tree, let vizState = viewModel.vizState else { return }
        guard tree.nodeCount > 0 else { return }
        Task {
            let found: UInt32? = await Task.detached(priority: .userInitiated) {
                let totalCount = UInt32(tree.nodeCount)
                // Check cancellation periodically (every 8K nodes) — not on
                // every iteration to avoid the per-call overhead, but often
                // enough that a Cancel responds within tens of milliseconds
                // even on 5M-node trees.
                var checkCounter: UInt32 = 0
                for i in 1...totalCount {
                    checkCounter &+= 1
                    if checkCounter & 0x1FFF == 0 {
                        if Task.isCancelled { return nil }
                    }
                    if tree.fullPath(of: i) == path {
                        return i
                    }
                }
                return nil
            }.value
            if let found {
                vizState.drillDown(to: found)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Home button (shown when launched from HomeView)
        if let onDismiss {
            ToolbarItem(placement: .navigation) {
                Button(action: onDismiss) {
                    Label("Home", systemImage: "house")
                }
                .help("Return to Home")
            }
        }

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
                    if viewModel.tree != nil {
                        // Already have results — confirm before discarding them.
                        showRescanConfirmation = true
                    } else {
                        Task { await viewModel.startScan() }
                    }
                } label: {
                    Label("Scan", systemImage: "play.fill")
                }
                .disabled(viewModel.volume == nil)
                .confirmationDialog(
                    "Restart scan?",
                    isPresented: $showRescanConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Restart from scratch", role: .destructive) {
                        Task { await viewModel.rescan() }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Discard current results and rescan the disk from scratch?")
                }
            }
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

        // Settings
        ToolbarItem {
            Menu {
                Button("Open Settings...") {
                    openSettings()
                }

                if let volume = viewModel.volume,
                   viewModel.cacheExistsForVolume {
                    Divider()
                    Button("Clear Cache for \"\(volume.name)\"", role: .destructive) {
                        ScanCache(volumeId: volume.id).invalidate()
                        viewModel.resetToIdle()
                    }
                }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .menuIndicator(.hidden)
            .help("Settings")
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
