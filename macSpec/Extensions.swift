//
//  File.swift
//  macSpec
//
//  Created by Milko Daskalov on 31.07.26.
//  Copyright © 2026 Milko Daskalov. All rights reserved.
//


extension Double {
    var noFraction: String {
        self.formatted(.number.precision(.fractionLength(0)))
    }
    var withFraction: String {
        self.formatted(.number.precision(.fractionLength(0...2)))
    }
    var scaled: String {
        self < 1000 ? self.noFraction : (self / 1000).withFraction
    }
    var inMs: String {
        self.scaled.appending(self < 1000 ? " ms" :" s")
    }
    var inHz: String {
        self.scaled.appending(self < 1000 ? " Hz" :" kHz")
    }
}
