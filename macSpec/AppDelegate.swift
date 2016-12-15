//
//  AppDelegate.swift
//  macSpec
//
//  Created by Milko Daskalov on 26.07.16.
//  Copyright © 2016 Milko Daskalov. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
 
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
        AudioInputHandler.sharedInstance().start()
        AudioInput.sharedInstance.start()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        AudioInputHandler.sharedInstance().stop()
        AudioInput.sharedInstance.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

}

