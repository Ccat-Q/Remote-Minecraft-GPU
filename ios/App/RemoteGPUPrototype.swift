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
        controls = [button, native, interop, share, connectButton]
        for item in [display, report, button, native, interop, share, connectButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            display.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            display.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            display.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            display.heightAnchor.constraint(equalTo: display.widthAnchor, multiplier: 9.0 / 16.0),
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
            report.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 12),
            report.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            report.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            report.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
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
        probe = nil // Tear down the separate local-triangle display first.
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
