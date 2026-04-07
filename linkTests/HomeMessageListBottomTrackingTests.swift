//
//  HomeMessageListBottomTrackingTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/7.
//

import XCTest
@testable import link

final class HomeMessageListBottomTrackingTests: XCTestCase {
    func testIsNearBottomReturnsTrueAtThresholdBoundary() {
        XCTAssertTrue(
            HomeMessageListBottomTracking.isNearBottom(
                bottomAnchorMaxY: 520,
                containerHeight: 400
            )
        )
    }

    func testIsNearBottomReturnsFalseBeyondThreshold() {
        XCTAssertFalse(
            HomeMessageListBottomTracking.isNearBottom(
                bottomAnchorMaxY: 521,
                containerHeight: 400
            )
        )
    }
}
