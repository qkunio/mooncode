import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.auth.isSignedIn || model.isDemoMode {
                MainView()
                    .task { await model.bootstrap() }
            } else {
                NavigationStack {
                    WelcomeView()
                }
            }
        }
        .animation(.default, value: model.auth.isSignedIn || model.isDemoMode)
    }
}
