import AppKit
import SwiftUI

// システムの Dock やメニューと同じ AppKit のガラスを使う
struct LiquidGlassView: NSViewRepresentable {
    var style: NSGlassEffectView.Style = .regular
    // 非公開のガラスの種類。3 が macOS の Dock と同じ見た目になる（実測で比較）
    var variant: Int?
    var cornerRadius: CGFloat
    var tint: NSColor?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let v = NSGlassEffectView()
        v.contentView = NSView()
        return v
    }

    func updateNSView(_ v: NSGlassEffectView, context: Context) {
        if v.style != style { v.style = style }
        if v.responds(to: NSSelectorFromString("set_variant:")) {
            v.setValue(variant ?? 0, forKey: "_variant")
        }
        if v.cornerRadius != cornerRadius { v.cornerRadius = cornerRadius }
        if v.tintColor != tint { v.tintColor = tint }
    }
}

struct FrostedView: NSViewRepresentable {
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.layer?.cornerRadius = cornerRadius
    }
}

// Dock・プレビュー・ウィジェット・設定画面で共通に使うガラス
struct AppGlass: View {
    var cornerRadius: CGFloat
    // Dock 以外（パネル・ウィジェット・設定）は文字を読みやすくするため少し不透明にする
    var isDock = false
    @Environment(DockSettings.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tint = settings.tintStrength > 0 ? NSColor(settings.tint.opacity(settings.tintStrength)) : nil
        ZStack {
            switch settings.material {
            case .liquidGlass:
                LiquidGlassView(style: .regular, variant: 3, cornerRadius: cornerRadius, tint: tint)
            case .clearGlass:
                LiquidGlassView(style: .clear, cornerRadius: cornerRadius, tint: tint)
            case .frosted:
                FrostedView(cornerRadius: cornerRadius)
                if settings.tintStrength > 0 { shape.fill(settings.tint.opacity(settings.tintStrength * 0.6)) }
            case .solid:
                shape.fill(settings.tint.opacity(0.3 + settings.tintStrength * 0.7))
            }
        }
        .overlay {
            if !isDock {
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0.32 : 0.28))
            }
        }
        // ダークモードでは Dock の背景を少し透けさせる
        .opacity(scheme == .dark && isDock ? 1 - settings.darkTransparency : 1)
    }
}

struct DockSurface: View {
    var cornerRadius: CGFloat
    var highlighted = false
    @Environment(DockSettings.self) private var settings

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        AppGlass(cornerRadius: cornerRadius, isDock: true)
            .overlay {
                if settings.borderWidth > 0 {
                    shape.strokeBorder(settings.tint.mix(with: .white, by: 0.5).opacity(settings.borderOpacity), lineWidth: settings.borderWidth)
                }
                if highlighted { shape.strokeBorder(.white.opacity(0.6), lineWidth: 1.5) }
            }
            .compositingGroup()
            .shadow(color: .black.opacity(settings.shadowStrength * 0.5), radius: 18 * settings.shadowStrength, y: 6 * settings.shadowStrength)
    }
}
