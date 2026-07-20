//
//  macSpecApp.swift
//  macSpec
//
//  Created by Milko Daskalov on 21.12.24.
//  Copyright © 2024 Milko Daskalov. All rights reserved.
//

import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct macSpecSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            AppView()
        }
    }
}
