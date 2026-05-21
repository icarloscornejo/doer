# Advisor Personas

Each file in this directory defines one advisor persona used by the `/wk:advise` skill. Personas are JSON files. Adding a new persona requires only dropping a valid JSON file here; no code changes are needed.

## JSON shape

```json
{
  "id": "unique-kebab-id",
  "display_name": "Human-readable name shown in /wk:advise --list",
  "summary": "One-line description of what this persona looks for.",
  "system_prompt": "Multi-paragraph prompt that primes the reviewer agent. Em-dashes prohibited.",
  "focus_checklist": [
    "Item the persona actively checks for.",
    "..."
  ],
  "out_of_scope": [
    "Item this persona explicitly ignores.",
    "..."
  ],
  "severity_scale": {
    "blocker": "Definition of a blocker-severity finding for this persona.",
    "high":    "Definition of a high-severity finding.",
    "medium":  "Definition of a medium-severity finding.",
    "low":     "Definition of a low-severity finding."
  },
  "output_schema": {
    "findings": [
      {
        "severity": "blocker | high | medium | low",
        "title": "Short title.",
        "where": "<file>:<line> or <ac-id> or 'spec'",
        "explain": "What the issue is and why it matters.",
        "fix": "Concrete remediation."
      }
    ]
  }
}
```

## Personas shipped by default

| id              | Display name          | Focus area                                           |
|-----------------|-----------------------|------------------------------------------------------|
| security        | Security Advisor      | Vulnerabilities, auth, secrets, injection            |
| performance     | Performance Advisor   | N+1 queries, memory, I/O, scalability                |
| mobile          | Mobile Advisor        | Lifecycle, battery, offline, platform APIs           |
| accessibility   | Accessibility Advisor | WCAG 2.1 AA, keyboard navigation, screen readers     |
| api             | API Advisor           | REST/GraphQL contracts, versioning, error shapes     |

## Adding a new persona

1. Create `lib/advisor-personas/<id>.json` matching the shape above.
2. Set `id` to the same value as the filename (without `.json`).
3. Write a `system_prompt` of 150 to 300 words. Em-dashes (U+2014, U+2013) are prohibited.
4. Add at least 6 items to `focus_checklist`.
5. Run `jq empty lib/advisor-personas/<id>.json` to confirm the file is valid JSON.

No registration or code change is needed. The `/wk:advise --list` command reads this directory at runtime.
