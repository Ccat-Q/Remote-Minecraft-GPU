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
        remoteDisplayButton.setTitle("Connect Remote Display", for: .normal)
        remoteDisplayButton.addTarget(self, action: #selector(connectRemoteDisplay), for: .touchUpInside)
        controls = [button, native, interop, share, connectButton, remoteDisplayButton]
        for item in [display, report, button, native, interop, share, connectButton, remoteDisplayButton] {
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
            remoteDisplayButton.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 8),
            remoteDisplayButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            report.topAnchor.constraint(equalTo: remoteDisplayButton.bottomAnchor, constant: 12),
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
        guard !nativeBusy else { return }
        let form = UIAlertController(title: "A2.1 Remote Display", message: "Trusted TLS hostname, UDP port and pairing token. Run the A1 64×64 GL demo on Ubuntu. Max 16 PRESENTs; no readback or video.", preferredStyle: .alert)
        form.addTextField { field in
            field.placeholder = "Ubuntu TLS hostname"
            field.text = UserDefaults.standard.string(forKey: "a21.host")
            field.autocapitalizationType = .none; field.autocorrectionType = .no
        }
        form.addTextField {
            $0.placeholder = "UDP port"
            $0.text = UserDefaults.standard.string(forKey: "a21.port") ?? "4434"
            $0.keyboardType = .numberPad
        }
        form.addTextField {
            $0.placeholder = "Pairing token (never saved)"; $0.isSecureTextEntry = true
            $0.autocapitalizationType = .none; $0.autocorrectionType = .no
        }
        form.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        form.addAction(UIAlertAction(title: "Connect", style: .default) { [weak self, weak form] _ in
            guard let self, let fields = form?.textFields,
                let host = fields[0].text?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
                let port = UInt16(fields[1].text ?? ""), port != 0,
                let token = fields[2].text, !token.isEmpty else {
                self?.report.text = "Hostname, valid UDP port and pairing token are required."
                return
            }
            guard token == token.trimmingCharacters(in: .whitespacesAndNewlines) else {
                self.report.text = "Pairing token has leading/trailing whitespace. Remove it and reconnect; token was NOT changed or logged."
                return
            }
            UserDefaults.standard.set(host, forKey: "a21.host")
            UserDefaults.standard.set(String(port), forKey: "a21.port")
            self.probe = nil
            self.setDisplayAspect(1) // A1 is square; do not stretch the triangle.
            self.nativeBusy = true
            self.controls.forEach { $0.isEnabled = false }
            self.remoteDisplayButton.isEnabled = true
            self.shareControl?.isEnabled = true
            self.remoteDisplayButton.setTitle("Disconnect Remote Display", for: .normal)
            self.report.text = "A2.1 INITIALIZING — any previous image is stale, NOT remote evidence. Wait for a numbered remote PRESENT report."
            let connection = NativeRemoteDisplayConnection(host: host, port: port, token: token, layer: self.display.metalLayer)
            self.remoteDisplayConnection = connection
            let sessionID = connection.sessionID
            UIApplication.shared.isIdleTimerDisabled = true
            self.frameBadge.isHidden = false
            self.frameBadge.text = "PRESENT 0 — waiting (not remote evidence)"
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
                    self.remoteDisplayButton.setTitle("Connect Remote Display", for: .normal)
                }
            }
            connection.start()
        })
        present(form, animated: true)
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
