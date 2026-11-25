@LAZYGLOBAL OFF.
// Quick in-game test: proves the load, run and report loop works.
// Run with: npm run test:ingame -- smoke
// #include "0:/lib/telemetry.ks"
PARAMETER test_id, run_token.

RUNONCEPATH("0:/lib/telemetry.ks").
open_log("test-" + test_id).
PRINT "TEST-START " + run_token.
info_line("Test", test_id + ", vessel " + SHIP:NAME + ", status " + SHIP:STATUS
    + ", body " + SHIP:BODY:NAME + ", UT " + ROUND(TIME:SECONDS, 1) + " s").
check_line(telemetry_can_transmit(), "Archive connection", "home connection "
    + HOMECONNECTION:ISCONNECTED + ", status " + SHIP:STATUS
    + ", required so the log can be copied to the archive").
check_line(SHIP = KUNIVERSE:ACTIVEVESSEL, "Active vessel",
    "test CPU's vessel active=" + (SHIP = KUNIVERSE:ACTIVEVESSEL) + ", required TRUE").
check_line(KUNIVERSE:TIMEWARP:RATE <= 1.01, "Time warp",
    KUNIVERSE:TIMEWARP:RATE + "x, limit 1.01x").
info_line("Manoeuvre nodes", "CAREER():CANMAKENODES = " + CAREER():CANMAKENODES).
info_line("Delta-v", ROUND(SHIP:DELTAV:CURRENT, 1) + " m/s current, stage "
    + STAGE:NUMBER + ", " + ROUND(STAGE:DELTAV:CURRENT, 1) + " m/s in this stage").
end_test(run_token).
