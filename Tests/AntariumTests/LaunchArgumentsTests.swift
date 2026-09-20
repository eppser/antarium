import Foundation
import Testing
@testable import Antarium

@Suite("Command-line validation before application startup")
struct LaunchArgumentsTests {
    @Test("Unknown, incomplete or conflicting diagnostics cannot fall through to normal startup")
    func invalid() {
        for args in [["--activity-presentation-soak","60"],["--soak-activity-ui"],
            ["--soak-activity-ui","not-a-number"],["--soak-activity-ui","0"],
            ["--activity-preview"],["--activity-preview","--explorer"],
            ["--migrate-harness","fixture.json"],["--agents","--once"],
            ["--model"],["--status","--typo"],["--log","-1"],["--log","1001"],
            ["--evaluate-activity-model","--case"],
            ["--activity-preview","fixture.png","--explorer","--analysis"]] {
            #expect(LaunchArguments.validate(args) != nil)
        }
    }
    @Test("Known diagnostics preserve their documented argument shapes")
    func valid() {
        for args in [["--soak-activity-ui","7200","--patches","--background"],
            ["--soak-activity-ui","1800","--model"],["--soak-activity","60"],
            ["--activity-preview","fixture.png","--explorer","--selected","--compact"],
            ["--migrate-harness","input.json","output.json"],["--agents","--cloud"],
            ["--remote-tmux","fixture-one","fixture-two"],["--log"],["--log","0"],
            ["--once","synthetic"],["--benchmark-activity","--semantic","--ambiguous"],
            ["--evaluate-activity-model","--holdout","--criteria-v2","--current-event-only","--case","fixture"],
            ["--help"]] {
            #expect(LaunchArguments.validate(args) == nil)
        }
    }
    @Test("Normal and recognized macOS launches remain valid, without accepting arbitrary options")
    func platform() {
        #expect(LaunchArguments.validate([]) == nil)
        #expect(LaunchArguments.validate(["-psn_0_12345"]) == nil)
        #expect(LaunchArguments.validate(["-NSDocumentRevisionsDebugMode","YES"]) == nil)
        #expect(LaunchArguments.validate(["-psn_not-a-number"]) != nil)
        #expect(LaunchArguments.validate(["-UnknownStartupOption","YES"]) != nil)
    }
    @Test("Child wrapper flags cannot be intercepted as Antarium help")
    func childHelp() {
        let args = ["run","--","synthetic-command","--help"]
        #expect(LaunchArguments.validate(args) == nil)
        #expect(!LaunchArguments.requestsHelp(args))
        #expect(LaunchArguments.requestsHelp(["--help"]))
    }

}
