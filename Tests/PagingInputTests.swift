import AppKit

@main
struct PagingInputTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            if condition {
                print("PASS: \(name)")
            } else {
                failures += 1
                print("FAIL: \(name)")
            }
        }

        let wheel = WheelDetentClassifier()
        check(wheel.feed(lineDelta: 0, pixelDelta: 0) == 0,
              "zero wheel delta never turns a page")
        check(wheel.feed(lineDelta: -40, pixelDelta: -400) == -1
                && wheel.feed(lineDelta: 1, pixelDelta: 10) == 1,
              "large line deltas stay bounded to one page")
        check(wheel.feed(lineDelta: 0, pixelDelta: .nan) == 0
                && wheel.feed(lineDelta: 0, pixelDelta: .infinity) == 0
                && wheel.feed(lineDelta: 0, pixelDelta: 0.0001) == 0,
              "invalid or negligible point deltas cannot turn pages")
        check(wheel.feed(lineDelta: 0, pixelDelta: -13) == -1
                && wheel.feed(lineDelta: 0, pixelDelta: 13) == 1,
              "point-only wheel input preserves its direction")

        typealias Router = AppDelegate.ScrollGestureRouter
        var router = Router()
        let zero = router.decide(phase: [], momentum: [], continuous: false, delta: 0)
        check(!zero.allowsDelta && !zero.wheelMotion,
              "empty discrete events do not enter paging")

        router = Router()
        var deltas: [CGFloat] = []
        for value: CGFloat in [-13, -3, -19, -4] {
            let route = router.decide(phase: [], momentum: [], continuous: true, delta: value)
            if route.allowsDelta { deltas.append(value) }
            check(route.wheelMotion && route.trackpadPath,
                  "continuous mouse movement uses the live page offset")
        }
        check(deltas == [-13, -3, -19, -4],
              "all continuous mouse deltas are forwarded without throttling")
        let wheelEnd = router.decide(phase: .ended, momentum: [], continuous: true, delta: 0)
        let duplicateEnd = router.decide(phase: .ended, momentum: [], continuous: true, delta: -1)
        check(wheelEnd.postEnd && wheelEnd.gestureEnded && !duplicateEnd.postEnd,
              "a continuous mouse gesture settles once and ignores duplicate ends")

        router = Router()
        let firstWheelDelta = router.decide(phase: [], momentum: [], continuous: true, delta: -13)
        let laterWheelDelta = router.decide(phase: [], momentum: [], continuous: true, delta: -6)
        check(firstWheelDelta.wheelMotion && laterWheelDelta.wheelMotion
                && laterWheelDelta.allowsDelta,
              "later deltas in one interpolated wheel stream keep following the pointer")

        router = Router()
        let changed = router.decide(phase: .changed, momentum: [],
                                    continuous: true, delta: -20)
        check(changed.trackpadPath && changed.allowsDelta && !changed.wheelMotion,
              "a trackpad entering mid-gesture remains continuous")

        router = Router()
        _ = router.decide(phase: .began, momentum: [], continuous: true, delta: -20)
        let inertia = router.decide(phase: [], momentum: .began,
                                    continuous: true, delta: -8)
        check(inertia.postEnd && !inertia.allowsDelta && !inertia.wheelMotion,
              "momentum settles an active trackpad if its end was missed")

        router = Router()
        _ = router.decide(phase: .began, momentum: [], continuous: true, delta: -20)
        _ = router.decide(phase: [], momentum: [], continuous: false, delta: -1)
        let switchedDevice = router.decide(phase: [], momentum: [],
                                           continuous: true, delta: -8)
        check(switchedDevice.wheelMotion && switchedDevice.allowsDelta,
              "switching devices does not retain a trackpad latch")

        router = Router()
        _ = router.decide(phase: .mayBegin, momentum: [], continuous: true, delta: 0)
        let began = router.decide(phase: .began, momentum: [], continuous: true, delta: -8)
        let moved = router.decide(phase: .changed, momentum: [], continuous: true, delta: -50)
        let end = router.decide(phase: .ended, momentum: [], continuous: true, delta: -3)
        let repeated = router.decide(phase: .ended, momentum: [], continuous: true, delta: -3)
        check(began.allowsDelta && moved.allowsDelta && end.allowsDelta
                && end.postEnd && !end.cancelled && !repeated.postEnd,
              "standard trackpad input forwards the final delta and settles once")

        router = Router()
        _ = router.decide(phase: .began, momentum: [], continuous: true, delta: -80)
        let cancelled = router.decide(phase: .cancelled, momentum: [],
                                      continuous: true, delta: -30)
        check(cancelled.postEnd && cancelled.cancelled && !cancelled.allowsDelta
                && !cancelled.wheelMotion,
              "a cancelled trackpad returns to its page without extra displacement")

        var inertiaDeltas = 0
        for phase: NSEvent.Phase in [.began, .changed, .changed, .ended] {
            let route = router.decide(phase: [], momentum: phase, continuous: true, delta: -18)
            inertiaDeltas += route.allowsDelta ? 1 : 0
            check(!route.allowsDelta, "momentum \(phase.rawValue) never forwards movement")
        }
        check(inertiaDeltas == 0,
              "momentum after cancellation never turns or settles another page")
        let nextGesture = router.decide(phase: [], momentum: [], continuous: true, delta: 10)
        check(nextGesture.wheelMotion && nextGesture.allowsDelta,
              "a new interpolated gesture works immediately after momentum")
        router = Router()
        check(router.decide(phase: [], momentum: [], continuous: true, delta: -8).wheelMotion,
              "resetting on window reopen admits the first new wheel gesture")

        router = Router()
        var alternating: [CGFloat] = []
        for value: CGFloat in [-14, -12, 0, 11, 15, 0, -16] {
            let route = router.decide(phase: [], momentum: [], continuous: true, delta: value)
            if route.allowsDelta { alternating.append(value) }
            if value == 0 {
                _ = router.decide(phase: .ended, momentum: [], continuous: true, delta: 0)
            }
        }
        check(alternating == [-14, -12, 11, 15, -16],
              "continuous movement follows reversals in both directions")

        router = Router()
        let discrete = (0..<3).map { _ in
            router.decide(phase: [], momentum: [], continuous: false, delta: -1)
        }
        check(discrete.allSatisfy { $0.allowsDelta && !$0.trackpadPath && !$0.wheelMotion },
              "rapid discrete wheel steps remain independent")

        let curves = [CGFloat(0), 0.7, 1]
        check(curves.allSatisfy { strength in
            abs(jellyProgress(0, jelly: strength)) < 0.000001
                && abs(jellyProgress(1, jelly: strength) - 1) < 0.000001
        }, "the existing jelly animation still begins and ends at exact page positions")

        let forward = advancePagingOffset(page: 0, pageCount: 5,
                                          offset: -2.4, stride: 1)
        check(forward.page == 2 && abs(forward.offset + 0.4) < 0.000001,
              "continuous forward input carries excess movement across pages")
        let backward = advancePagingOffset(page: 3, pageCount: 5,
                                           offset: 2.2, stride: 1)
        check(backward.page == 1 && abs(backward.offset - 0.2) < 0.000001,
              "continuous reverse input carries excess movement across pages")
        let lowerBound = advancePagingOffset(page: 0, pageCount: 5,
                                            offset: 3, stride: 1)
        check(lowerBound.page == 0 && lowerBound.offset == 1,
              "continuous input remains bounded at the first page")
        check(pagingSettleThreshold(stride: 1000) == 40,
              "short continuous gestures settle after four percent travel")
        check(wheelPagingDelta(steps: -1, stride: 1000) == 520
                && wheelPagingDelta(steps: 1, stride: 1000) == -520,
              "discrete wheel detents map to signed live page movement")
        check(pagingSettleDuration(fromScroll: true, wheelMotion: true) == 0.26
                && pagingSettleDuration(fromScroll: true, wheelMotion: false) == 0.26
                && pagingSettleDuration(fromScroll: false, wheelMotion: false) == 0.26,
              "mouse wheel, trackpad, and drag use the same settle timing")

        let apps = [
            AppItem(id: "wechat", name: "微信", bundleID: "com.tencent.xinWeChat",
                    path: "/Applications/WeChat.app", isFolder: false,
                    folderItems: nil, category: "社交"),
            AppItem(id: "xcode", name: "Xcode", bundleID: "com.apple.dt.Xcode",
                    path: "/Applications/Xcode.app", isFolder: false,
                    folderItems: nil, category: "开发者工具"),
        ]
        let searchLayout = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("launchpad-search-\(UUID().uuidString).json")
        let searchStore = LaunchpadStore(layoutFile: searchLayout, apps: apps,
                                         autoRefresh: false)
        searchStore.searchText = "社交"
        check(searchStore.visibleItems.map(\.id) == ["app:wechat"],
              "category names find programs in that category")
        searchStore.searchText = ""
        searchStore.selectedCategory = "开发者工具"
        searchStore.searchText = "微信"
        check(searchStore.visibleItems.isEmpty,
              "search respects the selected category")
        searchStore.selectedCategory = nil
        check(searchStore.visibleItems.map(\.id) == ["app:wechat"],
              "all category searches every program")

        if failures != 0 {
            print("\(failures) paging input checks failed")
            exit(1)
        }
        print("All paging input checks passed")
    }
}
