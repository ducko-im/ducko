import DuckoCore
import SwiftUI

public struct ContentView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ChatContainerState.self) private var chatContainer
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hasLoaded = false

    public init() {}

    public var body: some View {
        Group {
            if hasLoaded, !environment.accountService.accounts.isEmpty {
                ContactListWindow()
            } else {
                Color.clear
            }
        }
        .task {
            let didLoadAccounts = await (try? environment.accountService.loadAccounts()) != nil
            hasLoaded = true
            // After a failed load every saved tab would count as belonging to no account and be dropped for good.
            if didLoadAccounts {
                let reopensChatWindow = chatContainer.restoreTabs()
                if reopensChatWindow {
                    openWindow(id: "chat")
                }
            }
            if environment.accountService.accounts.isEmpty {
                openWindow(id: "welcome")
                dismissWindow(id: "contacts")
            } else {
                await environment.accountService.connectEnabledAccountsOnLaunch()
            }
        }
        .onChange(of: environment.accountService.accounts.isEmpty) { _, isEmpty in
            guard hasLoaded else { return }
            if isEmpty {
                openWindow(id: "welcome")
                dismissWindow(id: "contacts")
            }
        }
    }
}
