import XCTest
import JoseonCore
@testable import JoseonHeadphones

/// Noise dose: NIOSH daily and WHO / ITU-T H.870 weekly, and the time-to-limit readout.
final class SPLDoseTests: XCTestCase {

    // MARK: NIOSH

    /// The criterion itself: 85 dBA for 8 hours is 100 % of the daily dose.
    func testEightHoursAt85IsOneHundredPercent() {
        let estimator = SPLFixture.estimator()
        let reading = SPLFixture.run(estimator, atDBA: 85, seconds: 8 * 3_600, frameSeconds: 60)
        XCTAssertEqual(Double(reading.doseNIOSH), 1.00, accuracy: 0.01)
        XCTAssertEqual(reading.doseSeconds, 8 * 3_600, accuracy: 1e-6)
    }

    /// 3 dB exchange rate: +3 dB halves the allowed time. 4 hours at 88 dBA is also 100 %.
    func testFourHoursAt88IsOneHundredPercent() {
        let estimator = SPLFixture.estimator()
        let reading = SPLFixture.run(estimator, atDBA: 88, seconds: 4 * 3_600, frameSeconds: 60)
        XCTAssertEqual(Double(reading.doseNIOSH), 1.00, accuracy: 0.01)
    }

    /// +9 dB is one eighth of the time: 1 hour at 94 dBA is 100 %.
    func testOneHourAt94IsOneHundredPercent() {
        let estimator = SPLFixture.estimator()
        let reading = SPLFixture.run(estimator, atDBA: 94, seconds: 3_600, frameSeconds: 30)
        XCTAssertEqual(Double(reading.doseNIOSH), 1.00, accuracy: 0.01)
    }

    /// Half the time at the criterion is half the dose — the integral is linear in time.
    func testDoseIsLinearInTime() {
        let estimator = SPLFixture.estimator()
        let reading = SPLFixture.run(estimator, atDBA: 85, seconds: 4 * 3_600, frameSeconds: 60)
        XCTAssertEqual(Double(reading.doseNIOSH), 0.50, accuracy: 0.01)
    }

    /// The NIOSH threshold is a named option, default on: sound under 80 dBA adds no dose.
    func testThresholdIsOnByDefaultAndKeepsQuietSoundOutOfTheDose() {
        XCTAssertTrue(SPLDoseOptions().applyNIOSHThreshold)
        XCTAssertEqual(SPLDoseOptions.nioshThresholdDBA, 80)

        let estimator = SPLFixture.estimator()
        let reading = SPLFixture.run(estimator, atDBA: 79, seconds: 8 * 3_600, frameSeconds: 60)
        XCTAssertEqual(Double(reading.doseNIOSH), 0, accuracy: 1e-12)
        // The time still counts as listening, and still shows in the Leq.
        XCTAssertEqual(reading.doseSeconds, 8 * 3_600, accuracy: 1e-6)
        XCTAssertEqual(Double(reading.leqATrack), 79, accuracy: 0.1)
    }

    /// With the threshold off, the same 79 dBA does accumulate.
    func testThresholdCanBeTurnedOff() {
        let estimator = SPLFixture.estimator(options: SPLDoseOptions(applyNIOSHThreshold: false))
        let reading = SPLFixture.run(estimator, atDBA: 79, seconds: 8 * 3_600, frameSeconds: 60)
        // T(79) = 8 h · 2^(6/3) = 32 h, so 8 h is a quarter of it.
        XCTAssertEqual(Double(reading.doseNIOSH), 0.25, accuracy: 0.01)
    }

    /// The threshold is a cliff at exactly 80, not a slope.
    func testThresholdBoundary() {
        let under = SPLFixture.estimator()
        let over = SPLFixture.estimator()
        let a = SPLFixture.run(under, atDBA: 79.5, seconds: 600, frameSeconds: 10)
        let b = SPLFixture.run(over, atDBA: 80.5, seconds: 600, frameSeconds: 10)
        XCTAssertEqual(Double(a.doseNIOSH), 0, accuracy: 1e-12)
        XCTAssertGreaterThan(Double(b.doseNIOSH), 0)
    }

    // MARK: WHO / ITU-T H.870

    /// The adult weekly allowance: 80 dBA for 40 hours is the whole week.
    func testFortyHoursAt80IsTheWholeWeeklyAllowance() {
        let estimator = SPLFixture.estimator()
        let reading = SPLFixture.run(estimator, atDBA: 80, seconds: 40 * 3_600, frameSeconds: 120)
        XCTAssertEqual(Double(reading.doseWHOWeekly), 1.00, accuracy: 0.01)
    }

    /// +10 dB is one tenth of the time: 4 hours at 90 dBA is also the whole week.
    func testFourHoursAt90IsTheWholeWeeklyAllowance() {
        let estimator = SPLFixture.estimator()
        let reading = SPLFixture.run(estimator, atDBA: 90, seconds: 4 * 3_600, frameSeconds: 60)
        XCTAssertEqual(Double(reading.doseWHOWeekly), 1.00, accuracy: 0.01)
    }

    /// H.870 states no threshold, so quiet listening does spend a sliver of the allowance.
    func testWeeklyAllowanceHasNoThreshold() {
        let estimator = SPLFixture.estimator()
        let reading = SPLFixture.run(estimator, atDBA: 70, seconds: 4 * 3_600, frameSeconds: 60)
        // 4 h at 70 dBA = 14400 · 10^-1 / 144000 = 1 %.
        XCTAssertEqual(Double(reading.doseWHOWeekly), 0.01, accuracy: 0.001)
    }

    // MARK: Silence

    /// Digital silence does not advance the dose clock, however long it lasts.
    func testSilentFramesDoNotAdvanceTheDoseClock() {
        let estimator = SPLFixture.estimator()
        SPLFixture.run(estimator, atDBA: 90, seconds: 600, frameSeconds: 10)
        let before = estimator.doseState()

        // An hour of digital silence, with a loud band in the reading to prove that the
        // `isSilent` flag alone is what stops the clock.
        var reading = before.nioshDose == 0 ? nil as SPLReading? : nil
        let loudBands = SPLFixture.reading(atDBA: 95)
        for _ in 0..<360 {
            reading = estimator.evaluate(thirdOctave: loudBands, dt: 10, isSilent: true)
        }
        let after = estimator.doseState()
        XCTAssertEqual(after.nioshDose, before.nioshDose, accuracy: 1e-12)
        XCTAssertEqual(after.whoWeeklyEnergySeconds, before.whoWeeklyEnergySeconds, accuracy: 1e-9)
        XCTAssertEqual(after.doseSeconds, 600, accuracy: 1e-6)
        XCTAssertNotNil(reading)
    }

    /// A frame that carried no audio time does not advance it either.
    func testZeroDtFramesDoNotAdvanceTheDoseClock() {
        let estimator = SPLFixture.estimator()
        let bands = SPLFixture.reading(atDBA: 95)
        for _ in 0..<1_000 { _ = estimator.evaluate(thirdOctave: bands, dt: 0, isSilent: false) }
        let state = estimator.doseState()
        XCTAssertEqual(state.doseSeconds, 0, accuracy: 1e-12)
        XCTAssertEqual(state.nioshDose, 0, accuracy: 1e-12)
    }

    // MARK: Time to the limit

    /// With no dose spent, the time left is the whole allowance for that level.
    func testSecondsToNIOSHLimitOnAFreshDose() {
        let estimator = SPLFixture.estimator()
        XCTAssertEqual(estimator.secondsToNIOSHLimit(atDBA: 85), 8 * 3_600, accuracy: 1)
        XCTAssertEqual(estimator.secondsToNIOSHLimit(atDBA: 88), 4 * 3_600, accuracy: 1)
        XCTAssertEqual(estimator.secondsToNIOSHLimit(atDBA: 94), 3_600, accuracy: 1)
    }

    /// Under the threshold the limit is never reached.
    func testSecondsToNIOSHLimitIsInfiniteUnderTheThreshold() {
        let estimator = SPLFixture.estimator()
        XCTAssertEqual(estimator.secondsToNIOSHLimit(atDBA: 79.9), .infinity)
        XCTAssertTrue(estimator.secondsToNIOSHLimit(atDBA: 85).isFinite)
    }

    /// Spending half the dose halves the time left.
    func testSecondsToNIOSHLimitShrinksWithTheDose() {
        let estimator = SPLFixture.estimator()
        SPLFixture.run(estimator, atDBA: 85, seconds: 4 * 3_600, frameSeconds: 60)
        XCTAssertEqual(estimator.secondsToNIOSHLimit(atDBA: 85), 4 * 3_600, accuracy: 60)
    }

    /// Once the dose is spent there is no time left.
    func testSecondsToNIOSHLimitIsZeroAtFullDose() {
        let estimator = SPLFixture.estimator()
        SPLFixture.run(estimator, atDBA: 85, seconds: 8 * 3_600, frameSeconds: 60)
        XCTAssertEqual(estimator.secondsToNIOSHLimit(atDBA: 85), 0, accuracy: 1e-9)
    }

    /// The reading's own field tracks the slow level, so it settles to the same answer.
    func testReadingReportsTheTimeToTheLimit() {
        let estimator = SPLFixture.estimator()
        let reading = SPLFixture.run(estimator, atDBA: 94, seconds: 60, frameSeconds: 1)
        // 60 s of 3600 s spent, so about 3540 s left, less the slow meter's first second.
        XCTAssertEqual(reading.secondsToNIOSHLimit, 3_540, accuracy: 30)
    }

    // MARK: Reset

    /// `resetDose` clears the dose, the counted seconds and the session Leq.
    func testResetDoseClearsEverythingItOwns() {
        let estimator = SPLFixture.estimator()
        SPLFixture.run(estimator, atDBA: 90, seconds: 3_600, frameSeconds: 60)
        estimator.resetDose()
        let reading = SPLFixture.run(estimator, atDBA: 80, seconds: 10)
        XCTAssertEqual(reading.doseNIOSH, 0, accuracy: 0.001)
        XCTAssertEqual(reading.doseWHOWeekly, 0, accuracy: 0.001)
        XCTAssertEqual(reading.doseSeconds, 10, accuracy: 1e-6)
        XCTAssertEqual(Double(reading.leqASession), 80, accuracy: 0.05)
    }

    // MARK: Persistence

    /// A dose survives a round trip through `doseState()` / `restore(_:)`.
    func testDoseStateRoundTrip() {
        let first = SPLFixture.estimator()
        SPLFixture.run(first, atDBA: 90, seconds: 1_800, frameSeconds: 30)
        let saved = first.doseState()
        XCTAssertGreaterThan(saved.nioshDose, 0)

        let second = SPLFixture.estimator()
        second.restore(saved)
        XCTAssertEqual(second.doseState(), saved)

        // The restored estimator carries on from where the first one stopped.
        let a = SPLFixture.run(first, atDBA: 90, seconds: 600, frameSeconds: 30)
        let b = SPLFixture.run(second, atDBA: 90, seconds: 600, frameSeconds: 30)
        XCTAssertEqual(Double(b.doseNIOSH), Double(a.doseNIOSH), accuracy: 1e-6)
        XCTAssertEqual(b.doseSeconds, a.doseSeconds, accuracy: 1e-9)
        XCTAssertEqual(Double(b.doseWHOWeekly), Double(a.doseWHOWeekly), accuracy: 1e-6)
    }

    /// The state is `Codable`, so the app can write it as JSON and read it back exactly.
    func testDoseStateSurvivesJSON() throws {
        let estimator = SPLFixture.estimator()
        SPLFixture.run(estimator, atDBA: 92, seconds: 900, frameSeconds: 30)
        let saved = estimator.doseState()

        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SPLDoseState.self, from: data)
        XCTAssertEqual(decoded, saved)
        XCTAssertFalse(decoded.dayStamp.isEmpty)
        XCTAssertFalse(decoded.weekStamp.isEmpty)
    }

    /// Monday 2026-09-21, noon UTC. Rollover is checked in a fixed zone so the result does
    /// not depend on where the test machine sits.
    private static let mondayNoonUTC = Date(timeIntervalSince1970: 1_789_992_000)

    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// A state with real accumulators, stamped in UTC.
    private func savedState(at date: Date) -> SPLDoseState {
        let estimator = SPLFixture.estimator(now: { date })
        SPLFixture.run(estimator, atDBA: 90, seconds: 3_600, frameSeconds: 60)
        var saved = estimator.doseState()
        saved.dayStamp = SPLDoseState.dayStamp(for: date, calendar: Self.utc)
        saved.weekStamp = SPLDoseState.weekStamp(for: date, calendar: Self.utc)
        return saved
    }

    /// A new day clears the daily dose; the weekly allowance keeps running.
    func testRolloverToANewDayClearsTheDailyDoseOnly() {
        let saved = savedState(at: Self.mondayNoonUTC)
        XCTAssertGreaterThan(saved.nioshDose, 0)

        let tuesday = Self.mondayNoonUTC.addingTimeInterval(24 * 3_600)
        let rolled = saved.rolled(to: tuesday, calendar: Self.utc)
        XCTAssertEqual(rolled.nioshDose, 0)
        XCTAssertEqual(rolled.doseSeconds, 0)
        XCTAssertEqual(rolled.sessionSeconds, 0)
        XCTAssertEqual(rolled.sessionEnergySeconds, 0)
        XCTAssertEqual(rolled.whoWeeklyEnergySeconds, saved.whoWeeklyEnergySeconds, accuracy: 1e-9)
        XCTAssertEqual(rolled.dayStamp, "2026-09-22")
        XCTAssertEqual(rolled.weekStamp, saved.weekStamp, "Monday and Tuesday are the same ISO week")
    }

    /// A new ISO week clears the weekly allowance too.
    func testRolloverToANewWeekClearsTheWeeklyAllowance() {
        let saved = savedState(at: Self.mondayNoonUTC)
        XCTAssertGreaterThan(saved.whoWeeklyEnergySeconds, 0)

        let nextWeek = Self.mondayNoonUTC.addingTimeInterval(8 * 24 * 3_600)
        let rolled = saved.rolled(to: nextWeek, calendar: Self.utc)
        XCTAssertEqual(rolled.whoWeeklyEnergySeconds, 0)
        XCTAssertEqual(rolled.nioshDose, 0)
        XCTAssertNotEqual(rolled.weekStamp, saved.weekStamp)
    }

    /// Restoring inside the same day and week changes nothing.
    func testRolloverInsideTheSameDayIsANoOp() {
        let saved = savedState(at: Self.mondayNoonUTC)
        XCTAssertEqual(saved.rolled(to: Self.mondayNoonUTC.addingTimeInterval(120), calendar: Self.utc), saved)
    }

    /// The stamps are the shapes the app will compare, and both use the same time zone.
    func testStampFormats() {
        let d = Self.mondayNoonUTC
        XCTAssertEqual(SPLDoseState.dayStamp(for: d, calendar: Self.utc), "2026-09-21")
        XCTAssertEqual(SPLDoseState.weekStamp(for: d, calendar: Self.utc), "2026-W39")
    }

    /// A day stamp and a week stamp taken with the same calendar never disagree about which
    /// midnight they mean — the bug a listener at 00:30 on a Monday would otherwise hit.
    func testStampsAgreeAcrossTimeZones() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // Sunday 2026-09-20 16:00 UTC is already Monday 01:00 in Tokyo: a new day AND a new week.
        let sundayEvening = Date(timeIntervalSince1970: 1_789_920_000)
        XCTAssertEqual(SPLDoseState.dayStamp(for: sundayEvening, calendar: tokyo), "2026-09-21")
        XCTAssertEqual(SPLDoseState.weekStamp(for: sundayEvening, calendar: tokyo), "2026-W39")
        XCTAssertEqual(SPLDoseState.dayStamp(for: sundayEvening, calendar: Self.utc), "2026-09-20")
        XCTAssertEqual(SPLDoseState.weekStamp(for: sundayEvening, calendar: Self.utc), "2026-W38")
    }
}
