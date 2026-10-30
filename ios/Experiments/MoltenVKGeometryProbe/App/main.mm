#import <UIKit/UIKit.h>
#import "Probe.h"

@interface GeometryController : UIViewController
@property(nonatomic, strong) UITextView *report;
@property(nonatomic, strong) UIButton *run;
@end
@implementation GeometryController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Isolated Vulkan Geometry";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.run = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.run setTitle:@"Run Strict Geometry Probe (once)" forState:UIControlStateNormal];
    [self.run addTarget:self action:@selector(runProbe) forControlEvents:UIControlEventTouchUpInside];
    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    [share setTitle:@"Share Report + Features + Images" forState:UIControlStateNormal];
    [share addTarget:self action:@selector(shareReport) forControlEvents:UIControlEventTouchUpInside];
    self.report = [UITextView new]; self.report.editable = NO;
    self.report.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    NSURL *saved = [RGPUGeometryReportDirectory() URLByAppendingPathComponent:@"report.txt"];
    self.report.text = [NSString stringWithContentsOfURL:saved encoding:NSUTF8StringEncoding error:nil] ?:
        @"Independent MoltenVK process. No ANGLE, MobileGlues, VirGL or network.\nReports actual features/limits first. Geometry tests are BLOCKED if advertised limits do not permit them. No capability override.\nGPU readback is diagnostic only. No GL3.2/Zink/guest acceptance. Keep RemoteGPU installed.\nIf the app crashes, relaunch and Share the retained partial report before running again.";
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.run, share, self.report]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8]]];
}
- (void)runProbe {
    self.run.enabled = NO;
    self.report.text = @"Running. Partial report is persisted in Files → RemoteGPU Geometry. Do not background the app.";
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *report = RGPURunGeometryProbe();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.report.text = report; UIApplication.sharedApplication.idleTimerDisabled = NO;
        });
    });
}
- (void)shareReport {
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:RGPUGeometryReportDirectory()
        includingPropertiesForKeys:nil options:0 error:nil];
    if (!files.count) return;
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = self.view;
    [self presentViewController:sheet animated:YES completion:nil];
}
@end
@interface GeometryDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation GeometryDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[GeometryController new]];
    [self.window makeKeyAndVisible]; return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(GeometryDelegate.class)); }
}
