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
    let samples = [Float](count: kBufferSize, repeatedValue: 0)
    var offset = 0
    
    func copyTo(result: [Float]) {
        let ofs = offset;
        let destination = UnsafeMutablePointer<Float>(result)
        let length = result.count
        
        if (length <= offset) { // Just copy length items in front of ofs
            let src = UnsafeMutablePointer<Float>(samples) + ofs - length
            let dst = UnsafeMutablePointer<Float>(destination)
            dst.assignFrom(src, count: length)
        } else { // Split
            let tail = length - ofs;
            let src1 = UnsafeMutablePointer<Float>(samples) + kBufferSize - tail
            let dst1 = UnsafeMutablePointer<Float>(destination)
            dst1.assignFrom(src1, count: tail)

            let src2 = UnsafeMutablePointer<Float>(samples)
            let dst2 = UnsafeMutablePointer<Float>(destination) + tail
            dst2.assignFrom(src2, count: ofs)
        }
    }

    func pushSamples(source: UnsafeMutablePointer<Float32>, count: Int) {
        let rest = kBufferSize - offset;
        if (count <= rest) { // There is enough space, just copy past offset
            let src = UnsafeMutablePointer<Float>(source)
            let dst = UnsafeMutablePointer<Float>(samples) + offset
            dst.assignFrom(src, count: count)
            offset += count;
        } else { // Split
            let src1 = UnsafeMutablePointer<Float>(source)
            let dst1 = UnsafeMutablePointer<Float>(samples) + offset
            dst1.assignFrom(src1, count: rest)
            
            let src2 = UnsafeMutablePointer<Float>(source) + rest
            let dst2 = UnsafeMutablePointer<Float>(samples)
            dst2.assignFrom(src2, count: count - rest)
            offset = count - rest;
        }        
    }
}