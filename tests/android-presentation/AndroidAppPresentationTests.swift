// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

@main
struct AndroidAppPresentationTests {
    static func main() {
        let homes: Set<String> = ["org.lineageos.trebuchet", "com.example.launcher"]
        let installed: Set<String> = ["com.example.app", "com.example.browser", "com.example.launcher"]
        func allowed(_ foreground: String?, settings: Bool = false, launching: Bool = false) -> Bool {
            AndroidAppPresentation.allows(foreground, requested: "com.example.app", homePackages: homes,
                                           installedPackages: installed, allowSettings: settings, launching: launching)
        }
        precondition(AndroidAppPresentation.validPackage("com.example.app_2"))
        for bad in ["", "com.example;reboot", "com.example app", "com.example/Activity", "../app", "app\nfoo"] {
            precondition(!AndroidAppPresentation.validPackage(bad))
        }
        let homeReport = "2 activities found:\norg.lineageos.trebuchet/.Launcher\ncom.example.launcher/com.example.launcher.Home"
        precondition(AndroidAppPresentation.componentPackages(homeReport) == homes)
        let appReport = "  mCurrentFocus=Window{a02ab34 u0 com.example.app/.MainActivity}"
        precondition(AndroidAppPresentation.foregroundPackage(appReport) == "com.example.app")
        precondition(AndroidAppPresentation.foregroundPackage("topResumedActivity=ActivityRecord{ff12 u0 com.example.app/.MainActivity t9}") == "com.example.app")
        precondition(AndroidAppPresentation.foregroundPackage("mResumedActivity: ActivityRecord{ff12 u0 com.example.app/.MainActivity t9}") == "com.example.app")
        precondition(AndroidAppPresentation.foregroundPackage("mCurrentFocus=null\ntopResumedActivity=ActivityRecord{ff12 u0 com.example.app/.MainActivity t9}") == nil)
        precondition(AndroidAppPresentation.foregroundPackage(appReport + "\nmCurrentFocus=Window{def u0 org.lineageos.trebuchet/.Launcher}") == nil)
        precondition(AndroidAppPresentation.foregroundPackage("window service unavailable") == nil)
        precondition(allowed("com.example.app", launching: true))
        precondition(!allowed(nil))
        precondition(!allowed("org.lineageos.trebuchet"))
        precondition(!allowed("com.example.launcher"))
        precondition(!allowed("com.android.launcher3"))
        precondition(allowed("com.android.permissioncontroller", launching: true))
        precondition(allowed("com.google.android.packageinstaller"))
        precondition(allowed("com.android.documentsui"))
        precondition(!allowed("com.android.systemui"))
        precondition(!allowed("com.android.settings"))
        precondition(allowed("com.android.settings", settings: true, launching: true))
        precondition(!allowed("com.example.browser", launching: true))
        precondition(allowed("com.example.browser"))
        precondition(!allowed("com.unknown.app"))
        precondition(!AndroidAppPresentation.allows("com.example.app", requested: "com.example.app", homePackages: [], installedPackages: installed, allowSettings: false, launching: false))
        precondition(AndroidAppPresentation.launchSucceeded(status: 0, output: "Events injected: 1"))
        precondition(AndroidAppPresentation.launchSucceeded(status: 0, output: "Starting: Intent { act=android.settings.APPLICATION_DETAILS_SETTINGS }\nStatus: ok"))
        precondition(!AndroidAppPresentation.launchSucceeded(status: 1, output: "Events injected: 1"))
        for error in ["No activities found to run, monkey aborted.", "Error: Activity class does not exist", "java.lang.SecurityException"] {
            precondition(!AndroidAppPresentation.launchSucceeded(status: 0, output: error))
        }
        print("Android app presentation checks passed (foreground formats, launcher rejection, permission dialogs, app handoffs, launch errors).")
    }
}
