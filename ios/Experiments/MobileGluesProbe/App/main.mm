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
    self.title = @"B1.1 MobileGlues (isolated)";
    self.run = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.run setTitle:@"Run Provider + Context Probe" forState:UIControlStateNormal];
    [self.run addTarget:self action:@selector(runProbe) forControlEvents:UIControlEventTouchUpInside];
    UIButton *share = [UIButton buttonWithType:UIButtonTypeSystem];
    [share setTitle:@"Share Full Report" forState:UIControlStateNormal];
    [share addTarget:self action:@selector(shareReport) forControlEvents:UIControlEventTouchUpInside];
    self.report = [[UITextView alloc] init]; self.report.editable = NO;
    self.report.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.report.text = @"Independent process. Does not connect to Ubuntu or replace RemoteGPU.\nRun once, then share the full report. Relaunch this Probe to repeat.\nB1.1 does not verify GLSL 150 or guest OpenGL 3.2.";
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
        URLByAppendingPathComponent:@"RemoteGPU-B11-report.txt"];
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
