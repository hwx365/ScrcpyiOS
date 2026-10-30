//
//  ContentView.swift
//  ScrcpyiOS
//
//  根据连接状态在「连接页」与「投屏页」之间切换。
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var manager: ConnectionManager

    var body: some View {
        if manager.isConnected {
            ScreenView()
        } else {
            ConnectionView()
        }
    }
}
