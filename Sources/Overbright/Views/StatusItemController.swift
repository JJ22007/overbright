import AppKit

/// The menu bar icon and its menu. Rebuilt from scratch whenever the config
/// changes, so new presets and languages appear without a restart.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let boostController: BoostController
    private let brightnessKeyService: BrightnessKeyService
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private var toggleItem = NSMenuItem()
    private var statusTextItem = NSMenuItem()
    private var brightnessKeysItem = NSMenuItem()
    private var presetItems: [(item: NSMenuItem, preset: Preset)] = []
    private var percentageLabel = NSTextField(labelWithString: "")
    private var slider = NSSlider()

    init(
        boostController: BoostController,
        brightnessKeyService: BrightnessKeyService
    ) {
        self.boostController = boostController
        self.brightnessKeyService = brightnessKeyService
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.toolTip = AppInfo.name
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        rebuildMenu()

        boostController.onSnapshot = { [weak self] snapshot in
            self?.render(snapshot)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        brightnessKeyService.start()
        render(boostController.snapshot)
    }

    /// Call after the config changes.
    func rebuildMenu() {
        let config = ConfigStore.shared.config
        let problems = ConfigStore.shared.problems
        menu.removeAllItems()

        let titleItem = NSMenuItem(title: AppInfo.name, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        statusTextItem = NSMenuItem()
        statusTextItem.isEnabled = false
        menu.addItem(statusTextItem)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "", action: #selector(toggleBoost), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(makeSliderItem())

        presetItems = config.presets.map { preset in
            let item = NSMenuItem(
                title: "\(preset.name)  \(Self.plain(min(preset.level, config.maxLevel)))%",
                action: #selector(applyPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.name
            menu.addItem(item)
            return (item, preset)
        }

        let restoreItem = NSMenuItem(
            title: L10n.tr("Restore Standard Brightness", "恢复标准亮度"),
            action: #selector(restoreStandardBrightness),
            keyEquivalent: "r"
        )
        restoreItem.target = self
        menu.addItem(restoreItem)

        brightnessKeysItem = NSMenuItem(
            title: "", action: #selector(requestBrightnessKeyAccess), keyEquivalent: ""
        )
        brightnessKeysItem.target = self
        menu.addItem(brightnessKeysItem)

        menu.addItem(.separator())

        if !problems.isEmpty {
            let problemsItem = NSMenuItem(
                title: L10n.tr("Config Problems (\(problems.count))", "配置问题（\(problems.count)）"),
                action: nil,
                keyEquivalent: ""
            )
            let submenu = NSMenu()
            for problem in problems {
                let item = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
            }
            problemsItem.submenu = submenu
            menu.addItem(problemsItem)
        }

        let editItem = NSMenuItem(
            title: L10n.tr("Edit Config File…", "编辑配置文件…"),
            action: #selector(editConfig),
            keyEquivalent: ","
        )
        editItem.target = self
        menu.addItem(editItem)

        let helpItem = NSMenuItem(
            title: L10n.tr("Guide and Source Code", "使用说明与源码"),
            action: #selector(openGuide),
            keyEquivalent: ""
        )
        helpItem.target = self
        menu.addItem(helpItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.tr("Quit Overbright", "退出 Overbright"),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        render(boostController.snapshot)
    }

    private func makeSliderItem() -> NSMenuItem {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 62))

        let caption = NSTextField(labelWithString: L10n.tr("Brightness", "亮度"))
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.frame = NSRect(x: 14, y: 38, width: 140, height: 17)
        container.addSubview(caption)

        percentageLabel = NSTextField(labelWithString: "")
        percentageLabel.alignment = .right
        percentageLabel.textColor = .secondaryLabelColor
        percentageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        percentageLabel.frame = NSRect(x: 190, y: 38, width: 66, height: 17)
        container.addSubview(percentageLabel)

        slider = NSSlider()
        slider.minValue = Double(BoostLevel.minimum)
        slider.maxValue = Double(BoostLevel.cap)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.frame = NSRect(x: 12, y: 8, width: 246, height: 24)
        slider.setAccessibilityLabel(L10n.tr("Boost level", "增亮强度"))
        container.addSubview(slider)

        item.view = container
        return item
    }

    private func render(_ snapshot: BoostSnapshot) {
        let config = ConfigStore.shared.config
        slider.doubleValue = snapshot.level.normalizedSliderValue
        percentageLabel.stringValue = "\(snapshot.level.percentage)%"

        let active = snapshot.state.isRunning
        toggleItem.state = active ? .on : .off
        toggleItem.title = active
            ? L10n.tr("Turn Boost Off", "关闭增亮")
            : L10n.tr("Turn Boost On", "开启增亮")
        let supported = snapshot.potentialEDRHeadroom > 1.05
        toggleItem.isEnabled = active || supported
        slider.isEnabled = supported
        statusTextItem.toolTip = nil

        for (item, preset) in presetItems {
            let target = BoostLevel(Float(preset.level / 100))
            item.isEnabled = supported
            item.state = active && target.percentage == snapshot.level.percentage ? .on : .off
        }

        let symbol: String
        switch snapshot.state {
        case .off:
            symbol = "sun.max.circle"
            statusTextItem.title = supported
                ? L10n.tr("Standard brightness", "标准亮度")
                : L10n.tr("This display has no XDR headroom", "此屏幕不支持增亮")
        case .engaging:
            symbol = "sun.max.circle.fill"
            statusTextItem.title = L10n.tr("Starting…", "正在恢复…")
        case .active:
            symbol = "sun.max.circle.fill"
            statusTextItem.title = L10n.tr("Boost is on", "增亮已开启")
        case let .unavailable(message):
            symbol = "exclamationmark.triangle"
            statusTextItem.title = L10n.tr(
                "Unavailable · turn on to retry", "暂不可用 · 点击开启重试"
            )
            statusTextItem.toolTip = message
        }

        statusItem.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: AppInfo.name
        )
        statusItem.button?.title = config.showPercentage && snapshot.state == .active
            ? "\(snapshot.level.percentage)%"
            : ""
        refreshBrightnessKeyStatus()
    }

    func refreshBrightnessKeyStatus() {
        if !ConfigStore.shared.config.brightnessKeys {
            brightnessKeysItem.title = L10n.tr("F1 / F2 off in config", "F1 / F2 已在配置中关闭")
            brightnessKeysItem.state = .off
            brightnessKeysItem.isEnabled = false
            return
        }
        brightnessKeysItem.isEnabled = true
        if !brightnessKeyService.isTrusted {
            brightnessKeysItem.title = L10n.tr("Allow F1 / F2…", "授权 F1 / F2…")
            brightnessKeysItem.state = .off
        } else if brightnessKeyService.isRunning {
            brightnessKeysItem.title = "F1 / F2"
            brightnessKeysItem.state = .on
        } else {
            brightnessKeysItem.title = L10n.tr("Retry F1 / F2", "重试 F1 / F2")
            brightnessKeysItem.state = .off
        }
    }

    @objc private func toggleBoost() {
        boostController.toggle()
    }

    @objc private func sliderChanged() {
        boostController.setLevelFromUserInteraction(Float(slider.doubleValue))
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let preset = ConfigStore.shared.config.preset(named: name) else { return }
        boostController.setLevelFromUserInteraction(Float(preset.level / 100))
    }

    @objc private func restoreStandardBrightness() {
        boostController.disable()
    }

    @objc private func requestBrightnessKeyAccess() {
        if !brightnessKeyService.isTrusted {
            BrightnessKeyService.requestAccessibilityPermission()
            if let settingsURL = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(settingsURL)
            }
        }
        brightnessKeyService.start()
        refreshBrightnessKeyStatus()
    }

    @objc private func editConfig() {
        NSWorkspace.shared.open(ConfigStore.fileURL)
    }

    @objc private func openGuide() {
        if let url = URL(string: AppInfo.repoURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        boostController.shutdown()
        NSApp.terminate(nil)
    }

    private static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
