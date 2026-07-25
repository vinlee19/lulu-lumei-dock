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

    t.test("firstStep：取首个清单步骤文字（去列表符/方框/修饰）") {
        let md = """
        # Codex 计划

        > 来源：rollout-xxx

        - [x] Remove `REGISTERED_TOOL_COUNT` tracking and simplify helpers.
        - [x] Adjust health status.
        """
        try expectEqual(
            PlanParsing.firstStep(md),
            "Remove REGISTERED_TOOL_COUNT tracking and simplify helpers.")
        try expect(PlanParsing.firstStep("# 纯文档\n\n没有清单") == nil)
    }

    t.suite("tightenPlanTitle")

    t.test("按句读边界收短：句末标点优先，标题不带句号") {
        try expectEqual(
            tightenPlanTitle("请分析一下 Notion 报告的内容。我的想法是把结论放到第 3 章"),
            "请分析一下 Notion 报告的内容")
    }

    t.test("无句末标点时退到逗号；太靠前的逗号不算") {
        try expectEqual(
            tightenPlanTitle("重构技能页的统计卡，同时把来源筛选换成 chips 并接真实命中数"),
            "重构技能页的统计卡")
        // 逗号在第 3 字，过短 → 不按它切
        try expect(!tightenPlanTitle("先说，然后我们要把整个索引层的去重逻辑重做一遍并补上回归测试用例").hasSuffix("先说"))
    }

    t.test("已带省略号的硬截断产物先去省略号再重切，不叠加") {
        let hard = String(repeating: "长", count: 80) + "…"
        let tightened = tightenPlanTitle(hard)
        try expect(!tightened.hasSuffix("……"), "不应叠加省略号")
        try expect(tightened.count <= 47, "应收到 maxLength 内：\(tightened.count)")
    }

    t.test("短标题原样返回") {
        try expectEqual(tightenPlanTitle("用量扫描 SQLite 锁修复计划"), "用量扫描 SQLite 锁修复计划")
    }
}
