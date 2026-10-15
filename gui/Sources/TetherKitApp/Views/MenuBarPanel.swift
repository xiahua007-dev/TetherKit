import AppKit
import SwiftUI
import TetherKitIPC

/// 菜单栏里的常驻标签。状态详情只在主窗口中显示，避免后台轮询驱动菜单栏重绘。
struct MenuBarLabel: View {
    var body: some View {
        Image(systemName: "network")
    }
}

/// 点开菜单栏项后的小面板。
///
/// 面板只提供入口和退出操作；状态、速率、网卡与地址统一放在主窗口。
struct MenuBarPanel: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            actions
        }
        .padding(Design.Spacing.medium)
        .frame(width: 280)
        // 与主窗口同理：文案来自全局查表，改语言不会让任何 @Observable 属性
        // 「看起来」变了，得靠显式 identity 强制重建。
        .id(model.languageRevision)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.tight) {
            HStack {
                Button(L(.openMainWindow)) {
                    dismiss()
                    presentMainWindow(model, openWindow)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                // 仅菜单栏模式下这块面板是唯一入口，语言开关必须在这里也够得到 ——
                // 否则一个看不懂界面的用户，得先知道「要去 App 菜单」才能改语言，
                // 而在这个模式下 App 菜单只有把窗口开出来才看得见。
                languageMenu

                Button(L(.quit)) {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }

        }
    }

    /// 语言开关。选项写母语名字，不跟随界面语言翻译 —— 见 LanguageMenu 的说明。
    private var languageMenu: some View {
        Menu {
            Picker(L(.languageLabel), selection: Bindable(model).languagePreference) {
                Text(L(.languageSystem)).tag(LanguagePreference.system)
                Text(verbatim: "中文").tag(LanguagePreference.chinese)
                Text(verbatim: "English").tag(LanguagePreference.english)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "globe")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L(.languageLabel))
    }

}
