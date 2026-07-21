# Accessibility

Forge targets WCAG 2.2 AA for applicable native content. Primary actions must be keyboard reachable, expose role/name/state/action semantics, retain logical focus, support 200% text and high contrast, and provide at least 48×48 dp primary touch targets.

Current shell checks cover labeled controls, touch geometry, responsive text scaling, shortcut reachability, safe errors, and semantic headings. Automated checks cannot establish screen-reader usability. TalkBack, VoiceOver, Narrator, and each claimed Linux AT-SPI combination require isolated physical or packaged evidence listed in `docs/support/external-evidence.md`.

Report accessibility failures as functional defects. Include platform/OS, input or assistive technology, route, expected action, actual result, and synthetic screenshots or recordings only. Do not include private content. A verified platform limitation must have a tested alternative and a public capability record.
