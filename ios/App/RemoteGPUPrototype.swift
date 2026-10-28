import UIKit
import Metal
import QuartzCore

@main
final class PrototypeDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ProbeController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class MetalProbeView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

final class ProbeController: UIViewController {
    private let display = MetalProbeView()
    private let report = UITextView()
    private var probe: RGPUIOSurfaceProbe?
    private var controls: [UIButton] = []
    private var nativeBusy = false
    private var capabilityConnection: NativeCapabilityConnection?
    private var remoteDisplayConnection: NativeRemoteDisplayConnection?
    private let remoteDisplayButton = UIButton(type: .system)
    private let testSettingsButton = UIButton(type: .system)
    private let testProfileStore = RemoteGPUTestProfileStore()
    private let frameBadge = UILabel()
    private var displayHeight: NSLayoutConstraint?
    private let connectButton = UIButton(type: .system)
    private var shareControl: UIButton?
    private let rendererQueue = DispatchQueue(label: "org.remotegpu.native-gate", qos: .userInitiated)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        report.isEditable = false
        report.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        report.text = "RemoteGPU device interop gate\nTap Render Probe. Expect an orange triangle on a dark background."
        let button = UIButton(type: .system)
        button.setTitle("Render Probe", for: .normal)
        button.addTarget(self, action: #selector(render), for: .touchUpInside)
        let native = UIButton(type: .system)
        native.setTitle("VirGL Context + Caps", for: .normal)
        native.addTarget(self, action: #selector(nativeCaps), for: .touchUpInside)
        let interop = UIButton(type: .system)
        interop.setTitle("A2.0 VirGL Resource → IOSurface", for: .normal)
        interop.addTarget(self, action: #selector(resourceInterop), for: .touchUpInside)
        let share = UIButton(type: .system)
        shareControl = share
        share.setTitle("Share Report", for: .normal)
        share.addTarget(self, action: #selector(shareReport), for: .touchUpInside)
        connectButton.setTitle("Connect Capability Probe", for: .normal)
        connectButton.addTarget(self, action: #selector(connectCapability), for: .touchUpInside)
        remoteDisplayButton.setTitle("一键测试连接", for: .normal)
        remoteDisplayButton.addTarget(self, action: #selector(quickConnectRemoteDisplay), for: .touchUpInside)
        testSettingsButton.setTitle("测试设置", for: .normal)
        testSettingsButton.showsMenuAsPrimaryAction = true
        testSettingsButton.menu = UIMenu(children: [
            UIAction(title: "配置/更新一键连接") { [weak self] _ in
                self?.presentRemoteForm(remember: true, connectAfterSave: false)
            },
            UIAction(title: "手动连接（不保存 Token）") { [weak self] _ in self?.connectRemoteDisplay() },
            UIAction(title: "清除已保存配置", attributes: .destructive) { [weak self] _ in self?.clearTestProfile() }
        ])
        let remoteRow = UIStackView(arrangedSubviews: [remoteDisplayButton, testSettingsButton])
        remoteRow.axis = .horizontal
        remoteRow.spacing = 16
        remoteRow.alignment = .center
        controls = [button, native, interop, share, connectButton, remoteDisplayButton, testSettingsButton]
        for item in [display, report, button, native, interop, share, connectButton, remoteRow] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            display.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            display.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            display.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            button.topAnchor.constraint(equalTo: display.bottomAnchor, constant: 12),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            native.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 8),
            native.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            interop.topAnchor.constraint(equalTo: native.bottomAnchor, constant: 8),
            interop.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            share.topAnchor.constraint(equalTo: interop.bottomAnchor, constant: 8),
            share.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            connectButton.topAnchor.constraint(equalTo: share.bottomAnchor, constant: 8),
            connectButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            remoteRow.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 8),
            remoteRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            remoteRow.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 8),
            remoteRow.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
            report.topAnchor.constraint(equalTo: remoteRow.bottomAnchor, constant: 12),
            report.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            report.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            report.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        setDisplayAspect(9.0 / 16.0)
        frameBadge.translatesAutoresizingMaskIntoConstraints = false
        frameBadge.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        frameBadge.textColor = .white
        frameBadge.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        frameBadge.text = "No remote PRESENT"
        frameBadge.isHidden = true
        display.addSubview(frameBadge)
        NSLayoutConstraint.activate([
            frameBadge.topAnchor.constraint(equalTo: display.topAnchor, constant: 8),
            frameBadge.leadingAnchor.constraint(equalTo: display.leadingAnchor, constant: 8)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(enteredBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    @objc private func enteredBackground() {
        // A suspended foreground probe cannot attest to an uninterrupted hold.
        remoteDisplayConnection?.stop(reason: "Application backgrounded; foreground hold interrupted")
    }

    private func setDisplayAspect(_ ratio: CGFloat) {
        displayHeight?.isActive = false
        displayHeight = display.heightAnchor.constraint(equalTo: display.widthAnchor, multiplier: ratio)
        displayHeight?.isActive = true
        view.layoutIfNeeded()
    }

    @objc private func connectRemoteDisplay() {
        if let connection = remoteDisplayConnection {
            remoteDisplayButton.isEnabled = false
            connection.stop()
            return
        }
        presentRemoteForm(remember: false, connectAfterSave: true)
    }

    @objc private func quickConnectRemoteDisplay() {
        if remoteDisplayConnection != nil { connectRemoteDisplay(); return }
        guard !nativeBusy else { return }
        do {
            if let saved = try testProfileStore.load() {
                startRemoteDisplay(saved)
            } else {
                presentRemoteForm(remember: true, connectAfterSave: true)
            }
        } catch { report.text = error.localizedDescription }
    }

    private func clearTestProfile() {
        guard !nativeBusy else { return }
        let prompt = UIAlertController(title: "清除测试连接？", message: "仅删除本机保存的配置，不撤销服务端 Token。下次一键连接需要重新配置。", preferredStyle: .alert)
        prompt.addAction(UIAlertAction(title: "取消", style: .cancel))
        prompt.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try self.testProfileStore.clear()
                UserDefaults.standard.removeObject(forKey: "a21.host")
                UserDefaults.standard.removeObject(forKey: "a21.port")
                self.report.text = "本机测试连接已清除；服务端配置未改变。"
            } catch { self.report.text = error.localizedDescription }
        })
        present(prompt, animated: true)
    }

    private func presentRemoteForm(remember: Bool, connectAfterSave: Bool) {
        guard !nativeBusy else { return }
        let saved: RemoteGPUTestProfile?
        do { saved = remember ? try testProfileStore.load() : nil }
        catch { report.text = error.localizedDescription; return }
        let message = remember
            ? "首次设置后即可一键连接。Token 仅保存在本机 Keychain，不写入 IPA/报告或云同步；地址和端口会被记住。测试设置中可清除。TLS 验证和 GPU 渲染路径不变。"
            : "手动 Remote Display，不保存 Token。需要可信 TLS 主机名、UDP 端口和配对 Token。最多16次 PRESENT，无显示读回或视频。"
        let form = UIAlertController(title: remember ? "配置一键测试连接" : "A2.1 Remote Display", message: message, preferredStyle: .alert)
        form.addTextField { field in
            field.placeholder = "Ubuntu TLS hostname"
            field.text = saved?.host ?? UserDefaults.standard.string(forKey: "a21.host") ?? (remember ? "gpu.opencat.cc.cd" : nil)
            field.autocapitalizationType = .none; field.autocorrectionType = .no
        }
        form.addTextField {
            $0.placeholder = "UDP port"
            $0.text = saved.map { String($0.port) } ?? UserDefaults.standard.string(forKey: "a21.port") ?? "4434"
            $0.keyboardType = .numberPad
        }
        form.addTextField {
            $0.placeholder = remember ? "Pairing token (本机 Keychain)" : "Pairing token (不保存)"
            $0.text = saved?.token
            $0.isSecureTextEntry = true
            $0.autocapitalizationType = .none; $0.autocorrectionType = .no
        }
        form.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        form.addAction(UIAlertAction(title: remember ? (connectAfterSave ? "保存并连接" : "保存") : "Connect", style: .default) { [weak self, weak form] _ in
            guard let self, let fields = form?.textFields,
                let host = fields[0].text?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
                let port = UInt16(fields[1].text ?? ""), port != 0,
                let token = fields[2].text, !token.isEmpty else {
                self?.report.text = "Hostname, valid UDP port and pairing token are required."
                return
            }
            do {
                let profile = try RemoteGPUTestProfile(host: host, port: port, token: token)
                if remember { try self.testProfileStore.save(profile) }
                UserDefaults.standard.set(profile.host, forKey: "a21.host")
                UserDefaults.standard.set(String(profile.port), forKey: "a21.port")
                if connectAfterSave { self.startRemoteDisplay(profile) }
                else { self.report.text = "测试连接已保存到本机 Keychain。点击“一键测试连接”开始；未启动网络会话。" }
            } catch { self.report.text = error.localizedDescription }
        })
        present(form, animated: true)
    }

    private func startRemoteDisplay(_ profile: RemoteGPUTestProfile) {
        guard !nativeBusy else { return }
        probe = nil
        setDisplayAspect(1) // Same accepted renderer path for quick AND manual.
        nativeBusy = true
        controls.forEach { $0.isEnabled = false }
        remoteDisplayButton.isEnabled = true
        shareControl?.isEnabled = true
        remoteDisplayButton.setTitle("断开测试连接", for: .normal)
        report.text = "A2.1 INITIALIZING — any previous image is stale, NOT remote evidence. Wait for a numbered remote PRESENT report."
        let connection = NativeRemoteDisplayConnection(host: profile.host, port: profile.port, token: profile.token, layer: display.metalLayer)
        remoteDisplayConnection = connection
        let sessionID = connection.sessionID
        UIApplication.shared.isIdleTimerDisabled = true
        frameBadge.isHidden = false
        frameBadge.text = "PRESENT 0 — waiting (not remote evidence)"
        connection.onDisplayed = { [weak self] frame in
            guard let self, self.remoteDisplayConnection?.sessionID == sessionID else { return }
            self.frameBadge.text = "Metal completed PRESENT \(frame) — verify pixels"
        }
        connection.onReport = { [weak self] text, finished in
            guard let self, self.remoteDisplayConnection?.sessionID == sessionID else { return }
            self.report.text = text
            if finished {
                UIApplication.shared.isIdleTimerDisabled = false
                self.frameBadge.text = "Disconnected — retained image is NOT live evidence"
                self.remoteDisplayConnection = nil
                self.nativeBusy = false
                self.controls.forEach { $0.isEnabled = true }
                self.remoteDisplayButton.setTitle("一键测试连接", for: .normal)
            }
        }
        connection.start()
    }

    @objc private func connectCapability() {
        if let connection = capabilityConnection {
            connectButton.isEnabled = false
            connection.stop()
            return
        }
        guard !nativeBusy else { return }
        let form = UIAlertController(title: "Ubuntu capability probe", message: "Use a hostname/certificate trusted by iOS. UDP port must be reachable. This mode rejects PRESENT and GPU readback.", preferredStyle: .alert)
        form.addTextField { field in
            field.placeholder = "Ubuntu TLS hostname"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        form.addTextField { field in field.placeholder = "UDP port"; field.text = "4433"; field.keyboardType = .numberPad }
        form.addTextField { field in field.placeholder = "Pairing token"; field.isSecureTextEntry = true }
        form.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        form.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak form] _ in
            guard let self, let fields = form?.textFields,
                  let host = fields[0].text?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
                  let portText = fields[1].text, let port = UInt16(portText), port != 0,
                  let token = fields[2].text, !token.isEmpty else {
                self?.report.text = "Hostname, valid UDP port and pairing token are required."
                return
            }
            self.probe = nil
            self.nativeBusy = true
            self.controls.forEach { $0.isEnabled = false }
            self.connectButton.isEnabled = true
            self.connectButton.setTitle("Disconnect Capability Probe", for: .normal)
            let connection = NativeCapabilityConnection(host: host, port: port, token: token)
            self.capabilityConnection = connection
            connection.onReport = { [weak self] text, finished in
                guard let self else { return }
                self.report.text = text
                // Report sharing is safe during a session; it contains no token.
                self.shareControl?.isEnabled = true
                if finished {
                    self.capabilityConnection = nil
                    self.nativeBusy = false
                    self.controls.forEach { $0.isEnabled = true }
                    self.connectButton.setTitle("Connect Capability Probe", for: .normal)
                }
            }
            connection.start()
        })
        present(form, animated: true)
    }

    @objc private func shareReport(_ sender: UIButton) {
        guard let text = report.text, !text.isEmpty else { return }
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = sender
        sheet.popoverPresentationController?.sourceRect = sender.bounds
        present(sheet, animated: true)
    }

    @objc private func nativeCaps() {
        // Terminating EGLDisplay is process-global: diagnostic modes cannot
        // overlap. The native one-shot gate cleans up before it returns.
        guard !nativeBusy else { return }
        frameBadge.isHidden = true
        probe = nil
        nativeBusy = true
        controls.forEach { $0.isEnabled = false }
        report.text = "Initializing native VirGL/ANGLE and collecting capsets…"
        // Cold initialization must not block UIKit. Callbacks and cleanup
        // remain on this same serial renderer queue.
        rendererQueue.async {
            let result = Result { try RGPUVirglProbe.run() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                do { self.report.text = try result.get() }
                catch { self.report.text = "NATIVE GATE FAILED: \(error.localizedDescription)" }
                self.nativeBusy = false
                self.controls.forEach { $0.isEnabled = true }
            }
        }
    }

    @objc private func resourceInterop() {
        guard !nativeBusy else { return }
        frameBadge.isHidden = true
        probe = nil // Tear down the separate local-triangle display first.
        setDisplayAspect(9.0 / 16.0)
        nativeBusy = true
        controls.forEach { $0.isEnabled = false }
        let layer = display.metalLayer
        report.text = "A2.0: generating asymmetric content with VirGL GPU commands, testing shared-context copy…"
        rendererQueue.async {
            let result = RGPURemotePresent.run(layer: layer)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.report.text = result
                self.nativeBusy = false
                self.controls.forEach { $0.isEnabled = true }
            }
        }
    }

    @objc private func render() {
        guard !nativeBusy else { return }
        frameBadge.isHidden = true
        setDisplayAspect(9.0 / 16.0)
        do {
            if probe == nil { probe = try RGPUIOSurfaceProbe(layer: display.metalLayer) }
            try probe?.drawTriangle()
            report.text = probe?.capabilityReport
        } catch {
            report.text = "FAILED: \(error.localizedDescription)"
            probe = nil
        }
    }
}
