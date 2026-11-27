@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/burn.ks"
PARAMETER test_id, run_token.

RUNONCEPATH("0:/lib/telemetry.ks").
RUNONCEPATH("0:/lib/burn.ks").
open_log("test-" + test_id).
PRINT "TEST-START " + run_token.

LOCAL physics_deadline IS TIME:SECONDS + 30.
WAIT UNTIL (SHIP:UNPACKED AND KUNIVERSE:TIMEWARP:ISSETTLED) OR TIME:SECONDS >= physics_deadline.
LOCAL initial_ap IS SHIP:APOAPSIS.
LOCAL initial_pe IS SHIP:PERIAPSIS.
LOCAL parking_ok IS check_line(SHIP:STATUS = "ORBITING" AND SHIP:BODY:NAME = "Kerbin"
    AND ABS(initial_ap - initial_pe) <= 500, "Burn parking orbit", SHIP:BODY:NAME + " / " + SHIP:STATUS
    + ", Ap " + ROUND(initial_ap, 1) + " m, Pe " + ROUND(initial_pe, 1) + " m (spread limit 500 m)").
LOCAL options IS LEXICON().
SET options TO READJSON("0:/tests/options/" + test_id + ".json").
LOCAL node_allowed IS check_line(NOT options["use_node"] OR CAREER():CANMAKENODES, "Burn path available",
    "node requested=" + options["use_node"] + ", nodes available=" + CAREER():CANMAKENODES).
IF parking_ok AND node_allowed {
    LOCAL apoapsis_target IS initial_ap + 10000.
    LOCAL orbit_tolerance IS 400.
    LOCAL dv_tolerance IS 0.25.
    LOCAL mu_body IS SHIP:BODY:MU.
    LOCAL start_radius IS SHIP:BODY:RADIUS + (initial_ap + initial_pe) / 2.
    LOCAL end_radius IS SHIP:BODY:RADIUS + apoapsis_target.
    LOCAL transfer_axis IS (start_radius + end_radius) / 2.
    LOCAL planned_dv IS SQRT(mu_body * (2 / start_radius - 1 / transfer_axis)) - SQRT(mu_body / start_radius).
    LOCAL burn_plan IS LEXICON("ut", TIME:SECONDS + 45, "prograde", planned_dv, "normal", 0, "radial", 0,
        "label", "Raise apoapsis").
    info_line("Test targets", "Ap " + ROUND(apoapsis_target, 1) + " m, Pe " + ROUND(initial_pe, 1)
        + " m, tolerance " + orbit_tolerance + " m each, delta-v tolerance " + dv_tolerance + " m/s").
    LOCAL result IS execute_burn(burn_plan, options).
    check_line(result["success"], "Burn completion", result["path"] + " path, " + result["reason"]).
    check_line(ABS(result["delivered_dv"] - planned_dv) <= dv_tolerance, "Delivered delta-v",
        ROUND(result["delivered_dv"], 3) + " m/s, target " + ROUND(planned_dv, 3) + " m/s, tolerance " + dv_tolerance + " m/s").
    check_line(ABS(SHIP:APOAPSIS - apoapsis_target) <= orbit_tolerance, "Resulting apoapsis",
        ROUND(SHIP:APOAPSIS, 1) + " m, target " + ROUND(apoapsis_target, 1) + " m, tolerance " + orbit_tolerance + " m").
    check_line(ABS(SHIP:PERIAPSIS - initial_pe) <= orbit_tolerance, "Resulting periapsis",
        ROUND(SHIP:PERIAPSIS, 1) + " m, target " + ROUND(initial_pe, 1) + " m, tolerance " + orbit_tolerance + " m").
    IF options["use_node"] {
        check_line(NOT HASNODE, "Burn node cleanup", ALLNODES:LENGTH + " nodes remaining, required 0").
    }
}
end_test(run_token).
