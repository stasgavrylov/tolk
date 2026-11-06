import SwiftUI

/// Explicit rounded rectangles avoid the capsule chrome macOS applies to native tab/toolbar pickers.
struct RoundedTabPicker<Selection: Hashable>: View {
    let title: String
    let choices: [Selection]
    @Binding var selection: Selection
    let label: (Selection) -> String

    var body: some View {
        HStack(spacing: 1) {
            ForEach(choices, id: \.self) { choice in
                Button { selection = choice } label: {
                    Text(label(choice))
                        .font(.system(size: 12, weight: selection == choice ? .semibold : .regular))
                        .foregroundStyle(selection == choice ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(SegmentStyle(selected: selection == choice))
            }
        }
        .padding(2)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
        .onMoveCommand { direction in
            guard let index = choices.firstIndex(of: selection) else { return }
            switch direction {
            case .left: selection = choices[max(0, index - 1)]
            case .right: selection = choices[min(choices.count - 1, index + 1)]
            default: break
            }
        }
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(choices, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }

    private struct SegmentStyle: ButtonStyle {
        let selected: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? Color(nsColor: .textBackgroundColor) : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.07 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.primary.opacity(selected ? 0.10 : 0))
                }
        }
    }
}
