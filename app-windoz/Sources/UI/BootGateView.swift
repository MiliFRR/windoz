// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz — diagnostic-build gate screen.
//
// Shows the previous session's boot trace before any store or engine code
// runs, so a launch crash can be located from a single screenshot of the
// bottom lines. Temporary: the next build removes this screen once the
// crash is understood.

import SwiftUI
import UIKit

struct BootGateView: View {
    var onContinue: () -> Void

    @State private var logText = BootTrace.tail()
    @State private var copied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                Text("Windoz — diagnostic build")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("This build logs every launch step. The previous session's log is below — if the app bounced back to the home screen, screenshot the bottom lines before continuing.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                ScrollView {
                    Text(logText.isEmpty
                         ? "(no entries yet — this is the first launch of this build)"
                         : logText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .defaultScrollAnchor(.bottom)

                HStack(spacing: 14) {
                    Button {
                        onContinue()
                    } label: {
                        Text("Continue to Windoz")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)

                    Button(copied ? "Copied" : "Copy log") {
                        UIPasteboard.general.string = logText
                        copied = true
                    }
                    .font(.footnote.weight(.semibold))

                    Button("Clear") {
                        BootTrace.clear()
                        logText = BootTrace.tail()
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                }
            }
            .padding(18)
        }
        .onAppear { BootTrace.mark("gate shown") }
    }
}
