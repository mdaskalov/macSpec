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
 
    func applicationDidFinishLaunching(aNotification: NSNotification) {
        // Insert code here to initialize your application
        AudioInputHandler.sharedInstance().start()
        AudioInput.sharedInstance.start()
    }

    func applicationWillTerminate(aNotification: NSNotification) {
        // Insert code here to tear down your application
        AudioInputHandler.sharedInstance().stop()
        AudioInput.sharedInstance.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(sender: NSApplication) -> Bool {
        return true
    }

}

