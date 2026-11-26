@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/jeblink.ks"
PARAMETER test_id, run_token.

RUNONCEPATH("0:/lib/telemetry.ks").
RUNONCEPATH("0:/lib/jeblink.ks").
open_log("test-" + test_id).
PRINT "TEST-START " + run_token.

LOCAL physics_deadline IS TIME:SECONDS + 30.
WAIT UNTIL (SHIP:UNPACKED AND KUNIVERSE:TIMEWARP:ISSETTLED) OR TIME:SECONDS >= physics_deadline.
LOCAL physics_ready IS check_line(SHIP:UNPACKED AND KUNIVERSE:TIMEWARP:ISSETTLED, "Physics after load",
    "unpacked=" + SHIP:UNPACKED + ", warp settled=" + KUNIVERSE:TIMEWARP:ISSETTLED + ", waited up to 30 s").
LOCAL mounted_relays IS SHIP:PARTSNAMED("probeCoreCube"):LENGTH.
LOCAL layout_ready IS check_line(mounted_relays = 4, "Relay layout",
    mounted_relays + " mounted, required 4 before deployment").
IF physics_ready AND layout_ready {
    LOCAL success IS jeblink_deploy_constellation(4, FALSE, 1).
    check_line(success, "Relay deployment",
        "requires carrier phasing, one separation, and a verified circularisation report").
}
end_test(run_token).
