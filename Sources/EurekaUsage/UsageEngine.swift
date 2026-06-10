import Foundation
import EurekaKit

/// 用量引擎入口。M5 实现：
/// - ClaudeTranscriptScanner（offset 增量 + requestId+message.id 跨文件去重）
/// - CodexUsageScanner（total_token_usage 相邻差值法）
/// - PricingTable（家族匹配；未知模型仅显示 token 不算钱）
/// - UsageAggregator（今日/本周聚合，本地时区，周一起算）
public enum UsageEngine {}
