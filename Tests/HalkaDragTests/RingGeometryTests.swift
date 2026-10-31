import Testing
@testable import HalkaDrag

struct RingGeometryTests {
    let ring = RingGeometry(innerRadius: 40, outerRadius: 120, gapDegrees: 2)

    @Test func deadZoneSelectsNothing() {
        #expect(ring.index(dx: 0, dy: 0, count: 6) == nil)
        #expect(ring.index(dx: 20, dy: 20, count: 6) == nil)
    }

    @Test func noTargetsSelectsNothing() {
        #expect(ring.index(dx: 0, dy: 100, count: 0) == nil)
    }

    @Test func firstWedgeIsCentredAtTwelveOClock() {
        #expect(ring.index(dx: 0, dy: 80, count: 4) == 0)
        #expect(ring.index(dx: 80, dy: 0, count: 4) == 1)   // saat 3
        #expect(ring.index(dx: 0, dy: -80, count: 4) == 2)  // saat 6
        #expect(ring.index(dx: -80, dy: 0, count: 4) == 3)  // saat 9
    }

    @Test func boundariesWrapAround() {
        // 4 dilimde ilk dilim -45°..45°. Biraz solu hâlâ 0, 45°'nin biraz sağı 1.
        #expect(ring.index(dx: -10, dy: 80, count: 4) == 0)
        #expect(ring.index(dx: 81, dy: 80, count: 4) == 1)
        #expect(ring.index(dx: -81, dy: 80, count: 4) == 3)
    }

    @Test func outsideOuterRadiusStillSelects() {
        #expect(ring.index(dx: 0, dy: 500, count: 3) == 0)
    }

    @Test func singleTargetCoversEverything() {
        #expect(ring.index(dx: 0, dy: -90, count: 1) == 0)
        #expect(ring.span(of: 0, count: 1) == (-180, 180))
    }

    @Test func spanLeavesGap() {
        let span = ring.span(of: 1, count: 4)
        #expect(span.start == 46 && span.end == 134)
    }

    @Test func labelCentreSitsMidRing() {
        let c = ring.center(of: 0, count: 4)
        #expect(abs(c.x) < 1e-9 && abs(c.y - 80) < 1e-9)
    }
}
