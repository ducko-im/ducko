import Foundation
import Testing

extension CLIHelperUnitTests {
    struct OutputBufferTests {
        @Test
        func `appends below the cap leave the buffer intact`() async {
            let buffer = OutputBuffer()
            await buffer.append("hello world")
            #expect(await buffer.snapshot() == "hello world")
            #expect(await buffer.cursor() == "hello world".count)
        }

        @Test
        func `appending past the cap drops the oldest characters`() async {
            let buffer = OutputBuffer()
            // Recognisable head marker so we can prove it was dropped.
            let headMarker = "HEAD-MARKER"
            let filler = String(repeating: "x", count: OutputBuffer.maxRetained - headMarker.count)
            let overflow = "TAIL-MARKER"

            await buffer.append(headMarker + filler)
            await buffer.append(overflow)

            let snapshot = await buffer.snapshot()
            #expect(snapshot.count == OutputBuffer.maxRetained)
            #expect(snapshot.hasSuffix(overflow))
            #expect(!snapshot.contains(headMarker))
        }

        @Test
        func `cursor stays monotonic across a trim`() async {
            let buffer = OutputBuffer()
            await buffer.append("first ")
            let earlyCursor = await buffer.cursor()
            #expect(earlyCursor == "first ".count)

            // Push past the cap so the prefix containing the early cursor
            // gets trimmed.
            await buffer.append(String(repeating: "x", count: OutputBuffer.maxRetained))
            let lateCursor = await buffer.cursor()
            #expect(lateCursor > earlyCursor)
            #expect(lateCursor == "first ".count + OutputBuffer.maxRetained)
        }

        @Test
        func `snapshotIfContainsAny after cursor finds substrings written after the cursor`() async {
            let buffer = OutputBuffer()
            await buffer.append("prelude ")
            let cursor = await buffer.cursor()
            await buffer.append("MARKER tail")

            let match = await buffer.snapshotIfContainsAny(["MARKER"], after: cursor)
            #expect(match?.contains("MARKER") == true)

            // A substring that only appears before the cursor is not a match.
            let missingMatch = await buffer.snapshotIfContainsAny(["prelude"], after: cursor)
            #expect(missingMatch == nil)
        }

        @Test
        func `snapshotIfContainsAny after a stale cursor clamps to the retained tail`() async {
            let buffer = OutputBuffer()
            await buffer.append("OLD-PREFIX ")
            let staleCursor = await buffer.cursor()

            // Overflow the buffer so the "OLD-PREFIX " region is dropped and
            // `staleCursor` now points before the start of retained content.
            await buffer.append(String(repeating: "y", count: OutputBuffer.maxRetained))
            await buffer.append("LATE-MARKER")

            // Clamping must keep the substring scan over the entire retained
            // tail (no crash, no negative offset).
            let match = await buffer.snapshotIfContainsAny(["LATE-MARKER"], after: staleCursor)
            #expect(match?.contains("LATE-MARKER") == true)
        }

        @Test
        func `snapshotIfContains behind a marker finds only text written behind the first marker after the cursor`() async {
            let buffer = OutputBuffer()
            await buffer.append("MARKER early text ")
            let cursor = await buffer.cursor()

            // The text alone, as the echo of an earlier command would bring it, is no match.
            await buffer.append("text ")
            #expect(await buffer.snapshotIfContains("text", behind: "MARKER", after: cursor) == nil)

            // Nor is the marker with the text only in front of it.
            await buffer.append("MARKER ")
            #expect(await buffer.snapshotIfContains("text", behind: "MARKER", after: cursor) == nil)

            await buffer.append("late text")
            #expect(await buffer.snapshotIfContains("text", behind: "MARKER", after: cursor)?.hasSuffix("late text") == true)
        }

        @Test
        func `snapshotIfContains behind a marker after a stale cursor clamps to the retained tail`() async {
            let buffer = OutputBuffer()
            await buffer.append("OLD-PREFIX ")
            let staleCursor = await buffer.cursor()
            await buffer.append(String(repeating: "y", count: OutputBuffer.maxRetained))
            await buffer.append("MARKER late text")

            let match = await buffer.snapshotIfContains("late text", behind: "MARKER", after: staleCursor)
            #expect(match?.hasSuffix("MARKER late text") == true)
        }
    }
}
