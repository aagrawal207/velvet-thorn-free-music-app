//
//  ITagsTests.swift
//  YouTubeKit
//
//  Created by Alexander Eichhorn on 06.09.21.
//

import XCTest
@testable import YouTubeKit

final class ITagsTests: XCTestCase {
    
    func testSampleProfile() {
        guard let itag = ITag(22) else {
            XCTFail()
            return
        }
        
        XCTAssertEqual(itag.videoResolution, 720)
        XCTAssertEqual(itag.audioBitrate, 192)
        XCTAssertEqual(itag.isDash, false)
        XCTAssertFalse(itag.is3D)
        XCTAssertFalse(itag.isHDR)
        XCTAssertFalse(itag.isLive)
    }
    
    func testNonExistentProfile() {
        let itag = ITag(2239)
        XCTAssertNil(itag)
    }

    /// Gana Bajana patch: the 256 kbps audio tiers a signed-in account can receive must survive `Stream(format:)`.
    func testPremiumAudioTiersAreKnownDashAudio() {
        for (code, rate) in [(141, 256), (774, 256), (251, 160), (140, 128)] {
            guard let itag = ITag(code) else { return XCTFail("itag \(code) must be known") }
            XCTAssertEqual(itag.audioBitrate, rate)
            XCTAssertNil(itag.videoResolution)
            XCTAssertTrue(itag.isDash)
        }
    }
    
}
