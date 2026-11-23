import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeloCore

struct DownloadsPanel: View {
    @Bindable var model: DownloadModel
    let openPreferences: () -> Void
    let openBrowserPreferences: () -> Void

    @State private var search = ""
    @State private var anchor: UUID?
    @State private var deletion: DownloadDeletion?
    @State private var showLink = false
    @State private var scope: DownloadScope = .all
    @State private var fileKind = "All Types"
    @State private var sidebar = true
    @State private var inspector = false
    @State private var showCompactInspector = false
    @State private var sort: SortField = .date
    @State private var ascending = false
    @State private var samples: [Double] = Array(repeating: 0, count: 44)
    @State private var confirmClear = false
    @FocusState private var listFocused: Bool

    private let ticker = Timer.publish(every: 0.8, on: .main, in: .common).autoconnect()

    private var visible: [Transfer] {
        let filtered = model.userTransfers.filter {
            scope.includes($0) && matchesType($0) && (search.isEmpty ||
                $0.displayName.localizedStandardContains(search) ||
                $0.sourceURL?.host?.localizedStandardContains(search) == true)
        }
        let sorted: [Transfer]
        switch sort {
        case .date: sorted = filtered.sorted { $0.createdAt < $1.createdAt }
        case .name: sorted = filtered.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .status: sorted = filtered.sorted { statusRank($0.state) < statusRank($1.state) }
        case .size: sorted = filtered.sorted { $0.total < $1.total }
        case .speed: sorted = filtered.sorted { $0.speed < $1.speed }
        }
        return ascending ? sorted : sorted.reversed()
    }

    private var selected: Set<UUID> {
        get { model.selectedDownloads }
        nonmutating set { model.selectedDownloads = newValue }
    }

    private var selection: [Transfer] { model.userTransfers.filter { selected.contains($0.id) } }

    private var monthStats: (bytes: Int64, count: Int) {
        let calendar = Calendar.current
        let now = Date()
        return model.userTransfers.reduce(into: (Int64(0), 0)) { result, item in
            guard item.state == .completed,
                  calendar.isDate(item.finishedAt ?? item.updatedAt, equalTo: now, toGranularity: .month) else { return }
            result.0 += max(item.received, item.total)
            result.1 += 1
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            layout
                .task(id: model.terminalSelection) {
                    let ids = model.terminalSelection
                    guard let first = ids.first else { return }
                    scope = .all
                    search = ""
                    fileKind = "All Types"
                    anchor = first
                    listFocused = true
                    DispatchQueue.main.async {
                        guard model.terminalSelection == ids else { return }
                        proxy.scrollTo(first, anchor: .center)
                        model.clearTerminalSelection(ids)
                    }
                }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showLink) { AddDownloadsView(model: model) }
        .sheet(isPresented: $showCompactInspector) {
            VStack(spacing: 0) {
                inspectorPane
                Divider()
                Button("Done") { showCompactInspector = false }
                    .buttonStyle(VDSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(14)
            }
            .frame(width: 440, height: 468)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(item: $deletion) { request in DeleteDownloadsView(ids: request.ids, model: model) }
        .alert("Clear Finished History?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                for transfer in model.userTransfers where transfer.state.terminal {
                    model.removeHistory(transfer)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded files will stay on disk.")
        }
        .onChange(of: model.userTransfers.map(\.id)) { _, ids in selected.formIntersection(ids) }
        .onReceive(ticker) { _ in
            samples.append(Double(model.rate))
            if samples.count > 44 { samples.removeFirst(samples.count - 44) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, urls.allSatisfy(Transfer.supports) else { return false }
            do { try model.addLinks(urls.map(\.absoluteString).joined(separator: "\n")); return true }
            catch { model.notice = error.localizedDescription; return false }
        }
    }

    private var layout: some View {
        GeometryReader { geometry in
            let canDockInspector = geometry.size.width >= 940
            let showsInspector = inspector && canDockInspector
            let canDockSidebar = geometry.size.width >= (showsInspector ? 1240 : 980)
            let showRates = visible.contains { $0.state == .downloading }
            VStack(spacing: 0) {
                topBar(canDockSidebar: canDockSidebar)
                Divider().overlay(VD.hairline)
                HStack(spacing: 0) {
                    if sidebar && canDockSidebar {
                        DownloadSidebar(model: model, scope: Binding(get: { scope }, set: setScope), monthStats: monthStats)
                            .frame(width: 196)
                        Divider().overlay(VD.hairline)
                    }
                    content(showsSidebar: sidebar && canDockSidebar, canDockInspector: canDockInspector, showRates: showRates)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsInspector {
                        Divider().overlay(VD.hairline)
                        inspectorPane
                            .frame(width: 294)
                    }
                }
                Divider().overlay(VD.hairline)
                statusBar
            }
        }
    }

    private func setScope(_ value: DownloadScope) {
        guard scope != value else { return }
        scope = value
        selected.removeAll()
        anchor = nil
    }

    private func setSearch(_ value: String) {
        guard search != value else { return }
        search = value
        selected.removeAll()
        anchor = nil
    }

    // MARK: - Top bar

    private func topBar(canDockSidebar: Bool) -> some View {
        HStack(spacing: 12) {
            if canDockSidebar {
                VDIconButton(symbol: "sidebar.left", help: "Toggle Sidebar") { sidebar.toggle() }
            }
            BrandMark(size: 30)
            Text("VeloDrop")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 8)
            searchField
            Button {
                showLink = true
            } label: {
                Label("New Download", systemImage: "plus")
            }
            .buttonStyle(VDPrimaryButtonStyle())
            .keyboardShortcut("n")
            VDIconButton(symbol: "gearshape", help: "Settings", action: openPreferences)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea(edges: .top))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search Downloads", text: Binding(get: { search }, set: setSearch))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !search.isEmpty {
                Button {
                    setSearch("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 210, height: 28)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(VD.hairline, lineWidth: 0.8)
        )
    }

    // MARK: - Content

    private func content(showsSidebar: Bool, canDockInspector: Bool, showRates: Bool) -> some View {
        VStack(spacing: 0) {
            contentHeader(showsSidebar: showsSidebar, canDockInspector: canDockInspector)
            if let notice = model.notice {
                noticeBanner(notice)
            }
            if visible.isEmpty {
                emptyState
            } else {
                columnHeader(showRates: showRates)
                downloadList(showRates: showRates)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func contentHeader(showsSidebar: Bool, canDockInspector: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if showsSidebar {
                    Text(scope.title).font(.system(size: 21, weight: .bold))
                } else {
                    scopeMenu
                }
                Text("\(visible.count) downloads")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(SortField.allCases) { field in
                    Button {
                        chooseSort(field)
                    } label: {
                        Label(field.title, systemImage: sort == field ? (ascending ? "chevron.up" : "chevron.down") : "")
                    }
                }
            } label: {
                pillMenuLabel(Text(sort.title), symbol: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Menu {
                ForEach(["All Types", "Documents", "Images", "Video", "Archives"], id: \.self) { kind in
                    Button {
                        fileKind = kind
                        selected.removeAll()
                    } label: {
                        if fileKind == kind { Label(LocalizedStringKey(kind), systemImage: "checkmark") }
                        else { Text(LocalizedStringKey(kind)) }
                    }
                }
            } label: {
                pillMenuLabel(Text(LocalizedStringKey(fileKind)), symbol: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            if !selected.isEmpty {
                Button {
                    deletion = DownloadDeletion(ids: selected)
                } label: {
                    Label("Delete Selected…", systemImage: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(VD.red)
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(VD.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            VDIconButton(symbol: canDockInspector ? "sidebar.right" : "info.circle", help: "Download Details") {
                if canDockInspector {
                    inspector.toggle()
                } else {
                    showCompactInspector = true
                }
            }
            .disabled(visible.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var scopeMenu: some View {
        Menu {
            ForEach(DownloadScope.allCases) { category in
                Button { setScope(category) } label: {
                    Label(category.title, systemImage: scope == category ? "checkmark" : category.symbol)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(scope.title).font(.system(size: 21, weight: .bold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Download Categories")
    }

    private func pillMenuLabel(_ title: Text, symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            title
                .font(.system(size: 11, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                .strokeBorder(VD.hairline, lineWidth: 0.8)
        )
    }

    private func columnHeader(showRates: Bool) -> some View {
        HStack(spacing: ColumnMetrics.spacing) {
            sortHeader("Name", field: .name, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeader("Status", field: .status, alignment: .leading)
                .frame(width: ColumnMetrics.status, alignment: .leading)
            sortHeader("Size", field: .size, alignment: .trailing)
                .frame(width: ColumnMetrics.size, alignment: .trailing)
            if showRates {
                sortHeader("Speed", field: .speed, alignment: .trailing)
                    .frame(width: ColumnMetrics.speed, alignment: .trailing)
                Text("Remaining")
                    .frame(width: ColumnMetrics.remaining, alignment: .trailing)
            }
            Color.clear
                .frame(width: ColumnMetrics.actions)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 24)
    }

    private func sortHeader(_ title: LocalizedStringKey, field: SortField, alignment: Alignment) -> some View {
        Button {
            chooseSort(field)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sort == field {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(sort == field ? .primary : .secondary)
    }

    private func downloadList(showRates: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(visible) { item in
                    DownloadRow(
                        transfer: item,
                        model: model,
                        selected: selected.contains(item.id),
                        selectedIDs: selected,
                        showRates: showRates,
                        deleteIDs: { ids in deletion = DownloadDeletion(ids: ids) },
                        select: { modifiers in select(item, modifiers: modifiers) },
                        open: {
                            if item.state == .awaitingConfirmation { model.askToConfirm(item) }
                            else { model.onProgress?(item.id) }
                        }
                    )
                    .id(item.id)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.escape) {
            guard !selected.isEmpty else { return .ignored }
            selected.removeAll()
            return .handled
        }
        .onKeyPress(.return) {
            if selection.count == 1, let item = selection.first {
                if item.state == .awaitingConfirmation { model.askToConfirm(item) }
                else { model.onProgress?(item.id) }
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "a"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selected = Set(visible.map(\.id))
            return .handled
        }
        .onDeleteCommand {
            if !selected.isEmpty { deletion = DownloadDeletion(ids: selected) }
        }
        .accessibilityLabel("Download list")
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(VD.orange)
            Text(notice)
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer()
            Button {
                model.notice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(VD.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(VD.orange.opacity(0.18), lineWidth: 0.8)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        let libraryEmpty = model.userTransfers.isEmpty
        return VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(VD.accent.opacity(0.07))
                    .frame(width: 96, height: 96)
                Circle()
                    .strokeBorder(VD.accent.opacity(0.10), lineWidth: 1)
                    .frame(width: 76, height: 76)
                BrandMark(size: 50)
            }
            .padding(.bottom, 4)
            Text(libraryEmpty ? "No downloads yet" : "No matching downloads")
                .font(.system(size: 16, weight: .semibold))
            Text(libraryEmpty
                 ? "Add a link or download a file from your browser."
                 : "Try a different category, search, or file type.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            if libraryEmpty {
                HStack(spacing: 8) {
                    Button {
                        showLink = true
                    } label: {
                        Label("New Download", systemImage: "plus")
                    }
                    .buttonStyle(VDPrimaryButtonStyle())
                    Button("Browser Settings…", action: openBrowserPreferences)
                        .buttonStyle(VDSecondaryButtonStyle())
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 20)
    }

    private var inspectorPane: some View {
        Group {
            if selection.count == 1, let item = selection.first {
                TransferInspector(transfer: item, model: model)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Select a download to see its details.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 180)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(model.activeCount > 0 ? VD.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
                .shadow(color: model.activeCount > 0 ? VD.green.opacity(0.6) : .clear, radius: 3)
            Text(model.activeCount > 0 ? "\(model.activeCount) active" : "No active downloads")
                .monospacedDigit()
            if model.activeCount > 0 {
                SpeedSparkline(samples: samples)
                Text(Format.compactRate(model.rate))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(VD.accent)
                    .monospacedDigit()
            }
            Spacer(minLength: 10)
            if !selected.isEmpty {
                Text("\(selected.count) selected")
                    .monospacedDigit()
            }
            Divider().frame(height: 12)
            VDIconButton(symbol: "folder", help: "Downloads folder", size: 22) {
                NSWorkspace.shared.open(URL(fileURLWithPath: model.defaultFolder))
            }
            Menu {
                if model.userTransfers.contains(where: { $0.state.running }) {
                    Button("Pause All") {
                        for item in model.userTransfers where item.state.running { model.pause(item) }
                    }
                }
                if model.userTransfers.contains(where: { $0.state == .paused && $0.url != nil }) {
                    Button("Resume All") {
                        for item in model.userTransfers where item.state == .paused { model.resume(item) }
                    }
                }
                if model.userTransfers.contains(where: { $0.state.running || ($0.state == .paused && $0.url != nil) }) {
                    Divider()
                }
                if model.userTransfers.contains(where: { $0.state.terminal }) {
                    Button("Clear Finished History…") { confirmClear = true }
                    Divider()
                }
                Button("Quit VeloDrop") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Interaction

    private func chooseSort(_ field: SortField) {
        if sort == field {
            ascending.toggle()
        } else {
            sort = field
            ascending = field == .name
        }
    }

    private func select(_ item: Transfer, modifiers: EventModifiers) {
        listFocused = true
        if modifiers.contains(.command) {
            if selected.contains(item.id) { selected.remove(item.id) }
            else { selected.insert(item.id) }
            anchor = item.id
        } else if modifiers.contains(.shift), let anchor,
                  let from = visible.firstIndex(where: { $0.id == anchor }),
                  let to = visible.firstIndex(where: { $0.id == item.id }) {
            selected = Set(visible[min(from, to)...max(from, to)].map(\.id))
        } else {
            selected = [item.id]
            anchor = item.id
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !visible.isEmpty else { return }
        listFocused = true
        let current = selected.first.flatMap { id in visible.firstIndex(where: { $0.id == id }) }
        let next = min(max((current ?? (delta > 0 ? -1 : visible.count)) + delta, 0), visible.count - 1)
        selected = [visible[next].id]
        anchor = visible[next].id
    }

    private func statusRank(_ state: TransferState) -> Int {
        switch state {
        case .downloading: 0
        case .queued: 1
        case .awaitingConfirmation: 2
        case .paused: 3
        case .failed: 4
        case .completed: 5
        case .handedToBrowser: 6
        case .canceled: 7
        }
    }

    private func matchesType(_ item: Transfer) -> Bool {
        guard fileKind != "All Types" else { return true }
        guard let type = UTType(filenameExtension: (item.displayName as NSString).pathExtension) else { return false }
        switch fileKind {
        case "Images": return type.conforms(to: .image)
        case "Video": return type.conforms(to: .movie)
        case "Archives": return type.conforms(to: .archive) || type.conforms(to: .diskImage)
        default: return type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .content)
        }
    }
}

// MARK: - Column layout

private enum ColumnMetrics {
    static let spacing: CGFloat = 13
    static let status: CGFloat = 94
    static let size: CGFloat = 74
    static let speed: CGFloat = 86
    static let remaining: CGFloat = 70
    static let actions: CGFloat = 70
}

private enum SortField: String, CaseIterable, Identifiable {
    case date, name, status, size, speed
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .date: "Newest"
        case .name: "Name"
        case .status: "Status"
        case .size: "Size"
        case .speed: "Speed"
        }
    }
}

private struct DownloadDeletion: Identifiable {
    let id = UUID()
    let ids: Set<UUID>
}

private enum DownloadScope: String, CaseIterable, Identifiable {
    case all, active, waiting, paused, completed, attention
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All Downloads"
        case .active: "In progress"
        case .waiting: "Waiting"
        case .paused: "Paused"
        case .completed: "Finished"
        case .attention: "Needs Attention"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.down.circle"
        case .waiting: "clock"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .attention: "exclamationmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .all: VD.accent
        case .active: VD.accent
        case .waiting: VD.purple
        case .paused: VD.orange
        case .completed: VD.green
        case .attention: VD.red
        }
    }

    func includes(_ item: Transfer) -> Bool {
        switch self {
        case .all: true
        case .active: item.state == .downloading
        case .waiting: item.state == .queued || item.state == .awaitingConfirmation
        case .paused: item.state == .paused
        case .completed: item.state.terminal && item.state != .failed
        case .attention: item.state == .failed
        }
    }
}

// MARK: - Sidebar

private struct DownloadSidebar: View {
    let model: DownloadModel
    @Binding var scope: DownloadScope
    let monthStats: (bytes: Int64, count: Int)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionEyebrow(text: "Library")
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 7)
            VStack(spacing: 2) {
                ForEach(DownloadScope.allCases) { category in
                    SidebarRow(category: category,
                               count: model.userTransfers.filter(category.includes).count,
                               selected: scope == category) {
                        scope = category
                    }
                }
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 12)
            monthlyCard
                .padding(10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(VD.sidebar)
    }

    private var monthlyCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: "This Month")
            Text(Format.bytes(monthStats.bytes))
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(monthStats.count) finished")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(VD.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(VD.hairline, lineWidth: 0.8)
        )
    }
}

private struct SidebarRow: View {
    let category: DownloadScope
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: category.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Color.white : category.tint)
                    .frame(width: 17)
                Text(category.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 4)
                Text(count > 0 ? "\(count)" : "—")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(VD.accentGradient)
                        .shadow(color: VD.accent.opacity(0.22), radius: 4, x: 0, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Download row

private struct DownloadRow: View {
    let transfer: Transfer
    let model: DownloadModel
    let selected: Bool
    let selectedIDs: Set<UUID>
    let showRates: Bool
    let deleteIDs: (Set<UUID>) -> Void
    let select: (EventModifiers) -> Void
    let open: () -> Void
    @State private var hovering = false
    private var showsProgress: Bool { transfer.state == .downloading || transfer.state == .paused }

    var body: some View {
        HStack(spacing: ColumnMetrics.spacing) {
            HStack(spacing: 10) {
                FileIconTile(transfer: transfer, size: showsProgress ? 36 : 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(transfer.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if (transfer.priority ?? 0) > 0 {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(VD.orange)
                                .help("High")
                        }
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(transfer.state == .failed ? VD.red.opacity(0.9) : .secondary)
                            .lineLimit(1)
                            .monospacedDigit()
                    }
                    if showsProgress {
                        VDProgressBar(fraction: transfer.fraction, tint: transfer.state.tint, height: 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusBadge(state: transfer.state, text: transfer.state.shortStatusKey)
                .frame(width: ColumnMetrics.status, alignment: .leading)
            Text(max(transfer.total, transfer.received) > 0 ? Format.bytes(max(transfer.total, transfer.received)) : "—")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: ColumnMetrics.size, alignment: .trailing)
            if showRates {
                Text(transfer.state == .downloading ? Format.rate(transfer.speed) : "")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(VD.accent)
                    .frame(width: ColumnMetrics.speed, alignment: .trailing)
                Text(transfer.state == .downloading ? transfer.remainingText : "")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: ColumnMetrics.remaining, alignment: .trailing)
            }
            actions
                .frame(width: ColumnMetrics.actions, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? VD.accent.opacity(0.10)
                      : (hovering ? VD.rowHover : Color.primary.opacity(0.022)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(selected ? VD.accent.opacity(0.32) : .clear, lineWidth: 1)
                )
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(selectionGesture)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(([transfer.displayName, transfer.statusText, detail]).filter { !$0.isEmpty }.joined(separator: ", ")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { select([]) }
    }

    private var selectionGesture: some Gesture {
        TapGesture().modifiers(.command).onEnded { select(.command) }
            .exclusively(before: TapGesture().modifiers(.shift).onEnded { select(.shift) })
            .exclusively(before: TapGesture(count: 2).onEnded { open() })
            .exclusively(before: TapGesture().onEnded { select([]) })
    }

    private var detail: String {
        switch transfer.state {
        case .awaitingConfirmation:
            return transfer.sourceBrowser?.name ?? String(localized: "From Browser")
        case .queued:
            return ""
        case .downloading, .paused:
            let percent = transfer.fraction.map { String(format: "%.0f%%", $0 * 100) }
            let connections = transfer.connections > 0
                ? String(localized: "\(transfer.connections) connections") : nil
            return [Format.bytes(transfer.received), percent, connections].compactMap { $0 }.joined(separator: " · ")
        case .completed:
            return [transfer.sourceURL?.host, Format.when(transfer.finishedAt ?? transfer.updatedAt)]
                .compactMap { $0 }.joined(separator: " · ")
        case .failed:
            return transfer.message ?? String(localized: "Download failed")
        case .canceled:
            return ""
        case .handedToBrowser:
            return transfer.message ?? String(localized: "Sent back to the browser.")
        }
    }

    private var actions: some View {
        HStack(spacing: 1) {
            switch transfer.state {
            case .awaitingConfirmation:
                quickButton("checkmark", "Confirm…") { model.askToConfirm(transfer) }
            case .downloading:
                quickButton("pause.fill", "Pause") { model.pause(transfer) }
            case .paused:
                quickButton("play.fill", "Resume") { model.resume(transfer) }
            case .failed where transfer.url != nil:
                quickButton("arrow.clockwise", "Retry") { model.resume(transfer) }
            case .completed:
                quickButton("arrow.up.right.square", "Open File") { model.openFile(transfer) }
                quickButton("folder", "Show in Finder") { model.reveal(transfer) }
            default:
                EmptyView()
            }
            Menu {
                contextMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("Actions for \(transfer.name)")
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if transfer.state == .awaitingConfirmation {
            Button("Confirm…") { model.askToConfirm(transfer) }
        }
        Button("Download Details") { open() }
        if transfer.state == .downloading {
            Button("Pause") { model.pause(transfer) }
        }
        if transfer.state == .paused || (transfer.state == .failed && transfer.url != nil) {
            Button(transfer.state == .paused ? "Resume" : "Retry") { model.resume(transfer) }
        }
        if transfer.state == .completed {
            Divider()
            Button("Open File") { model.openFile(transfer) }
            Button("Show in Finder") { model.reveal(transfer) }
        }
        if transfer.fromBrowser && !transfer.state.terminal {
            Divider()
            Button("Continue in Browser") { model.useBrowser(transfer) }
        }
        if !transfer.state.terminal {
            Button("Cancel download", role: .destructive) { model.cancel(transfer) }
        }
        Divider()
        Button("Delete Selected…", role: .destructive) {
            deleteIDs(selectedIDs.contains(transfer.id) ? selectedIDs : [transfer.id])
        }
    }

    private func quickButton(_ symbol: String, _ help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(hovering ? Color.primary.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

}

// MARK: - Inspector

struct TransferInspector: View {
    let transfer: Transfer
    let model: DownloadModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 11) {
                    FileIconTile(transfer: transfer, size: 50)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(transfer.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        StatusBadge(state: transfer.state, text: transfer.state.shortStatusKey)
                    }
                }

                if transfer.state == .downloading || transfer.state == .paused {
                    progressCard
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                    let size = max(transfer.received, transfer.total)
                    if size > 0 {
                        StatTile(title: "File Size", value: Format.bytes(size), symbol: "externaldrive")
                    }
                    StatTile(title: "Added", value: Format.when(transfer.createdAt),
                             symbol: "calendar")
                    if let finished = transfer.finishedAt, transfer.state == .completed {
                        StatTile(title: "Finished", value: Format.when(finished), symbol: "checkmark.circle")
                    }
                    if let browser = transfer.sourceBrowser {
                        StatTile(title: "Browser", value: browser.name, symbol: "globe")
                    }
                    if transfer.state == .downloading || transfer.state == .paused {
                        StatTile(title: "Connections",
                                 value: "\(transfer.connections) / \(transfer.connectionLimit ?? model.maxConnections)",
                                 symbol: "point.3.connected.trianglepath.dotted")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionEyebrow(text: "Location")
                    Text(transfer.finalPath ?? model.workspace.directory(for: transfer).path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if transfer.state == .completed {
                        HStack(spacing: 6) {
                            Button("Show in Finder") { model.reveal(transfer) }
                                .buttonStyle(VDSecondaryButtonStyle(compact: true))
                            Button("Open File") { model.openFile(transfer) }
                                .buttonStyle(VDSecondaryButtonStyle(compact: true))
                        }
                    }
                }

                if let source = transfer.sourceURL {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionEyebrow(text: "Source")
                        Text(source.host ?? "")
                            .font(.system(size: 11, weight: .medium))
                        Text(source.absoluteString)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                if let message = transfer.message, transfer.state == .failed {
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(VD.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(VD.hairline)

                HStack(spacing: 6) {
                    Button("Download Details") { model.onProgress?(transfer.id) }
                        .buttonStyle(VDSecondaryButtonStyle(compact: true))
                    Spacer()
                    if transfer.state == .downloading {
                        Button("Pause") { model.pause(transfer) }
                            .buttonStyle(VDPrimaryButtonStyle(compact: true))
                    } else if transfer.state == .paused {
                        Button("Resume") { model.resume(transfer) }
                            .buttonStyle(VDPrimaryButtonStyle(compact: true))
                    } else if transfer.state == .awaitingConfirmation {
                        Button("Confirm…") { model.askToConfirm(transfer) }
                            .buttonStyle(VDPrimaryButtonStyle(compact: true))
                    }
                }
            }
            .padding(14)
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(transfer.fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Text(transfer.state == .downloading ? Format.rate(transfer.speed) : "—")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(VD.accent)
                    .monospacedDigit()
            }
            VDProgressBar(fraction: transfer.fraction, tint: transfer.state.tint, height: 6)
            HStack {
                Text(transfer.total > 0
                     ? String(localized: "\(Format.bytes(transfer.received)) of \(Format.bytes(transfer.total))")
                     : Format.bytes(transfer.received))
                Spacer()
                Text(transfer.remainingText)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(11)
        .background(VD.subtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(VD.hairline.opacity(0.6), lineWidth: 0.7)
        )
    }
}

// MARK: - Add downloads

private struct AddDownloadsView: View {
    let model: DownloadModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(VD.accent.opacity(0.10))
                        .frame(width: 46, height: 46)
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(VD.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add Downloads")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Paste one HTTP or HTTPS link per line.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            VStack(alignment: .leading, spacing: 8) {
                PlainTextEditor(text: $text)
                    .frame(height: 170)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(VD.hairline, lineWidth: 0.8)
                    )
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(verbatim: "https://example.com/file.zip\nhttps://example.com/movie.mp4")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Color.secondary.opacity(0.55))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 17)
                                .allowsHitTesting(false)
                        }
                    }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(VD.red)
                }
            }
            .padding(.horizontal, 20)

            Divider().overlay(VD.hairline).padding(.top, 18)
            HStack(spacing: 8) {
                Button {
                    text = NSPasteboard.general.string(forType: .string) ?? ""
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(VDSecondaryButtonStyle())
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(VDSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Start Download") {
                    do { try model.addLinks(text); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(VDPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Delete downloads

private struct DeleteDownloadsView: View {
    let ids: Set<UUID>
    let model: DownloadModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("deleteFilesByDefault") private var defaultFiles = true
    @State private var files = true
    @State private var remember = false
    @State private var deleting = false

    private var items: [Transfer] { model.userTransfers.filter { ids.contains($0.id) } }
    private var fileSizes: [Int64] { items.compactMap(model.deletableFileSize) }
    private var titleKey: LocalizedStringKey { items.count == 1 ? "Delete Download?" : "Delete Downloads?" }

    var body: some View {
        let fileSizes = fileSizes
        let active = items.filter { !$0.state.terminal }.count
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(VD.red.opacity(0.10))
                        .frame(width: 52, height: 52)
                    Image(systemName: "trash")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(VD.red)
                }
                Text(titleKey)
                    .font(.system(size: 17, weight: .semibold))
                VStack(spacing: 3) {
                    Text("\(items.count) history records")
                    if active > 0 {
                        Text("\(active) unfinished downloads will be stopped.")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .padding(.top, 22)
            .padding(.bottom, 18)

            VStack(spacing: 8) {
                if !fileSizes.isEmpty {
                    choice(title: "Delete Files and History",
                           detail: "\(fileSizes.count) files · \(Format.bytes(fileSizes.reduce(0, +))) will be moved to Trash.",
                           symbol: "trash", selected: files) { files = true }
                }
                choice(title: "Delete History Only",
                       detail: "Downloaded files will stay on disk.",
                       symbol: "clock.arrow.circlepath", selected: !files || fileSizes.isEmpty) { files = false }
            }
            .padding(.horizontal, 20)

            if !fileSizes.isEmpty {
                Toggle("Remember this choice", isOn: $remember)
                    .font(.system(size: 11))
                    .padding(.horizontal, 20)
                    .padding(.top, 15)
            }

            Divider().overlay(VD.hairline).padding(.top, 16)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(VDSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    if remember && !fileSizes.isEmpty { defaultFiles = files }
                    deleting = true
                    Task { await model.delete(ids, files: files && !fileSizes.isEmpty); dismiss() }
                }
                .buttonStyle(VDDestructiveButtonStyle())
                .disabled(deleting || items.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { files = defaultFiles }
        .interactiveDismissDisabled(deleting)
    }

    private func choice(title: LocalizedStringKey, detail: LocalizedStringKey,
                        symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? VD.accent : Color.secondary)
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? VD.accent : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(10)
            .background(selected ? VD.accent.opacity(0.07) : Color.primary.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? VD.accent.opacity(0.30) : VD.hairline, lineWidth: 0.8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transfer text

extension Transfer {
    var statusText: String {
        switch state {
        case .awaitingConfirmation: String(localized: "Waiting for confirmation")
        case .queued: String(localized: "Waiting")
        case .downloading: fraction.map { String(format: "%.0f%%", $0 * 100) } ?? String(localized: "Downloading")
        case .paused: String(localized: "Paused")
        case .completed: String(localized: "Completed")
        case .failed: String(localized: "Download failed")
        case .canceled: String(localized: "Canceled")
        case .handedToBrowser: String(localized: "Sent back to the browser.")
        }
    }

    var remainingText: String {
        guard state == .downloading else { return "—" }
        guard speed > 0, total > received else { return String(localized: "Estimating…") }
        let seconds = (total - received) / speed
        return Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
    }
}
