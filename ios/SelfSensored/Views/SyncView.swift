import HealthKit
import SwiftUI

struct SyncView: View {
    @StateObject private var syncEngine = SyncEngine.shared
    @StateObject private var hkManager = HKManager.shared

    /// Types that should still be visible — hide done/skipped rows with a delay for animation.
    private var activeTypes: [HKSampleType] {
        HKTypes.allSampleTypes.filter { type in
            guard let s = syncEngine.typeStatus[type.identifier] else {
                // No status yet — show if never synced, hide if previously synced
                return SyncState.shared.lastSync(for: type.identifier) == nil
            }
            switch s {
            case .done, .skipped: return false
            default: return true
            }
        }
    }

    private var stalledBannerText: String? {
        let snap = syncEngine.queueSnapshot
        guard snap.isStalled else { return nil }
        if let last = snap.lastSuccessAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let phrase = formatter.localizedString(for: last, relativeTo: Date())
            return "Sync stalled — last successful upload \(phrase). Tap to retry."
        }
        return "Sync stalled — no uploads have succeeded yet. Tap to retry."
    }

    var body: some View {
        NavigationStack {
            List {
                if let stalledText = stalledBannerText {
                    Section {
                        Button {
                            Task { await syncEngine.syncAll() }
                        } label: {
                            Label(stalledText, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                        .disabled(syncEngine.isSyncing)
                    }
                }

                // MARK: - Status Section
                Section("Status") {
                    HStack {
                        Text("HealthKit")
                        Spacer()
                        Text(hkManager.isAuthorized ? "Authorized" : "Not Authorized")
                            .foregroundStyle(hkManager.isAuthorized ? .green : .secondary)
                    }

                    if syncEngine.isSyncing {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Syncing")
                                Spacer()
                                Text("\(syncEngine.typesCompleted)/\(syncEngine.typesTotal) types")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(
                                value: syncEngine.typesTotal > 0
                                    ? Double(syncEngine.typesCompleted) / Double(syncEngine.typesTotal)
                                    : 0
                            )
                            .tint(.blue)
                        }
                    } else {
                        HStack {
                            Text("Sync")
                            Spacer()
                            Text("Idle")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = syncEngine.lastError {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                // MARK: - Sync Button
                Section {
                    Button {
                        Task { await syncEngine.syncAll() }
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(syncEngine.isSyncing || !hkManager.isAuthorized)
                }

                // MARK: - Data Types with Progress
                Section("Data Types") {
                    ForEach(activeTypes, id: \.identifier) { type in
                        TypeProgressRow(
                            typeId: type.identifier,
                            status: syncEngine.typeStatus[type.identifier]
                        )
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: activeTypes.map(\.identifier))
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("AppLogo")
                            .resizable()
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Self Sensored")
                            .font(.headline)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                    }
                }
            }
        }
    }
}

// MARK: - Per-Type Progress Row

struct TypeProgressRow: View {
    let typeId: String
    let status: TypeSyncStatus?

    private var displayName: String {
        typeId
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutType", with: "Workouts")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                statusIcon
                    .frame(width: 16, height: 16)
                Text(displayName)
                    .font(.caption)
                    .lineLimit(1)
                Spacer()
                statusLabel
                    .frame(minWidth: 80, alignment: .trailing)
            }

            ProgressView(value: barProgress)
                .tint(progressColor)
                .animation(.easeInOut(duration: 0.3), value: barProgress)
        }
        .padding(.vertical, 2)
    }

    private var barProgress: Double {
        guard let status else { return 0 }
        return status.progress
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .done(let synced):
            Image(systemName: synced > 0 ? "checkmark.circle.fill" : "checkmark.circle")
                .foregroundStyle(.green)
                .font(.caption)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .reading, .syncing:
            ProgressView()
                .controlSize(.mini)
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        case nil:
            if SyncState.shared.lastSync(for: typeId) != nil {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let status {
            Text(status.label)
                .font(.caption2)
                .foregroundStyle(status.isDone ? .secondary : .primary)
                .monospacedDigit()
        } else if let lastSync = SyncState.shared.lastSync(for: typeId) {
            Text(lastSync, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("Never")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var progressColor: Color {
        guard let status else { return .blue }
        switch status {
        case .reading: return .blue
        case .syncing: return .green
        case .error: return .red
        default: return .blue
        }
    }
}

#Preview {
    SyncView()
}
