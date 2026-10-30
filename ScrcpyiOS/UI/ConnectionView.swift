//
//  ConnectionView.swift
//  ScrcpyiOS
//
//  连接页：输入安卓 IP、连接/投屏按钮、实时状态、调试日志。
//

import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject var manager: ConnectionManager

    var body: some View {
        VStack(spacing: 16) {
            Text("Scrcpy iOS 自用客户端")
                .font(.title2)
                .bold()

            TextField("安卓设备 IP（如 192.168.43.1）", text: $manager.ipAddress)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .autocapitalization(.none)
                .disableAutocorrection(true)

            Button(action: { manager.connect() }) {
                Text(manager.status == .connecting ? "连接中…" : "连接并投屏")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.status == .connecting)

            Text("状态：\(manager.status.rawValue)")
                .foregroundColor(.secondary)

            Divider()
            Text("调试日志").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            LogView().frame(maxHeight: .infinity)
        }
        .padding()
    }
}
