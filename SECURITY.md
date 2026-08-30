# Security policy

## Supported versions

Security fixes are applied to the current `main` branch and the latest published release. Older releases should be upgraded before requesting a backport.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use the repository host's private security-advisory channel or contact the maintainers privately through the project profile. Include reproduction steps, affected versions, impact, and any suggested mitigation. Do not include live credentials or customer data.

You can expect an acknowledgement within five business days. The maintainers will validate the report, coordinate a fix and disclosure timeline, and credit the reporter unless anonymity is requested.

## Scope

Reports are especially useful for:

- command or argument injection in executor adapters;
- credential exposure in logs, prompts, results, or Git history;
- unsafe cross-repository writer overlap;
- lease/recovery behavior that can corrupt or duplicate work;
- path traversal outside `SALMON_RUN_HOME` or a configured target repository;
- forged or stale gate results that bypass quality stages.

The project does not accept real secrets in test cases. Use obviously synthetic values and run `scripts/Invoke-LeakCheck.ps1` before submission.