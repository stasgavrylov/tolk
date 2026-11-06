import SwiftUI

struct ScreenSwitcher: View {
    @Binding var selection: AppState.Screen

    var body: some View {
        RoundedTabPicker(title: "Screen", choices: AppState.Screen.allCases, selection: $selection) { $0.rawValue }
    }
}
