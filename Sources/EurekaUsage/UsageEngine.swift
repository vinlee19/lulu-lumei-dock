import Foundation
import EurekaKit

/// Usage engine entry point. M5 implementation:
/// - ClaudeTranscriptScanner (offset-incremental + cross-file requestId+message.id dedup)
/// - CodexUsageScanner (adjacent differences of total_token_usage)
/// - PricingTable (family matching; unknown models show tokens only, no cost)
/// - UsageAggregator (today / this-week aggregation, local time zone, weeks start on Monday)
public enum UsageEngine {}
