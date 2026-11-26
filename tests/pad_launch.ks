@LAZYGLOBAL OFF.
// In-game test: launch_to_orbit from the pad, judged by its own checks.
// Run with: npm run test:ingame -- pad-launch-80km or pad-launch-120km
// The craft-specific launch options come from tests/tests.json; the runner
// writes them to 0:/tests/options/<test id>.json before loading the save.
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/launch.ks"
PARAMETER test_id, run_token.

RUNONCEPATH("0:/lib/telemetry.ks").
RUNONCEPATH("0:/lib/launch.ks").
open_log("test-" + test_id).
PRINT "TEST-START " + run_token.
LOCAL options_path IS "0:/tests/options/" + test_id + ".json".
// KSP keeps a vessel packed (no physics) for a moment after a load.
LOCAL physics_deadline IS TIME:SECONDS + 30.
WAIT UNTIL (SHIP:UNPACKED AND KUNIVERSE:TIMEWARP:ISSETTLED) OR TIME:SECONDS >= physics_deadline.
LOCAL physics_ready IS check_line(SHIP:UNPACKED AND KUNIVERSE:TIMEWARP:ISSETTLED, "Physics after load",
    "unpacked=" + SHIP:UNPACKED + ", warp settled=" + KUNIVERSE:TIMEWARP:ISSETTLED + ", waited up to 30 s").
LOCAL options_ready IS check_line(EXISTS(options_path), "Test options", options_path
    + " present=" + EXISTS(options_path) + ", written by npm run test:ingame").
IF physics_ready AND options_ready {
    LOCAL options IS READJSON(options_path).
    // launch_to_orbit logs the values it uses in its "Launch target" line.
    info_line("Launch options", "keys " + options:KEYS:JOIN(", ")).
    LOCAL started_at IS TIME:SECONDS.
    LOCAL result IS launch_to_orbit(options).
    info_line("Launch duration", ROUND(TIME:SECONDS - started_at, 1)
        + " s from the start of the countdown to the end of the launch").
    info_line("Launch outcome", "success=" + result["success"] + ", " + result["reason"]).
}
end_test(run_token).
