import XCTest
@testable import WorkbenchKit

/// Reads the real job feed on this Mac and reports how much each record carries. Skipped unless WB_LIVE=1.
final class LiveFeedProbe: XCTestCase {
    func testLiveFeedContent() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WB_LIVE"] == "1")
        let jobs = JobFeed.load()
        print("LIVE jobs=\(jobs.count) emptySummary=\(jobs.filter { $0.summary.isEmpty }.count) emptyOutput=\(jobs.filter { $0.output.isEmpty }.count)")
        for job in jobs.prefix(12) {
            print("LIVE | \(job.project) | \(job.workflow.rawValue) | \(job.status.rawValue) | \(job.title) | sum=\(job.summary.prefix(60)) | out=\(job.output.count) | task=\(job.taskPath ?? "-")")
        }
    }
}
