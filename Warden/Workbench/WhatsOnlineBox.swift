import SwiftUI
import WorkbenchKit

/// Bottom-left "What's online" box, as in the old app: each resident model with its host and ready state, the
/// router status, and the host thermals (GPU/CPU temperature, GPU clock) with the time of the last sample.
struct WhatsOnlineBox: View {
    @ObservedObject private var hub = WorkbenchHub.shared

    private var endpoint: String {
        let url = Workbench.routerBaseURL
        return "\(url.host ?? "127.0.0.1"):\(url.port.map(String.init) ?? "")"
    }

    var body: some View {
        let ready = hub.residentModels.filter(\.ready).count
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("WHAT'S ONLINE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(ready) of \(hub.residentModels.count) ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(hub.residentModels) { model in
                HStack(spacing: 7) {
                    dot(model.ready)
                    Text(model.title).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(model.host).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.caption)
            }
            ForEach(HostThermals.hosts, id: \.self) { host in
                if let t = hub.thermals[host] {
                    VStack(alignment: .leading, spacing: 1) {
                        t.parts.reduce(Text("\(host)").foregroundColor(.secondary)) { line, part in
                            line + Text(" · ").foregroundColor(.secondary) + Text(part.text).foregroundColor(part.level.color)
                        }
                        .lineLimit(2)
                        Text("sampled \(t.sampledAt.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                } else {
                    Text("\(host) · thermals: reading…")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Divider()
            HStack(spacing: 7) {
                dot(hub.routerOnline == true)
                Text(hub.routerOnline == nil ? "router checking" : (hub.routerOnline == true ? "router online" : "router offline"))
                Spacer()
                Text(endpoint).foregroundStyle(.tertiary)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("WhatsOnlineBox")
    }

    private func dot(_ on: Bool) -> some View {
        Circle()
            .fill(on ? Color.green : Color.clear)
            .overlay(Circle().stroke(on ? Color.clear : Color.secondary, lineWidth: 1.2))
            .frame(width: 7, height: 7)
    }
}

extension ThermalLevel {
    var color: Color {
        switch self {
        case .normal: return .green
        case .elevated: return .orange
        case .high: return .red
        }
    }
}
