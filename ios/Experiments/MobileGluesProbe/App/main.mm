#import <UIKit/UIKit.h>
#import "Probe.h"

@interface ProbeController : UIViewController
@property(nonatomic, strong) UITextView *report;
@property(nonatomic, strong) UIButton *run;
@end
@implementation ProbeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.run = [UIButton buttonWithType:UIButtonTypeSystem];
#if RGPU_B12_RASTER_PROBE
    self.title = @"B1.2c Depth / Stencil / Blend";
    [self.run setTitle:@"Run Depth / Stencil / Blend Probe" forState:UIControlStateNormal];
#elif RGPU_B12_FEATURE_PROBE
    self.title = @"B1.2b Instancing + Sync";
    [self.run setTitle:@"Run Instancing + Sync Probe" forState:UIControlStateNormal];
#elif RGPU_B12_SHADER_PROBE
    self.title = @"B1.2a GLSL150 (isolated)";
    [self.run setTitle:@"Run GLSL150 + Dynamic Output Probe" forState:UIControlStateNormal];
#else
    self.title = @"B1.1 MobileGlues (isolated)";
    [self.run setTitle:@"Run Provider + Context Probe" forState:UIControlStateNormal];
#endif
    [self.run addTarget:self action:@selector(runProbe) forControlEvents:UIControlEventTouchUpInside];
    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    [share setTitle:@"Share Full Report" forState:UIControlStateNormal];
    [share addTarget:self action:@selector(shareReport) forControlEvents:UIControlEventTouchUpInside];
    self.report = [[UITextView alloc] init]; self.report.editable = NO;
    self.report.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
#if RGPU_B12_RASTER_PROBE
    self.report.text = @"Separate B1.2c bundle. B1.1/B1.2a/B1.2b regressions run first, then four actual depth, stencil and separate RGB/Alpha blending outputs.\nNot full raster conformance, GL3.2, Texture Buffer, Geometry, cross-context sync or performance acceptance. Run once and Share Full Report.";
#elif RGPU_B12_FEATURE_PROBE
    self.report.text = @"Separate B1.2b bundle. B1.1/B1.2a regressions run first, then 4/2/0 instance draws and same-context Fence completion before pixel checks.\nNo full GL3.2, cross-context ordering, slow-GPU cancellation or performance verdict. Run once per process and Share Full Report.";
#elif RGPU_B12_SHADER_PROBE
    self.report.text = @"Independent B1.2a bundle. Keeps accepted B1.1 and RemoteGPU installed.\nRuns context regression then actual GLSL150 vertex/fragment translation, compile/link and three dynamic FBO outputs.\nRemaining feature gates and guest GL3.2 are NOT tested. Run once and share Full Report. Relaunch to repeat.";
#else
    self.report.text = @"Independent process. Does not connect to Ubuntu or replace RemoteGPU.\nRun once, then share the full report. Relaunch this Probe to repeat.\nB1.1 does not verify GLSL 150 or guest OpenGL 3.2.";
#endif
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.run, share, self.report]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8]]];
}
- (void)runProbe {
    self.run.enabled = NO; self.report.text = @"Running isolated one-shot initialization/context checks…";
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *result = RGPURunMobileGluesProbe();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.report.text = result; UIApplication.sharedApplication.idleTimerDisabled = NO;
        });
    });
}
- (void)shareReport {
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
#if RGPU_B12_RASTER_PROBE
        URLByAppendingPathComponent:@"RemoteGPU-B12c-report.txt"];
#elif RGPU_B12_FEATURE_PROBE
        URLByAppendingPathComponent:@"RemoteGPU-B12b-report.txt"];
#elif RGPU_B12_SHADER_PROBE
        URLByAppendingPathComponent:@"RemoteGPU-B12a-report.txt"];
#else
        URLByAppendingPathComponent:@"RemoteGPU-B11-report.txt"];
#endif
    NSError *error = nil;
    if (![self.report.text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error]) return;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view;
    [self presentViewController:share animated:YES completion:nil];
}
@end
@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation ProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[[ProbeController alloc] init]];
    [self.window makeKeyAndVisible]; return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeDelegate.class)); }
}
