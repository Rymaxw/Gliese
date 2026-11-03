//
//  TabButton.swift
//  Gliese
//
//  Gliese Team
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    let onClick: () -> Void
    
    var body: some View {
        Button(action: onClick) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
