//
//  RingBuffer.swift
//  macSpec
//
//  Created by Milko Daskalov on 05.08.16.
//  Copyright © 2016 Milko Daskalov. All rights reserved.
//

import Foundation

let kBufferSize = 1024 * 16

class RingBuffer: NSObject {
    let samples = [Float](repeating: 0, count: kBufferSize)
    var offset = 0
    
    func copyTo(_ result: [Float]) {
        let ofs = offset;
        let destination = UnsafeMutablePointer<Float>(mutating: result)
        let length = result.count
        
        if (length <= offset) { // Just copy length items in front of ofs
            let src = UnsafeMutablePointer<Float>(mutating: samples) + ofs - length
            let dst = UnsafeMutablePointer<Float>(destination)
            dst.assign(from: src, count: length)
        } else { // Split
            let tail = length - ofs;
            let src1 = UnsafeMutablePointer<Float>(mutating: samples) + kBufferSize - tail
            let dst1 = UnsafeMutablePointer<Float>(destination)
            dst1.assign(from: src1, count: tail)

            let src2 = UnsafeMutablePointer<Float>(mutating: samples)
            let dst2 = UnsafeMutablePointer<Float>(destination) + tail
            dst2.assign(from: src2, count: ofs)
        }
    }

    @objc func pushSamples(_ source: UnsafeMutablePointer<Float32>, count: Int) {
        let rest = kBufferSize - offset;
        if (count <= rest) { // There is enough space, just copy past offset
            let src = UnsafeMutablePointer<Float>(source)
            let dst = UnsafeMutablePointer<Float>(mutating: samples) + offset
            dst.assign(from: src, count: count)
            offset += count;
        } else { // Split
            let src1 = UnsafeMutablePointer<Float>(source)
            let dst1 = UnsafeMutablePointer<Float>(mutating: samples) + offset
            dst1.assign(from: src1, count: rest)
            
            let src2 = UnsafeMutablePointer<Float>(source) + rest
            let dst2 = UnsafeMutablePointer<Float>(mutating: samples)
            dst2.assign(from: src2, count: count - rest)
            offset = count - rest;
        }        
    }
}
