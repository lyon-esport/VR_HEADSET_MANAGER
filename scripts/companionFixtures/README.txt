Companion probe fixtures (T6.1, ADR-0046). Shared by scripts\Test-CompanionProbes.ps1 and the
Kotlin ProbeParsersTest (T6.2). UTF-8 no BOM, LF.

Layout: <probe id>\<fixture>.txt + <probe id>\expected.json
  expected.json = { "<fixture file>": { "<wire field>": value-or-null, ... } } (every field listed).
  battery_power fixtures also have <name>.intent.json (battery intent for the Kotlin mapper).

Naming: q3_*  real output captured from a Quest 3 (Q3 BLUE, Horizon 209, 2026-11-07).
        synthetic_*  hand-written to cover a case the bench headset cannot produce.

Capture a real one (read-only adb, runs the CATALOGUE command):
  .\scripts\Capture-CompanionFixtures.ps1 -DeviceId 192.168.1.243:5555 -Probe controllers -Name q3_connected
Then add its entry to expected.json (reviewed by hand).

TODO (operator): controllers\q3_connected.txt - needs both controllers AWAKE and connected when
captured (the bench capture only had them asleep, ExternalStatus SEARCHING). synthetic_connected.txt
covers the parse rule until then. Expected for it: ctrlLeftState/ctrlRightState "connected" with levels.