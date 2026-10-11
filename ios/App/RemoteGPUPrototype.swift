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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        report.isEditable = false
        report.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        report.text = "RemoteGPU device interop gate\nTap Render Probe. Expect an orange triangle on a dark background."
        let button = UIButton(type: .system)
        button.setTitle("Render Probe", for: .normal)
        button.addTarget(self, action: #selector(render), for: .touchUpInside)
        for item in [display, report, button] {
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
            report.topAnchor.constraint(equalTo: button.bottomAnchor, constant: 12),
            report.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            report.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            report.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    @objc private func render() {
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
