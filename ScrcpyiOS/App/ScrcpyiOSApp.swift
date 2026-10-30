//
//  ScrcpyiOSApp.swift
//  ScrcpyiOS
//
//  应用入口。仅做自签部署，不处理任何 App Store 上架逻辑。
//

import SwiftUI

@main
struct ScrcpyiOSApp: App {
    @StateObject private var manager = ConnectionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
        }
    }
}
