//
//  LogView.swift
//  ScrcpyiOS
//
//  简单的调试日志视图（黑底绿字，自动滚动到底部）。
//

import SwiftUI

struct LogView: View {
    @EnvironmentObject var manager: ConnectionManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(manager.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.green)
                    }
                }
                .padding(6)
                .id("logBottom")
            }
            .background(Color.black)
            .onChange(of: manager.logLines.count) { _ in
                withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
            }
        }
    }
}
