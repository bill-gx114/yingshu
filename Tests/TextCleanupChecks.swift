import Foundation

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckError.failed(message) }
}
private enum CheckError: Error { case failed(String) }

@main enum TextCleanupChecks {
    static func main() async throws {
        setbuf(stdout, nil)
        try require(SpeechTextCleaner.basicClean("  海边\t\t真美，，\r\n  风很轻。。。 \n\n\n明天再来。 ") == "海边 真美，\n风很轻。\n\n明天再来。", "Basic whitespace/punctuation normalization")
        try require(SpeechTextCleaner.basicClean("\u{3000}京都\u{00A0}\u{00A0}Mac  27\u{3000}") == "京都 Mac 27", "Unicode spaces must normalize")
        try require(SpeechTextCleaner.basicClean("今天海边很安静 ，我们在散步 。\n啊 ！ 真的很开心！！") == "今天海边很安静，我们在散步。\n啊！真的很开心！！", "Chinese punctuation gaps should normalize without joining lines or deleting emotion")
        try require(SpeechTextCleaner.basicClean("京都\t，\tiPhone拍了3段 ：\t海 、\t风。\nEnglish, next. std::vector https://example.invalid/a?b=1") == "京都，iPhone拍了3段：海、风。\nEnglish, next. std::vector https://example.invalid/a?b=1", "Only Chinese punctuation should lose adjacent ASCII whitespace")
        for text in ["嗯，啊，真好。", "啊！！今天真的真的很开心？！", "我说不，不，不去。", "想了很久……还是想你。", "Wait... std::vector, 3.5, https://example.invalid/a?b=1", "我想走一走，慢一点，再慢一点。", "I don't want to go."] {
            try require(SpeechTextCleaner.basicClean(text) == text, "Basic formatting changed meaningful words, emotion, or technical punctuation: " + text)
        }
        print("PASS conservative basic formatting preserves emotion/fillers, meaningful repeats, ellipsis, English punctuation, numbers and negation")

        let captionPunctuation = [
            ("今天的海风很舒服。", "今天的海风很舒服"),
            ("今天的海风很舒服.", "今天的海风很舒服"),
            ("前面一句。后面一句。", "前面一句。后面一句"),
            ("你听说了吗？", "你听说了吗？"), ("真开心！！", "真开心！！"),
            ("真的?!", "真的?!"), ("想了很久……", "想了很久……"),
            ("Wait...", "Wait..."), ("想一想..", "想一想.."),
            ("想了很久……。", "想了很久……"),
            ("他说：“真好。”", "他说：“真好”"),
            ("（今天真好。）", "（今天真好）"),
            ("She said, \"Hi.\"", "She said, \"Hi\""),
            ("温度3.5。", "温度3.5"), ("版本1.2.3.", "版本1.2.3"),
            ("U.S.", "U.S."), ("e.g.", "e.g."), ("Ph.D.", "Ph.D."),
            ("Dr.", "Dr."), ("。", ""), (".", "")
        ]
        for (source, expected) in captionPunctuation {
            let displayed = SpeechTextCleaner.captionText(source)
            try require(displayed == expected, "Caption ending changed incorrectly: \(source) => \(displayed)")
            try require(SpeechTextCleaner.captionText(displayed) == displayed, "Caption punctuation must be idempotent")
        }
        print("PASS caption endings drop sentence stops, retain emotional punctuation, internal stops, quotations, decimals and abbreviations; basic formatting stays unchanged")

        let samples: [(String,String,[String])] = [
            ("我们我们下午去京都，嗯，走一走。", "我们下午去京都，走一走。", ["京都"]),
            ("今天用 iPhone 录了3段视频花了120元", "今天用 iPhone 录了3段视频，花了120元。", ["iPhone"]),
            ("我不是不喜欢海边只是今天不想去", "我不是不喜欢海边，只是今天不想去。", []),
            ("2026-10-19我们从京都到大阪坐了3次车花了120.50元", "2026-10-19，我们从京都到大阪坐了3次车，花了120.50元。", ["京都","大阪"]),
            ("I don't want to leave Kyoto today", "I don't want to leave Kyoto today.", ["Kyoto"]),
            ("我看了三次海花了二十元", "我看了三次海，花了二十元。", [])
        ]
        for (source, output, terms) in samples {
            try require(try SpeechTextCleaner.validateResult(output, original: source, protectedTerms: terms) == output, "Conservative result was refused")
        }
        print("PASS deterministic guard accepts only supplied safe edits; these are fixtures, not model-generated samples")

        try rejects("今天用 iPhone 录了3段视频花了120元", "今天用 iPhone 录了4段视频，花了120元。", ["iPhone"], reason: "数字")
        try rejects("今天拍摄花了120元", "今天拍摄花了120", [], reason: "数字")
        try rejects("我看了三次海花了二十元", "我看了三次海，花了二十五元。", [], reason: "数字")
        try rejects("我们从京都去了大阪", "我们从东京去了大阪。", ["京都","大阪"], reason: "保护词")
        try rejects("我不是不喜欢海边", "我不是喜欢海边。", [], reason: "否定")
        try rejects("I don't want to leave Kyoto", "I want to leave Kyoto.", ["Kyoto"], reason: "否定")
        try rejects("I like sea", "I like tea.", [], reason: "英文词")
        try rejects("我们今天沿着海边慢慢走，后来坐在石头上看海，觉得很放松", "我们今天沿着海边慢慢走，后来坐在石头上看海，觉得很放松，阳光好。", [], reason: "新内容")
        try rejects("海风很轻，我们一直沿着海边慢慢走，想记住今天的感觉", "今天是一场不可思议的伟大冒险", [], reason: nil)
        try rejects("海风很轻，我们沿着海边慢慢走", "海风很轻", [], reason: "改写")
        try rejects("海风很轻", "整理后：海风很轻。", [], reason: "正文")
        try rejects("海风很轻", "", [], reason: nil)
        try rejects("海风很轻", String(repeating: "风", count: 2001), [], reason: nil)
        print("PASS guards reject changed Arabic/Chinese numbers, protected places, deleted negations, new facts, excessive edits, wrappers and invalid output")

        for (source, corrected) in [("海边的天好篮，风很轻。", "海边的天好蓝，风很轻。"), ("今天这个地方好漂量。", "今天这个地方好漂亮。"), ("我们下午去了耳海，天气很好。", "我们下午去了洱海，天气很好。")] {
            try require(try SpeechTextCleaner.validateResult(corrected, original: source, protectedTerms: [], allowPhoneticCorrections: true) == corrected,
                        "Bounded same-sound recognition correction should pass only when explicitly allowed")
            try rejects(source, corrected, [], reason: "新内容")
        }
        do {
            _ = try SpeechTextCleaner.validateResult("我们去了东京。", original: "我们去了京都。", protectedTerms: ["京都"], allowPhoneticCorrections: true)
            throw CheckError.failed("Protected place changed under phonetic mode")
        } catch is SpeechTextCleanupError { }
        try rejects("开放时间：早上九点至下午五点。", "早上九点至下午五点。", [], reason: "遗漏")
        try rejects("明天可能下雨，我们也许去海边。", "明天下雨，我们去海边。", [], reason: "不确定")
        print("PASS opt-in limited homophone corrections, protected-place preservation, missing-content and uncertainty guards")

        let completions = [
            ("我把今天的感受写在记里，后来又看了一遍，哈哈哈哈。", "我把今天的感受写在日记里，后来又看了一遍，哈哈哈哈。"),
            ("我们把今天拍的照放进相册，明天再看。", "我们把今天拍的照片放进相册，明天再看。"),
            ("我们想把这段文做成幕留在画面上。", "我们想把这段文做成字幕留在画面上。")
        ]
        for (source, corrected) in completions {
            try require(try SpeechTextCleaner.validateResult(corrected, original: source, protectedTerms: [],
                        allowPhoneticCorrections: true, allowWordCompletion: true) == corrected,
                        "An anchored one-character completion of a supplied common word should pass")
            try rejects(source, corrected, [], reason: "新内容")
        }
        let wordRepairSource = "我把今天的感受写在记里，后来又看了一遍，哈哈哈哈。"
        for output in [
            "我把今天的感受写在日记里，哈哈哈哈。",
            "我把今天的感受写在日记里，后来又看了一遍，哈哈。",
            "我把今天的感受写在美丽日记里，后来又看了一遍，哈哈哈哈。",
            "我把今天的感受写在日记里，后来又看了一遍，哈哈哈哈，真幸福。"
        ] {
            try rejectsRepair(wordRepairSource, output, [])
        }
        for (source, changed) in [
            ("你听说了吗？", "听说了。"),
            ("你听说了吗？", "你听说了。"),
            ("我们今天沿着海边慢慢走。", "我们今天又沿着海边慢慢走。"),
            ("我把今天的感受写在日记里。", "我把今天的感受写在日记里面。"),
            ("我不想把今天的感受写在日记里。", "我想把今天的感受写在日记里。"),
            ("我们花了120元，后来坐了3次车。", "我们花了1200元，后来坐了3次车。"),
            ("今天也许下雨，我们可能去海边。", "今天下雨，我们去海边。"),
            ("今天的树叶很绿，我们慢慢走。", "今天的树叶很鹿，我们慢慢走。"),
            ("那个女孩正在海边散步。", "那个怒孩正在海边散步。")
        ] {
            try rejectsRepair(source, changed, [])
        }
        try rejectsRepair("我们下午去了耳海，天气很好。", "我们下午去了洱海，天气很好。", ["耳海"])
        try rejects("你听说了吗？", "听说了。", [], reason: "遗漏")
        try rejects("你听说了吗？", "你听说了。", [], reason: "遗漏")
        try rejects("我哭了，哈哈哈哈。", "我哭了，哈哈。", [], reason: "情绪")
        print("PASS local-only anchored common-word completions; no dropped subjects/questions, emotion, facts or unbounded insertions")

        for input in [" \n\t", String(repeating: "字", count: 2001)] {
            do { _ = try await SpeechTextCleaner.clean(input, protectedTerms: []); throw CheckError.failed("Invalid input was accepted") }
            catch is SpeechTextCleanupError { }
        }
        let (startGate, releaseGate) = AsyncStream<Void>.makeStream()
        let cancelled = Task { () throws -> String in
            for await _ in startGate { break }
            return try await SpeechTextCleaner.clean("这是取消检查。", protectedTerms: [])
        }
        cancelled.cancel()
        releaseGate.finish()
        do { _ = try await cancelled.value; throw CheckError.failed("Cancelled cleanup completed") }
        catch is CancellationError { }
        print("PASS empty/overlong input and cancellation never proceed to generation")

        let state = SpeechTextCleaner.availability
        print("LOCAL MODEL available=\(state.isAvailable) message=\(state.message)")
        if !state.isAvailable {
            do { _ = try await SpeechTextCleaner.clean("今天去了京都，拍了3张照片。", protectedTerms: ["京都"]); throw CheckError.failed("Unavailable model silently returned a fallback") }
            catch let error as SpeechTextCleanupError {
                guard case .unavailable = error else { throw error }
                print("PASS actual unavailable runtime reports an explicit error; no AI result was generated")
            }
        } else if CommandLine.arguments.contains("--live") {
            for source in ["我们我们今天去京都，嗯，用 iPhone 拍了3段视频，花了120元。", "我不是不喜欢海边，我今天只是想慢慢走。", "2026-10-19从京都去大阪，坐了3次地铁。"] {
                let result = try await SpeechTextCleaner.clean(source, protectedTerms: ["京都","大阪","iPhone"])
                print("ACTUAL LOCAL MODEL INPUT: \(source)\nOUTPUT: \(result)")
            }
        } else {
            print("NOTE model is available; actual generation requires --live, no inference performed by default")
        }
        print("ALL TEXT CLEANUP CHECKS PASSED")
    }

    private static func rejects(_ original: String, _ output: String, _ terms: [String], reason: String?) throws {
        do { _ = try SpeechTextCleaner.validateResult(output, original: original, protectedTerms: terms); throw CheckError.failed("Unsafe result was accepted: " + output) }
        catch let error as SpeechTextCleanupError {
            if let reason { try require(error.localizedDescription.contains(reason), "Unexpected rejection reason: " + error.localizedDescription) }
        }
    }

    private static func rejectsRepair(_ original: String, _ output: String, _ terms: [String]) throws {
        do {
            _ = try SpeechTextCleaner.validateResult(output, original: original, protectedTerms: terms,
                allowPhoneticCorrections: true, allowWordCompletion: true)
            throw CheckError.failed("Unsafe repair was accepted: " + output)
        } catch is SpeechTextCleanupError { }
    }
}
