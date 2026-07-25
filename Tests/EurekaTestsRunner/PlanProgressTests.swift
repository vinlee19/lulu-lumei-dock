import EurekaIngest
import Foundation

func planProgressTests(_ t: TestRunner) {
    t.suite("PlanParsing")

    t.test("checklist 计数：完成 / 进行中 / 未开始") {
        let md = """
        # Title
        - [x] done one
        - [X] done two
        - [~] in progress
        - [ ] not yet
        - [ ] also not
        """
        let c = PlanParsing.checklist(md)
        try expectEqual(c.total, 5)
        try expectEqual(c.done, 2)
        try expectEqual(c.inProgress, 1)
        try expect(abs((c.fraction ?? 0) - 0.4) < 0.0001, "fraction 应为 0.4")
    }

    t.test("checklist 兼容 * / + / 数字前缀，忽略普通列表与正文") {
        let md = """
        prose line
        * [x] star done
        + [ ] plus todo
        1. [x] numbered done
        2) [ ] paren todo
        - normal bullet, not a checkbox
        """
        let c = PlanParsing.checklist(md)
        try expectEqual(c.total, 4)
        try expectEqual(c.done, 2)
    }

    t.test("无清单 → total 0，fraction nil") {
        let c = PlanParsing.checklist("# Doc\n\n纯说明文档，没有任务清单。\n")
        try expectEqual(c.total, 0)
        try expect(c.fraction == nil, "fraction 应为 nil")
    }

    t.test("deriveStatus：文档 / 完成 / 草稿 / 进行中") {
        try expectEqual(PlanMaterializer.deriveStatus(done: 0, total: 0), .document)
        try expectEqual(PlanMaterializer.deriveStatus(done: 3, total: 3), .complete)
        try expectEqual(PlanMaterializer.deriveStatus(done: 0, total: 5), .draft)
        try expectEqual(PlanMaterializer.deriveStatus(done: 2, total: 5), .inProgress)
    }

    t.test("summary：跳过标题 / 引用 / 清单，取首个正文行") {
        let md = """
        # 灵动岛通知节流与合并策略
        > Codex 工作清单 · 会话 abc
        同一 agent 高频事件合并为一条，降低打扰。
        - [ ] step
        """
        try expectEqual(PlanParsing.summary(md), "同一 agent 高频事件合并为一条，降低打扰。")
    }

    t.test("summary：去掉 markdown 修饰与列表符号") {
        try expectEqual(PlanParsing.summary("# T\n\n- **重点** 内容"), "重点 内容")
    }
}
