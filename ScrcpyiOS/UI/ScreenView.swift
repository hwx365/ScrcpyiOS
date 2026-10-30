//
//  ScreenView.swift
//  ScrcpyiOS
//
//  投屏页：底层 Metal 渲染 + 上层透明触摸；顶部工具栏含「键盘」「断开」。
//

import SwiftUI

struct ScreenView: View {
    @EnvironmentObject var manager: ConnectionManager

    var body: some View {
        ZStack {
            ScreenSurfaceRepresentable(manager: manager)
                .edgesIgnoringSafeArea(.all)

            VStack {
                HStack {
                    Button(action: { manager.disconnect() }) {
                        Label("断开", systemImage: "xmark.circle")
                    }
                    Spacer()
                    Text(manager.deviceName.isEmpty ? "投屏中" : manager.deviceName)
                        .font(.caption)
                    Spacer()
                    Button(action: { manager.focusKeyboard() }) {
                        Label("键盘", systemImage: "keyboard")
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial)

                Spacer()

                // 触摸提示
                Text("在画面上直接触摸 / 滑动即可控制安卓")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(6)
                    .background(.black.opacity(0.4))
                    .cornerRadius(6)
                    .padding(.bottom, 20)
            }
        }
    }
}
