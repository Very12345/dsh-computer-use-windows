# DSH Windows desktop plugin

- Keep this an independent DSH 0.2 plugin. Browser automation belongs to other plugins.
- Do not copy or ship OpenAI binaries, private runtime packages or proprietary source.
- Preserve MIT provenance of native/windows-uia.ps1 and upstream licenses.
- Inputs are never replayed automatically. Consume state before dispatch; report ambiguous effects honestly.
- Preserve app identity and per-agent observation isolation; all agents share one desktop queue.
- Keep native backend target validation even when Node has already validated the window.
- Run npm test, the Windows smoke test for input/backend changes, and npm pack --dry-run.
- Smoke tests operate uniquely owned temporary documents, never existing user documents.
- Keep screenshots, local settings, credentials and test documents out of Git and package contents.
