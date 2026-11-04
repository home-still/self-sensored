import SwiftUI

struct FoodDiaryView: View {
    @State private var showingLogger = false

    var body: some View {
        NavigationStack {
            MealHistoryView()
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showingLogger = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Log meal")
                    }
                }
                .sheet(isPresented: $showingLogger) {
                    NavigationStack { MealLogView() }
                }
        }
    }
}

#Preview {
    FoodDiaryView()
}
