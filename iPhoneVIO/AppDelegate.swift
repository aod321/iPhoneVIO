//
//  AppDelegate.swift
//  iPhoneVIO
//
//  Created by David Gao on 5/5/24.
//

import UIKit
import SwiftUI

final class LandscapeHostingController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var shouldAutorotate: Bool { false }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .landscapeRight
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Create the SwiftUI view that provides the window contents.
        let contentView = ContentView()

        // Use a UIHostingController as window root view controller.
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = LandscapeHostingController(rootView: contentView)
        self.window = window
        window.makeKeyAndVisible()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Stop Bonjour advertising so mDNS goodbye is sent — Linux detects offline within ~2s
        BonjourManager.shared.stopAdvertising()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Resume Bonjour advertising
        let deviceModel = ViewController.deviceModelIdentifier()
        BonjourManager.shared.startAdvertising(deviceModel: deviceModel)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
    }

    func applicationWillTerminate(_ application: UIApplication) {
        BonjourManager.shared.stopAll()
    }
}
