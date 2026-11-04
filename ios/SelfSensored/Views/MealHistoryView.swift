import SwiftUI

@MainActor
struct MealHistoryView: View {
    @State private var entries: [MealHistoryEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if entries.isEmpty && !isLoading {
                ContentUnavailableView(
                    "No meals yet",
                    systemImage: "fork.knife",
                    description: Text("Voice-log a meal and it'll show up here.")
                )
            }

            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.mealType)
                            .font(.caption.bold())
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.rawText)
                        .font(.subheadline)
                        .lineLimit(3)
                    if let kcal = entry.totals.caloriesKcal {
                        Text("\(Int(kcal)) kcal")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
                .padding(.vertical, 4)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .navigationTitle("Meal History")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await APIClient.shared.mealHistory().items
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { MealHistoryView() }
}
