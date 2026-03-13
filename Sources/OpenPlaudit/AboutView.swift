/// About window — project information, privacy rationale, firmware warning.

import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                Text("♪")
                    .font(.system(size: 36))
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenPlaudit")
                        .font(.title2.bold())
                    Text("v0.2.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Privacy rationale
            Text("Why this exists")
                .font(.headline)

            Text("""
                OpenPlaudit exists because of privacy and security concerns about \
                cloud-based recording storage. The official PLAUD app uploads recordings \
                to remote servers for processing. This tool keeps everything local — \
                recordings never leave your machine.
                """)
                .font(.body)

            Text("""
                If cloud storage is not a concern for you, use the official PLAUD app. \
                It is better supported and will not break with firmware updates.
                """)
                .font(.body)
                .foregroundStyle(.secondary)

            Divider()

            // Firmware warning
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("""
                    This tool is built on a reverse-engineered BLE protocol. \
                    Any firmware update to the PLAUD Note can break compatibility \
                    without warning. There is no affiliation with PLAUD Inc.
                    """)
                    .font(.callout)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Spacer()

            // Footer
            HStack {
                Text("By Ram Sundaram")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("MIT License")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 420, height: 380)
    }
}
