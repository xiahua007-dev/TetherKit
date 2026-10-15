import SwiftUI
import TetherKitIPC

/// 按需打开的吞吐与日志窗口。
///
/// 这两块内容会频繁变化，而且 Charts 与日志列表都需要参与布局；独立出来后，
/// 主窗口只负责连接控制，详情窗口关闭时也停止对应的数据轮询。
struct DetailsWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: Design.Spacing.gutter) {
                ThroughputCard(model: model)
                LogCard(model: model)
            }
            .padding(Design.Spacing.medium)
        }
        .frame(minWidth: 560, minHeight: 620)
        .background(.background)
        .id(model.languageRevision)
        .task {
            model.start()
        }
        .onAppear {
            model.detailsWindowDidAppear()
        }
        .onDisappear {
            model.detailsWindowDidDisappear()
        }
    }
}
