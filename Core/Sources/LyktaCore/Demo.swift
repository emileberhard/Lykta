import Foundation

public enum Demo {
    public static let title = "Lykta demo"

    public static func data(start: Date) -> JSONValue {
        .object([
            "agent": .string("Demo agent"),
            "task": .string("Showing what Lykta can do"),
            "start": .number(start.timeIntervalSince1970),
            "end": .number(start.timeIntervalSince1970 + 300),
        ])
    }

    public static let layout = try! JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {
          "lockScreen": {
            "vstack": [
              {
                "hstack": [
                  {"symbol": "sparkles", "modifiers": [{"font": "title2"}, {"foreground": "orange"}]},
                  {
                    "vstack": [
                      {"text": "{{agent}}", "modifiers": [{"font": "caption"}, {"foreground": "secondary"}]},
                      {"text": "{{task}}", "modifiers": [{"font": "headline"}, {"lineLimit": 1}]}
                    ],
                    "alignment": "leading",
                    "spacing": 2
                  },
                  {"spacer": true},
                  {
                    "timer": ["{{start}}", "{{end}}"],
                    "modifiers": [{"font": "title2"}, {"fontWeight": "semibold"}, {"monospacedDigit": true},
                                  {"multilineTextAlignment": "trailing"}, {"frame": {"width": 76}}]
                  }
                ],
                "spacing": 10
              },
              {"progress": ["{{start}}", "{{end}}"], "modifiers": [{"tint": "orange"}]}
            ],
            "spacing": 12,
            "modifiers": [{"padding": 16}]
          },
          "compactLeading": {"symbol": "sparkles", "modifiers": [{"foreground": "orange"}]},
          "compactTrailing": {
            "timer": ["{{start}}", "{{end}}"],
            "modifiers": [{"monospacedDigit": true}, {"multilineTextAlignment": "trailing"}, {"frame": {"width": 44}}]
          },
          "minimal": {"progress": ["{{start}}", "{{end}}"], "style": "circular", "modifiers": [{"tint": "orange"}]},
          "expanded": {
            "leading": {"symbol": "sparkles", "modifiers": [{"font": "title2"}, {"foreground": "orange"}]},
            "trailing": {
              "timer": ["{{start}}", "{{end}}"],
              "modifiers": [{"font": "title3"}, {"monospacedDigit": true}, {"multilineTextAlignment": "trailing"},
                            {"frame": {"width": 64}}]
            },
            "center": {"text": "{{task}}", "modifiers": [{"font": "headline"}, {"lineLimit": 1}]},
            "bottom": {"progress": ["{{start}}", "{{end}}"], "modifiers": [{"tint": "orange"}]}
          },
          "keyline": "orange"
        }
        """#.utf8))
}
