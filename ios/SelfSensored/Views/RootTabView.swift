import SwiftUI

struct RootTabView: View {
    var body: some View {
        TabView {
            FoodDiaryView()
                .tabItem { Label("Diary", systemImage: "fork.knife") }

            SyncView()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
        }
    }
}

#Preview {
    RootTabView()
}
