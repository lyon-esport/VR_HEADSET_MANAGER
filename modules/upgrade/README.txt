modules\upgrade - one-time upgrade steps run at the first start of a new release.

Naming contract: <release core version>.ps1, for example 2026-11.RC1.2.ps1
(the core version is YYYY-MM.RCn[.minor[.patch]], without a V prefix or +dev suffix).

Each file defines ONE function, Invoke-UpgradeStep, and does nothing else at load time.
Invoke-UpgradeStep takes no parameters; $global:ScriptPath is the install root.

Invoke-AppUpgradeSteps (modules\vrhm_update.ps1) runs, at the first start after an update,
every file whose version V satisfies: last applied version < V <= current version,
in ascending version order, once. The result is recorded in data\update\applied.json.

A failure is logged as ERROR and stops the remaining steps; the failed step is retried at
the next start (applied.json is only advanced past the steps that succeeded).

Keep the files ASCII only. This folder is NOT auto-loaded by the module glob.
