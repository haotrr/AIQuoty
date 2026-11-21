import Foundation

public enum DemoFixtures {
    public static var claudeUsageJSON: Data {
        """
        {
          "five_hour": { "utilization": 0.42, "resetsAt": 1893456000 },
          "seven_day": { "utilization": 0.67, "resetsAt": 1893888000 },
          "seven_day_sonnet": { "utilization": 0.12, "resets_at": "2030-01-02T00:00:00Z" },
          "extra_usage": { "is_enabled": false },
          "subscriptionType": "pro"
        }
        """.data(using: .utf8)!
    }

    public static var codexUsageJSON: Data {
        """
        {
          "email": "demo@example.com",
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 55,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 2547,
              "reset_at": 1893456000
            },
            "secondary_window": {
              "used_percent": 31,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 489405,
              "reset_at": 1893888000
            }
          },
          "credits": { "has_credits": false, "balance": null }
        }
        """.data(using: .utf8)!
    }

    public static var cursorUsageJSON: Data {
        """
        {
          "email": "cursor-demo@example.com",
          "membershipType": "pro",
          "billingCycleEnd": "2030-02-01T00:00:00Z",
          "individualUsage": {
            "plan": { "usedPercent": 72, "billingCycleEnd": "2030-02-01T00:00:00Z" },
            "auto": { "usedPercent": 40 },
            "api": { "used": 12, "limit": 100 }
          }
        }
        """.data(using: .utf8)!
    }

    public static var geminiQuotaJSON: Data {
        """
        {
          "buckets": [
            { "modelId": "gemini-2.5-pro", "remainingFraction": 0.35, "resetTime": "2030-01-01T12:00:00Z" },
            { "modelId": "gemini-2.5-flash", "remainingFraction": 0.80, "resetTime": "2030-01-01T12:00:00Z" },
            { "modelId": "gemini-2.5-flash-lite", "remainingFraction": 0.95, "resetTime": "2030-01-01T06:00:00Z" }
          ]
        }
        """.data(using: .utf8)!
    }

    public static var copilotUserJSON: Data {
        """
        {
          "copilot_plan": "pro",
          "quota_reset_date": "2030-02-01",
          "quota_snapshots": {
            "premium_interactions": { "percent_remaining": 42 },
            "chat": { "percent_remaining": 88 }
          }
        }
        """.data(using: .utf8)!
    }

    public static var openRouterKeyJSON: Data {
        """
        { "data": { "label": "demo", "usage": 1.23, "limit": 50, "limit_remaining": 48.77 } }
        """.data(using: .utf8)!
    }

    public static var claudeCredentialsJSON: Data {
        """
        { "claudeAiOauth": { "accessToken": "sk-ant-oat-demo", "expiresAt": 1893456000000, "email": "claude@example.com" } }
        """.data(using: .utf8)!
    }

    public static var codexAuthJSON: Data {
        """
        { "tokens": { "access_token": "demo-access", "account_id": "acct_demo", "id_token": "e30." } }
        """.data(using: .utf8)!
    }

    public static var claudeLogJSONL: String {
        """
        {"type":"assistant","message":{"id":"msg_1","usage":{"input_tokens":10,"output_tokens":5}},"requestId":"req_1","sessionId":"s1"}
        {"type":"assistant","message":{"id":"msg_1","usage":{"input_tokens":12,"output_tokens":8}},"requestId":"req_1","sessionId":"s1"}
        {"type":"assistant","message":{"id":"msg_2","usage":{"input_tokens":3,"output_tokens":1,"cache_read_input_tokens":2}},"requestId":"req_2","sessionId":"s1"}
        """
    }
}
