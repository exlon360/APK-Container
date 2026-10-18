// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Parses Android's own foreground reports without changing its launcher or system packages.
/// A missing/ambiguous report is never permission to reveal the whole Android display.
enum AndroidAppPresentation {
    static let systemDialogs: Set<String> = [
        "com.android.permissioncontroller", "com.google.android.permissioncontroller",
        "com.android.packageinstaller", "com.google.android.packageinstaller",
        "com.android.documentsui", "com.google.android.documentsui",
    ]
    static let knownLaunchers: Set<String> = [
        "com.android.launcher", "com.android.launcher3", "org.lineageos.trebuchet",
        "com.google.android.apps.nexuslauncher",
    ]

    static func validPackage(_ package: String) -> Bool {
        package.range(of: #"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$"#,
                      options: .regularExpression) != nil
    }

    static func componentPackages(_ text: String) -> Set<String> {
        let pattern = #"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)/[A-Za-z0-9_.$]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
    }

    static func foregroundPackage(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map(String.init)
        // Window focus includes Android permission dialogs. An explicit null focus stays unknown;
        // do not fall back to an activity that might now be behind the launcher or a lock screen.
        for marker in ["mCurrentFocus=", "topResumedActivity=", "mResumedActivity:"] {
            let matching = lines.filter { $0.contains(marker) }
            guard !matching.isEmpty else { continue }
            let packages = matching.reduce(into: Set<String>()) { $0.formUnion(componentPackages($1)) }
            return packages.count == 1 ? packages.first : nil
        }
        return nil
    }

    static func launchSucceeded(status: Int, output: String) -> Bool {
        let text = output.lowercased()
        return status == 0 && !text.contains("no activities found") && !text.contains("monkey aborted")
            && !text.contains("error:") && !text.contains("exception")
    }

    static func allows(_ foreground: String?, requested: String, homePackages: Set<String>,
                       installedPackages: Set<String>, allowSettings: Bool, launching: Bool) -> Bool {
        guard !homePackages.isEmpty, let foreground,
              !homePackages.contains(foreground), !knownLaunchers.contains(foreground) else { return false }
        if foreground == "com.android.settings" { return allowSettings }
        if foreground == requested || systemDialogs.contains(foreground) { return true }
        // Once the requested app is running, its intents may open another installed app.
        return !launching && installedPackages.contains(foreground)
    }
}
