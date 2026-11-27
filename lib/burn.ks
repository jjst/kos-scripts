@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"

LOCAL FUNCTION time_for_burn {
    PARAMETER delta_v.
    LOCAL available IS SHIP:AVAILABLETHRUST.
    IF available <= 0 { RETURN 0. }
    LOCAL modeled IS 0.
    LOCAL mass_flow IS 0.
    FOR eng IN SHIP:ENGINES {
        IF eng:IGNITION AND NOT eng:FLAMEOUT AND eng:AVAILABLETHRUST > 0 AND eng:VACUUMISP > 0 {
            SET modeled TO modeled + eng:AVAILABLETHRUST.
            SET mass_flow TO mass_flow + eng:AVAILABLETHRUST / (eng:VACUUMISP * CONSTANT:G0).
        }
    }
    IF mass_flow > 0 AND ABS(modeled - available) <= 0.01 {
        RETURN SHIP:MASS / mass_flow * (1 - CONSTANT:E^(-delta_v * mass_flow / modeled)).
    }
    RETURN delta_v * SHIP:MASS / available.
}

FUNCTION burn_duration {
    PARAMETER delta_v.
    RETURN time_for_burn(delta_v).
}

FUNCTION burn_lead {
    PARAMETER delta_v.
    RETURN time_for_burn(delta_v / 2).
}

LOCAL FUNCTION burn_vector {
    PARAMETER plan.
    LOCAL prograde_direction IS SHIP:VELOCITY:ORBIT:NORMALIZED.
    LOCAL radial_direction IS VXCL(prograde_direction, SHIP:POSITION - SHIP:BODY:POSITION):NORMALIZED.
    LOCAL normal_direction IS VCRS(radial_direction, prograde_direction):NORMALIZED.
    RETURN prograde_direction * plan["prograde"] + radial_direction * plan["radial"]
        + normal_direction * plan["normal"].
}

// Plan UT is the impulsive burn time. The caller owns the telemetry log.
FUNCTION execute_burn {
    PARAMETER plan, options.
    LOCAL use_node IS CAREER():CANMAKENODES.
    IF options:HASKEY("use_node") { SET use_node TO use_node AND options["use_node"]. }
    LOCAL path_name IS "no-node".
    IF use_node { SET path_name TO "node". }
    LOCAL planned_dv IS V(plan["prograde"], plan["normal"], plan["radial"]):MAG.
    LOCAL duration IS burn_duration(planned_dv).
    LOCAL lead IS burn_lead(planned_dv).
    LOCAL ignition_ut IS plan["ut"] - lead.
    LOCAL ignition_deadline IS ignition_ut + 5.
    LOCAL warp_buffer IS 30.
    LOCAL throttle_cmd IS 0.
    LOCAL delivered_dv IS 0.
    LOCAL remaining_dv IS planned_dv.
    LOCAL controls_locked IS FALSE.
    LOCAL had_sas IS SAS.
    LOCAL node_added IS FALSE.
    LOCAL burn_node IS 0.
    LOCAL pointing_limit IS 5.
    LOCAL cutoff_tolerance IS 0.1.
    LOCAL next_status IS 0.

    FUNCTION burn_flight_ready {
        RETURN SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:UNPACKED
            AND KUNIVERSE:TIMEWARP:ISSETTLED AND KUNIVERSE:TIMEWARP:RATE <= 1.01.
    }

    FUNCTION finish_burn {
        PARAMETER success, reason.
        log_line("Burn cutoff: " + reason + ", " + path_name + " path, UT " + ROUND(TIME:SECONDS, 2)
            + " s, throttle " + ROUND(throttle_cmd, 3) + ", thrust " + ROUND(SHIP:THRUST, 2) + " kN.").
        IF controls_locked {
            SET throttle_cmd TO 0.
            WAIT 0.
            UNLOCK THROTTLE.
            UNLOCK STEERING.
            SET SAS TO had_sas.
        }
        IF SHIP = KUNIVERSE:ACTIVEVESSEL {
            IF KUNIVERSE:TIMEWARP:RATE > 1.01 { KUNIVERSE:TIMEWARP:CANCELWARP(). }
            IF node_added { REMOVE burn_node. }
        }
        log_line("Burn result: success=" + success + ", " + reason + ", delivered "
            + ROUND(delivered_dv, 3) + "/" + ROUND(planned_dv, 3) + " m/s, residual "
            + ROUND(remaining_dv, 3) + " m/s, Ap " + ROUND(SHIP:APOAPSIS, 1)
            + " m, Pe " + ROUND(SHIP:PERIAPSIS, 1) + " m, period " + ROUND(SHIP:OBT:PERIOD, 2) + " s.").
        transmit_log().
        RETURN LEXICON("success", success, "reason", reason, "path", path_name, "delivered_dv", delivered_dv).
    }

    IF NOT check_line(burn_flight_ready() AND duration > 0 AND planned_dv > cutoff_tolerance
        AND TIME:SECONDS < ignition_ut, "Burn preflight", path_name + " path, planned "
        + ROUND(planned_dv, 3) + " m/s (minimum > 0.1 m/s), " + ROUND(SHIP:AVAILABLETHRUST, 2)
        + " kN available (required > 0 kN), ignition in " + ROUND(ignition_ut - TIME:SECONDS, 2)
        + " s (required > 0 s), flight ready=" + burn_flight_ready()) {
        RETURN finish_burn(FALSE, "burn preflight failed").
    }
    IF use_node {
        SET burn_node TO NODE(plan["ut"], plan["radial"], plan["normal"], plan["prograde"]).
        ADD burn_node.
        SET node_added TO TRUE.
        info_line("Node prediction", "Ap " + ROUND(burn_node:ORBIT:APOAPSIS, 1)
            + " m, Pe " + ROUND(burn_node:ORBIT:PERIAPSIS, 1) + " m").
    }
    log_line(plan["label"] + ": " + ROUND(planned_dv, 3) + " m/s, scheduled UT "
        + ROUND(plan["ut"], 2) + " s, lead " + ROUND(lead, 2) + " s, " + path_name + " path.").
    transmit_log().
    IF ignition_ut > TIME:SECONDS + warp_buffer {
        KUNIVERSE:TIMEWARP:WARPTO(ignition_ut - warp_buffer).
    }

    LOCAL burn_direction IS burn_vector(plan).
    UNTIL TIME:SECONDS >= ignition_deadline OR SHIP <> KUNIVERSE:ACTIVEVESSEL {
        IF burn_flight_ready() AND TIME:SECONDS >= ignition_ut - warp_buffer {
            IF NOT controls_locked {
                SAS OFF.
                LOCK THROTTLE TO throttle_cmd.
                LOCK STEERING TO burn_direction.
                SET controls_locked TO TRUE.
            }
            IF use_node {
                SET burn_direction TO burn_node:DELTAV.
            } ELSE {
                SET burn_direction TO burn_vector(plan).
            }
            IF TIME:SECONDS >= ignition_ut AND VANG(SHIP:FACING:FOREVECTOR, burn_direction) <= pointing_limit {
                BREAK.
            }
        }
        IF TIME:SECONDS >= next_status {
            SET next_status TO TIME:SECONDS + 2.
            CLEARSCREEN.
            PRINT plan["label"] + " in " + MAX(0, CEILING(ignition_ut - TIME:SECONDS)) + " s.".
            PRINT "Stay on this vessel.".
        }
        checkpoint_log("Waiting for " + plan["label"]).
        WAIT 0.
    }
    LOCAL pointing_error IS VANG(SHIP:FACING:FOREVECTOR, burn_direction).
    IF NOT check_line(TIME:SECONDS < ignition_deadline AND burn_flight_ready() AND pointing_error <= pointing_limit,
        "Burn ignition", "pointing error " + ROUND(pointing_error, 2) + " deg, limit " + pointing_limit
        + " deg, ignition delay " + ROUND(TIME:SECONDS - ignition_ut, 2)
        + " s, limit 5 s, flight ready=" + burn_flight_ready()) {
        RETURN finish_burn(FALSE, "ignition window missed").
    }
    LOCAL initial_direction IS burn_direction.
    LOCAL burn_deadline IS TIME:SECONDS + MAX(15, 3 * duration).
    SET next_status TO 0.
    LOCAL step_ut IS TIME:SECONDS.
    LOCAL thrust_deadline IS step_ut + 2.
    UNTIL remaining_dv <= cutoff_tolerance {
        IF NOT burn_flight_ready() { RETURN finish_burn(FALSE, "lost flight controls"). }
        IF SHIP:AVAILABLETHRUST <= 0 { RETURN finish_burn(FALSE, "no available thrust"). }
        IF TIME:SECONDS >= burn_deadline { RETURN finish_burn(FALSE, "burn time limit reached"). }
        IF delivered_dv <= 0 AND TIME:SECONDS >= thrust_deadline {
            RETURN finish_burn(FALSE, "no measured thrust within 2 s").
        }
        IF options:HASKEY("cutoff") {
            LOCAL cutoff_test IS options["cutoff"].
            IF cutoff_test:CALL() { RETURN finish_burn(TRUE, "caller cutoff reached"). }
        }
        IF use_node {
            SET burn_direction TO burn_node:DELTAV.
            SET remaining_dv TO burn_direction:MAG.
            IF remaining_dv <= cutoff_tolerance { BREAK. }
            IF VDOT(initial_direction, burn_direction) < 0 {
                RETURN finish_burn(TRUE, "node burn vector reversed").
            }
        }
        IF VANG(SHIP:FACING:FOREVECTOR, burn_direction) > pointing_limit {
            RETURN finish_burn(FALSE, "burn pointing error exceeded 5 deg").
        }
        SET throttle_cmd TO MAX(0.02, MIN(1, remaining_dv / 2)).
        IF TIME:SECONDS >= next_status {
            SET next_status TO TIME:SECONDS + 1.
            log_line("Burn sample: residual " + ROUND(remaining_dv, 3) + " m/s, delivered "
                + ROUND(delivered_dv, 3) + " m/s, throttle " + ROUND(throttle_cmd, 3)
                + ", thrust " + ROUND(SHIP:THRUST, 2) + " kN.", FALSE).
        }
        checkpoint_log("").
        WAIT 0.
        SET delivered_dv TO delivered_dv + SHIP:THRUST / SHIP:MASS * (TIME:SECONDS - step_ut).
        SET step_ut TO TIME:SECONDS.
        IF NOT use_node { SET remaining_dv TO MAX(0, planned_dv - delivered_dv). }
    }
    RETURN finish_burn(TRUE, "remaining delta-v within 0.1 m/s").
}
