import XCTest
@testable import AudioRecorderCore

final class RecordingTitlerTests: XCTestCase {
    // MARK: - Cleaning

    func testSanitizeKeepsShortReadableNames() {
        XCTAssertEqual(RecordingTitler.sanitize("Pricing Call"), "Pricing Call")
        XCTAssertEqual(RecordingTitler.sanitize("Q3 Budget"), "Q3 Budget")
        XCTAssertEqual(RecordingTitler.sanitize("Sync-Up"), "Sync-Up")
        // A function word inside a name that already fits is left alone.
        XCTAssertEqual(RecordingTitler.sanitize("Out of Office"), "Out of Office")
    }

    /// Path characters must never reach a file name. They become separators
    /// rather than vanishing, so words stay apart.
    func testSanitizeReplacesPathCharactersWithSpaces() {
        XCTAssertEqual(RecordingTitler.sanitize("Sync/Dana"), "Sync Dana")
        XCTAssertEqual(RecordingTitler.sanitize("10:30 Call"), "10 30 Call")
    }

    func testSanitizeCollapsesWhitespaceAndTrimsEdges() {
        XCTAssertEqual(RecordingTitler.sanitize("  Vendor    Demo \n"), "Vendor Demo")
        XCTAssertEqual(RecordingTitler.sanitize("--Kickoff--"), "Kickoff")
        XCTAssertEqual(RecordingTitler.sanitize(".hidden"), "hidden")
    }

    func testSanitizeDropsDisallowedCharacters() {
        XCTAssertEqual(RecordingTitler.sanitize("Budget (draft)!"), "Budget draft")
        XCTAssertEqual(RecordingTitler.sanitize("💰 Money Talk"), "Money Talk")
    }

    /// Possessives lose the whole suffix, not just the apostrophe: "Jims Label"
    /// reads like a typo.
    func testSanitizeDropsPossessiveSuffix() {
        XCTAssertEqual(RecordingTitler.sanitize("Jim's Label"), "Jim Label")
        XCTAssertEqual(RecordingTitler.sanitize("Q3’s Budget"), "Q3 Budget")
    }

    // MARK: - Shortening

    /// The bug this feature shipped with: a model answered "Impact of Childhood
    /// Labels" and truncation produced the fragment "Impact of". Over-long names
    /// must lose whole words and never end on a preposition.
    func testOverLongNameLosesWholeWordsRatherThanBeingCut() {
        let shortened = RecordingTitler.sanitize("Impact of Childhood Labels")
        XCTAssertEqual(shortened, "Childhood")
        XCTAssertNotEqual(shortened, "Impact of")
    }

    func testShorteningKeepsTheStrongestAdjacentPair() {
        // "Boy Broken Brain" is 16; the best pair that fits is a real phrase.
        XCTAssertEqual(RecordingTitler.sanitize("The Boy with the Broken Brain"), "Broken Brain")
        XCTAssertEqual(RecordingTitler.sanitize("Jim's Broken Brain"), "Broken Brain")
        XCTAssertEqual(RecordingTitler.sanitize("Broken Brain Labels"), "Broken Brain")
    }

    /// Words describing the container rather than the content go first.
    func testShorteningDropsFillerWordsBeforeRealOnes() {
        XCTAssertEqual(RecordingTitler.sanitize("Pricing Discussion"), "Pricing")
        XCTAssertEqual(RecordingTitler.sanitize("Analytics Overview"), "Analytics")
        XCTAssertEqual(RecordingTitler.sanitize("Deploy Retro Meeting"), "Deploy Retro")
        // "Migration Retro" is 15, one over, so even that has to give way.
        XCTAssertEqual(RecordingTitler.sanitize("Migration Retro Meeting"), "Migration")
    }

    func testLeadingArticleIsDropped() {
        XCTAssertEqual(RecordingTitler.sanitize("The Team"), "Team")
    }

    func testShorteningStaysWithinBudget() {
        for input in [
            "Impact of Childhood Labels",
            "Quarterly Budget Review Meeting",
            "Analytics Product Tour",
            "Checkout API Issue",
            "The lasting impact of the words adults use with children",
        ] {
            let result = RecordingTitler.sanitize(input)
            XCTAssertNotNil(result, input)
            XCTAssertLessThanOrEqual(result?.count ?? 99, RecordingTitler.maxLength, input)
        }
    }

    /// A single word longer than the whole budget is cut — the only case where
    /// cutting is acceptable, because there is no word to drop.
    func testSanitizeHardCutsOneLongWord() {
        XCTAssertEqual(RecordingTitler.sanitize("Internationalization"), "Internationali")
        XCTAssertEqual(
            RecordingTitler.sanitize("Internationalization")?.count, RecordingTitler.maxLength
        )
    }

    func testSanitizeReturnsNilWhenNothingUsableRemains() {
        XCTAssertNil(RecordingTitler.sanitize(""))
        XCTAssertNil(RecordingTitler.sanitize("   "))
        XCTAssertNil(RecordingTitler.sanitize("!!!"))
        XCTAssertNil(RecordingTitler.sanitize("///"))
    }

    func testSanitizeRespectsCustomLimit() {
        XCTAssertEqual(
            RecordingTitler.sanitize("Quarterly Budget Review", maxLength: 20),
            "Quarterly Budget"
        )
    }

    // MARK: - candidate / fits

    /// The caller needs the model's answer unshortened, to quote back when it
    /// asks for something shorter.
    func testCandidateKeepsLengthButCleansDecoration() {
        XCTAssertEqual(
            RecordingTitler.candidate(in: "\"Impact of Childhood Labels\""),
            "Impact of Childhood Labels"
        )
        XCTAssertEqual(
            RecordingTitler.candidate(in: "File name: Checkout Outage"), "Checkout Outage"
        )
        XCTAssertNil(RecordingTitler.candidate(in: "  \n "))
    }

    func testFitsMeasuresAgainstTheBudget() {
        XCTAssertTrue(RecordingTitler.fits("Broken Brain"))
        XCTAssertTrue(RecordingTitler.fits("Migration Slip"))
        XCTAssertFalse(RecordingTitler.fits("Checkout Outage"))
        XCTAssertFalse(RecordingTitler.fits(""))
    }

    // MARK: - parse

    func testParseUnwrapsModelDecoration() {
        XCTAssertEqual(RecordingTitler.parse("\"Pricing Call\""), "Pricing Call")
        XCTAssertEqual(RecordingTitler.parse("Title: Q3 Budget"), "Q3 Budget")
        XCTAssertEqual(RecordingTitler.parse("```\nVendor Demo\n```"), "Vendor Demo")
        XCTAssertEqual(RecordingTitler.parse("Kickoff."), "Kickoff")
        XCTAssertEqual(RecordingTitler.parse("  Standup \n"), "Standup")
    }

    /// A model that answers with a sentence still yields a usable name rather
    /// than nothing at all.
    func testParseShortensRatherThanRejectingLongAnswers() {
        let parsed = RecordingTitler.parse(
            "The conversation was mainly about next quarter's pricing strategy."
        )
        XCTAssertNotNil(parsed)
        XCTAssertLessThanOrEqual(parsed?.count ?? 99, RecordingTitler.maxLength)
    }

    func testParseReturnsNilForEmptyOrUnusableResponses() {
        XCTAssertNil(RecordingTitler.parse(""))
        XCTAssertNil(RecordingTitler.parse("   \n  "))
        XCTAssertNil(RecordingTitler.parse("***"))
    }

    // MARK: - heuristic fallback

    func testHeuristicTitleUsesMostFrequentSalientWords() {
        let transcript = """
        Me: how does the pricing look for the new tier?
        Them: pricing is fine, but the budget for onboarding is tight.
        Me: so pricing is agreed and budget is the open item?
        Them: yes, budget.
        """
        XCTAssertEqual(RecordingTitler.heuristicTitle(from: transcript), "Pricing Budget")
    }

    func testHeuristicTitleIsDeterministic() {
        let transcript = "Me: deployment deployment rollback. Them: rollback pipeline."
        XCTAssertEqual(
            RecordingTitler.heuristicTitle(from: transcript),
            RecordingTitler.heuristicTitle(from: transcript)
        )
    }

    func testHeuristicTitleStaysWithinBudget() {
        let transcript = String(repeating: "internationalization localization ", count: 3)
        let title = RecordingTitler.heuristicTitle(from: transcript)
        XCTAssertNotNil(title)
        XCTAssertLessThanOrEqual(title?.count ?? 99, RecordingTitler.maxLength)
    }

    func testHeuristicTitleReturnsNilWithoutSalientWords() {
        XCTAssertNil(RecordingTitler.heuristicTitle(from: ""))
        XCTAssertNil(RecordingTitler.heuristicTitle(from: "Me: yeah. Them: okay, sure, right."))
    }

    // MARK: - prompts

    func testPromptIncludesSummaryOnlyWhenPresent() {
        let withSummary = RecordingTitler.user(
            summary: "They agreed on pricing.", transcript: "Me: hi"
        )
        XCTAssertTrue(withSummary.contains("Summary of the conversation"))
        let withoutSummary = RecordingTitler.user(summary: "  ", transcript: "Me: hi")
        XCTAssertFalse(withoutSummary.contains("Summary of the conversation"))
        XCTAssertTrue(withoutSummary.contains("Me: hi"))
    }

    func testPromptBoundsTranscriptLength() {
        let huge = String(repeating: "word ", count: 5_000)
        let prompt = RecordingTitler.user(summary: "", transcript: huge)
        XCTAssertLessThan(prompt.count, RecordingTitler.promptCharacterLimit + 300)
    }

    /// The system prompt has to carry the budget *and* examples at that length —
    /// stating the limit alone does not stop a model answering with 26
    /// characters.
    func testSystemPromptStatesTheBudgetAndShowsExamples() {
        XCTAssertTrue(RecordingTitler.system.contains("\(RecordingTitler.maxLength) characters"))
        XCTAssertTrue(RecordingTitler.system.contains("Broken Brain"))
        for line in RecordingTitler.system.split(separator: "\n") where line.contains(" -> ") {
            let example = line.components(separatedBy: " -> ").last ?? ""
            XCTAssertLessThanOrEqual(
                example.count, RecordingTitler.maxLength, "example over budget: \(example)"
            )
        }
    }

    func testRetryPromptQuotesTheRejectedAnswerAndItsLength() {
        let retry = RecordingTitler.retryUser(
            summary: "A talk about childhood labels.",
            transcript: "",
            previous: "Impact of Childhood Labels"
        )
        XCTAssertTrue(retry.contains("\"Impact of Childhood Labels\""))
        XCTAssertTrue(retry.contains("26 characters"))
        XCTAssertTrue(retry.contains("Summary of the conversation"))
    }
}
