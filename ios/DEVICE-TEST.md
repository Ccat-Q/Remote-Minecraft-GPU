# Device acceptance: native renderer gates

The available test device is user-reported iPhone 17 / iOS 27.0.1, with external
IPA signing available. Build only in GitHub Actions; do not compile on Ubuntu.
Physical execution is pending and must not be inferred from a successful build.

1. Obtain the unsigned IPA from **Build iOS interop prototype**, using a
   successful **Build iOS renderer sysroot** built with the non-GBM external-EGL
   cleanup fix. Sign the complete app, including embedded EGL, GLESv2,
   virglrenderer.1 and epoxy.0 frameworks, using your provisioning method.
2. Install and launch. Tap **Render Probe**. Expect an orange triangle on a dark
   background. Record any missing/corrupt image or reported ANGLE/IOSurface error.
3. Tap **VirGL Context + Caps**. Controls are disabled while the renderer runs
   on its own serial queue. Expect a native context/caps PASS report with host
   GL/GLSL/renderer strings and capsets 1 and 2, including full base64 dumps.
4. Tap **Share Report** to copy/export the complete report (a screenshot alone
   truncates capsets). Repeat the native gate five times and switch back to
   **Render Probe**; both modes must still work without a crash. Repetition
   exercises initialization and ownership cleanup but does not measure leaks.
5. Return the full reports, triangle observation, device/OS versions and any
   crash log. Actual sustained resource/memory and GPU validation requires
   device profiling later; these one-shot diagnostics do not establish it.

This package does not connect to Ubuntu or display remote frames. A successful
host/native diagnostic does **not** pass guest GL 3.2 Core: the following gate
must connect Mesa virpipe from Ubuntu and create that exact Core context through
the iPhone renderer. Only then proceed to remote triangle presentation and
Minecraft. No JVM/Minecraft launcher should be installed inside this app.
