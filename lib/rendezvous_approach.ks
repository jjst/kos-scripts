@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/burn.ks"
// #include "0:/lib/rendezvous.ks"
// #include "0:/lib/rcs.ks"

FUNCTION fly_rendezvous_approach {
    PARAMETER station_name.
    LOCAL stations IS LIST().
    LIST TARGETS IN stations.
    LOCAL matches IS LIST().
    FOR vessel_item IN stations {
        IF vessel_item:NAME = station_name { matches:ADD(vessel_item). }
    }
    IF NOT check_line(matches:LENGTH = 1, "Target station",
        station_name + ", " + matches:LENGTH + " matching vessels, required 1") { RETURN. }

    LOCAL station IS matches[0].
    LOCAL safety_distance IS 50.
    LOCAL handoff_distance IS 100.
    LOCAL match_tolerance IS 0.30.
    LOCAL approach_limit IS 5000.
    LOCAL closing_limit IS 40.
    LOCAL braking_turn_time IS 8.
    LOCAL stop_distance IS 85.
    LOCAL engine_starts IS 0.
    LOCAL had_rcs IS RCS.
    LOCAL translating IS FALSE.
    LOCAL throttle_cmd IS 0.
    LOCAL burn_direction IS SHIP:FACING:FOREVECTOR.
    LOCAL controls_locked IS FALSE.
    LOCAL had_sas IS SAS.
    LOCAL last_burn IS "No burn started.".
    LOCAL phase_name IS "Preflight".
    LOCAL next_display IS 0.
    LOCAL next_sample IS 0.

    LOCAL FUNCTION flight_ready {
        RETURN SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:UNPACKED
            AND KUNIVERSE:TIMEWARP:ISSETTLED AND KUNIVERSE:TIMEWARP:RATE <= 1.01.
    }

    LOCAL FUNCTION closing_command {
        PARAMETER distance_m.
        // Leave room to measure braking authority before entering the close approach.
        LOCAL acceleration IS 1.
        LOCAL remaining IS MAX(0, distance_m - stop_distance).
        LOCAL stopping_speed IS acceleration * (SQRT(braking_turn_time^2
            + 2 * remaining / acceleration) - braking_turn_time).
        RETURN MIN(0.90 * closing_limit, stopping_speed).
    }

    LOCAL FUNCTION measure_approach {
        LOCAL separation IS station:POSITION - SHIP:POSITION.
        LOCAL distance_m IS separation:MAG.
        LOCAL line_of_sight IS separation / MAX(0.01, distance_m).
        LOCAL relative_motion IS SHIP:VELOCITY:ORBIT - station:VELOCITY:ORBIT.
        LOCAL closing_speed IS VDOT(relative_motion, line_of_sight).
        RETURN LEXICON("offset", separation, "distance", distance_m, "bearing", line_of_sight,
            "velocity", relative_motion, "speed", relative_motion:MAG,
            "closing", closing_speed, "sideways", (relative_motion - line_of_sight * closing_speed):MAG).
    }

    LOCAL FUNCTION describe_approach {
        PARAMETER sample.
        RETURN "range " + ROUND(sample["distance"], 1) + " m, relative speed "
            + ROUND(sample["speed"], 2) + " m/s, closing " + ROUND(sample["closing"], 2)
            + " m/s, sideways " + ROUND(sample["sideways"], 2) + " m/s".
    }

    LOCAL FUNCTION begin_phase {
        PARAMETER label, detail.
        SET phase_name TO label.
        SET next_display TO 0.
        SET next_sample TO 0.
        log_line(label + ". " + detail).
        transmit_log().
    }

    LOCAL FUNCTION approach_status {
        PARAMETER sample, next_action.
        IF KUNIVERSE:REALTIME >= next_display {
            SET next_display TO KUNIVERSE:REALTIME + 2.
            CLEARSCREEN.
            PRINT next_action.
            PRINT "Stay on " + SHIP:NAME + ". Press any key to abort.".
            PRINT describe_approach(sample) + ".".
        }
        IF KUNIVERSE:REALTIME >= next_sample {
            SET next_sample TO KUNIVERSE:REALTIME + 5.
            log_line(phase_name + " sample. " + describe_approach(sample)
                + ", throttle " + ROUND(throttle_cmd, 3) + ".", FALSE).
        }
        checkpoint_log("").
    }

    LOCAL FUNCTION clear_controls {
        IF SHIP = KUNIVERSE:ACTIVEVESSEL AND KUNIVERSE:TIMEWARP:RATE > 1.01 {
            KUNIVERSE:TIMEWARP:CANCELWARP().
        }
        IF controls_locked {
            SET throttle_cmd TO 0.
            IF translating {
                SET SHIP:CONTROL:TRANSLATION TO V(0, 0, 0).
                SET SHIP:CONTROL:NEUTRALIZE TO TRUE.
                SET RCS TO had_rcs.
            }
            WAIT 0.
            UNLOCK THROTTLE.
            UNLOCK STEERING.
            SET SAS TO had_sas.
        }
        CLEARSCREEN.
    }

    LOCAL FUNCTION abort_approach {
        PARAMETER abort_detail.
        LOCAL detail IS phase_name + " stopped. " + abort_detail + " " + last_burn
            + " " + describe_approach(measure_approach()) + ", throttle "
            + ROUND(throttle_cmd, 3) + ", measured thrust " + ROUND(SHIP:THRUST, 2)
            + " kN, starts commanded " + engine_starts + ".".
        SET throttle_cmd TO 0.
        check_line(FALSE, "Approach aborted", detail).
        clear_controls().
        PRINT detail.
        PRINT "Check the separation and relative velocity before retrying.".
        PRINT "For the test, reload __test_rendezvous_transfer.".
        transmit_log().
    }

    LOCAL FUNCTION flight_stop_reason {
        IF TERMINAL:INPUT:HASCHAR {
            LOCAL abort_key IS TERMINAL:INPUT:GETCHAR().
            TERMINAL:INPUT:CLEAR().
            RETURN "Operator abort key " + UNCHAR(abort_key) + ".".
        }
        IF SHIP <> KUNIVERSE:ACTIVEVESSEL { RETURN "Lost the active vessel.". }
        IF SHIP:STATUS <> "ORBITING" OR station:STATUS <> "ORBITING" OR SHIP:BODY <> station:BODY {
            RETURN "Both vessels must remain in orbit around the same body.".
        }
        RETURN "".
    }

    LOCAL FUNCTION proximity_stop_reason {
        PARAMETER sample, braking_authority IS 0.
        IF sample["distance"] <= safety_distance {
            RETURN "Separation reached the " + safety_distance + " m safety floor.".
        }
        IF braking_authority > 0 {
            IF sample["closing"] > closing_limit {
                RETURN "Closing speed exceeded " + closing_limit + " m/s.".
            }
            LOCAL inbound_speed IS MAX(0, sample["closing"]).
            LOCAL stopping_range IS sample["distance"] - 0.2 * inbound_speed
                - inbound_speed^2 / (2 * braking_authority).
            IF stopping_range < safety_distance {
                RETURN "Predicted braking stop at " + ROUND(stopping_range, 1)
                    + " m is inside the " + safety_distance + " m safety floor.".
            }
            RETURN "".
        }
        // Before the intercept, the unpowered trajectory must also clear the station.
        IF sample["closing"] > 0 AND sample["speed"] > 0.5 {
            LOCAL relative_motion IS sample["velocity"].
            LOCAL pass_time IS MIN(braking_turn_time + 5,
                VDOT(sample["offset"], relative_motion) / VDOT(relative_motion, relative_motion)).
            LOCAL pass_distance IS (sample["offset"] - relative_motion * pass_time):MAG.
            IF pass_distance < safety_distance {
                RETURN "Predicted pass " + ROUND(pass_distance, 1) + " m in "
                    + ROUND(pass_time, 1) + " s (minimum " + safety_distance + " m).".
            }
        }
        RETURN "".
    }

    LOCAL FUNCTION run_main_burn {
        PARAMETER label, desired_speed, ignition_ut, main_braking IS FALSE.
        LOCAL sample IS measure_approach().
        SET last_burn TO label + " did not ignite.".
        begin_phase(label, "Before burn, " + describe_approach(sample)
            + ", commanded approach speed " + ROUND(desired_speed, 2) + " m/s.").
        LOCAL deadline IS ignition_ut + 45.
        LOCAL velocity_tolerance IS match_tolerance.
        IF desired_speed > 0 { SET velocity_tolerance TO 0.20. }
        LOCAL thrust_deadline IS 0.
        LOCAL burn_started IS FALSE.
        LOCAL measured_thrust IS FALSE.

        UNTIL TIME:SECONDS >= deadline {
            LOCAL burn_stop IS flight_stop_reason().
            IF burn_stop <> "" { RETURN burn_stop. }
            IF NOT flight_ready() { RETURN "Lost settled 1x flight controls.". }
            SET sample TO measure_approach().
            LOCAL available IS SHIP:AVAILABLETHRUST.
            IF available <= 0 { RETURN "No available engine thrust.". }
            LOCAL acceleration IS available / SHIP:MASS.
            IF main_braking {
                SET burn_stop TO proximity_stop_reason(sample, 0.8 * acceleration).
            } ELSE {
                SET burn_stop TO proximity_stop_reason(sample).
            }
            IF burn_stop <> "" { RETURN burn_stop. }
            LOCAL velocity_error IS sample["bearing"] * desired_speed - sample["velocity"].
            LOCAL residual IS velocity_error:MAG.
            IF residual <= velocity_tolerance { BREAK. }
            SET burn_direction TO velocity_error.
            LOCAL pointing_error IS VANG(SHIP:FACING:FOREVECTOR, burn_direction).
            IF NOT burn_started AND TIME:SECONDS >= ignition_ut AND pointing_error <= 8 {
                SET burn_started TO TRUE.
                SET engine_starts TO engine_starts + 1.
                SET thrust_deadline TO TIME:SECONDS + 2.
                log_line(label + " ignition " + engine_starts + ". " + describe_approach(sample)
                    + ", pointing error " + ROUND(pointing_error, 1) + " deg.").
            }
            IF burn_started {
                IF pointing_error > 25 { RETURN "Pointing error exceeded 25 deg after ignition.". }
                LOCAL needed_acceleration IS residual / 0.6.
                // Throttle stays positive from ignition until cutoff. A
                // pointing loss aborts the burn without attempting a restart.
                SET throttle_cmd TO MAX(0.01, MIN(1, needed_acceleration / acceleration)).
            }
            IF burn_started AND SHIP:THRUST > 0 {
                SET measured_thrust TO TRUE.
                SET last_burn TO label + " ignited but did not finish.".
            }
            IF burn_started AND NOT measured_thrust AND TIME:SECONDS >= thrust_deadline {
                RETURN "No measured thrust within 2 s of commanding throttle.".
            }
            LOCAL next_action IS label + " in " + MAX(0, CEILING(ignition_ut - TIME:SECONDS)) + " s.".
            IF TIME:SECONDS >= ignition_ut { SET next_action TO label + " once aligned.". }
            IF throttle_cmd > 0 { SET next_action TO label + " in progress.". }
            approach_status(sample, next_action).
            WAIT 0.
        }

        SET throttle_cmd TO 0.
        WAIT 0.
        SET sample TO measure_approach().
        LOCAL error_after IS (sample["bearing"] * desired_speed - sample["velocity"]):MAG.
        IF NOT check_line(TIME:SECONDS < deadline AND error_after <= velocity_tolerance + 0.02,
            label, "after cutoff, " + describe_approach(sample) + ", velocity error "
            + ROUND(error_after, 3) + " m/s (limit " + (velocity_tolerance + 0.02) + " m/s)") {
            RETURN "The velocity target was not reached before the burn deadline.".
        }
        IF measured_thrust {
            SET last_burn TO label + " completed.".
        } ELSE {
            SET last_burn TO label + " needed no thrust.".
        }
        transmit_log().
        RETURN "".
    }

    LOCAL FUNCTION coast_to_main_brake {
        PARAMETER rcs_speed.
        LOCAL sample IS measure_approach().
        LOCAL deadline IS TIME:SECONDS + 300.
        begin_phase("Coast to main braking", describe_approach(sample)
            + ". Turning for one braking burn near 195 m, followed by RCS.").
        UNTIL TIME:SECONDS >= deadline {
            LOCAL braking_stop IS flight_stop_reason().
            IF braking_stop <> "" { RETURN braking_stop. }
            IF NOT flight_ready() { RETURN "Lost settled 1x flight controls during the coast.". }
            SET sample TO measure_approach().
            LOCAL acceleration IS SHIP:AVAILABLETHRUST / SHIP:MASS.
            IF acceleration <= 0 { RETURN "No main engine thrust available for braking.". }
            SET braking_stop TO proximity_stop_reason(sample, 0.8 * acceleration).
            IF braking_stop <> "" { RETURN braking_stop. }
            IF sample["closing"] <= rcs_speed { RETURN "". }
            SET burn_direction TO sample["bearing"] * rcs_speed - sample["velocity"].
            LOCAL braking_travel IS sample["closing"] * 0.3
                + (sample["closing"]^2 - rcs_speed^2) / (2 * 0.8 * acceleration).
            LOCAL ignition_range IS MAX(195, 115 + braking_travel).
            IF sample["distance"] <= ignition_range {
                IF VANG(SHIP:FACING:FOREVECTOR, burn_direction) > 8 {
                    RETURN "The probe did not finish turning before the braking point.".
                }
                RETURN run_main_burn("Main braking", rcs_speed, TIME:SECONDS, TRUE).
            }
            approach_status(sample, "Main braking in about " + MAX(0, CEILING(
                (sample["distance"] - ignition_range) / sample["closing"])) + " s.").
            WAIT 0.
        }
        RETURN "The main braking point was not reached before the coast deadline.".
    }

    LOCAL FUNCTION close_with_rcs {
        PARAMETER cruise_speed.
        LOCAL sample IS measure_approach().
        LOCAL close_start IS TIME:SECONDS.
        LOCAL hold_attitude IS SHIP:FACING.
        LOCK STEERING TO hold_attitude.
        SET translating TO TRUE.
        RCS ON.
        begin_phase("RCS approach", "Holding attitude. " + describe_approach(sample)
            + ", closing limit " + closing_limit + " m/s, planned stop near " + stop_distance + " m.").

        LOCAL probe_direction IS -sample["bearing"].
        LOCAL velocity_before IS sample["velocity"].
        LOCAL probe_start IS TIME:SECONDS.
        UNTIL TIME:SECONDS >= probe_start + 0.6 {
            LOCAL probe_stop IS flight_stop_reason().
            IF probe_stop <> "" { RETURN probe_stop. }
            IF NOT flight_ready() { RETURN "Lost settled 1x flight controls during the RCS check.". }
            rcs_translate(probe_direction).
            WAIT 0.
        }
        rcs_translate(V(0, 0, 0)).
        SET sample TO measure_approach().
        LOCAL braking_authority IS VDOT(sample["velocity"] - velocity_before, probe_direction)
            / (TIME:SECONDS - probe_start).
        IF NOT check_line(braking_authority >= 0.15, "RCS braking authority",
            ROUND(braking_authority, 2) + " m/s^2 measured, minimum 0.15 m/s^2") {
            RETURN "RCS did not produce enough translation away from the station.".
        }
        transmit_log().

        LOCAL braking_acceleration IS 0.65 * braking_authority.
        LOCAL maximum_attitude_error IS 0.
        LOCAL drive_since IS TIME:SECONDS.
        LOCAL drive_velocity IS sample["velocity"].
        LOCAL drive_direction IS V(0, 0, 0).
        UNTIL sample["distance"] <= handoff_distance AND sample["speed"] < 0.35 {
            LOCAL rcs_stop IS flight_stop_reason().
            IF rcs_stop <> "" { RETURN rcs_stop. }
            IF NOT flight_ready() { RETURN "Lost settled 1x flight controls during RCS approach.". }
            IF NOT RCS { RETURN "RCS was switched off during approach.". }
            IF TIME:SECONDS >= close_start + 600 { RETURN "The RCS approach exceeded 600 s.". }
            SET rcs_stop TO proximity_stop_reason(sample, braking_acceleration).
            IF rcs_stop <> "" { RETURN rcs_stop. }

            LOCAL attitude_error IS MAX(VANG(SHIP:FACING:FOREVECTOR, hold_attitude:FOREVECTOR),
                VANG(SHIP:FACING:TOPVECTOR, hold_attitude:TOPVECTOR)).
            SET maximum_attitude_error TO MAX(maximum_attitude_error, attitude_error).
            IF attitude_error > 10 { RETURN "RCS approach attitude error exceeded 10 deg.". }

            LOCAL desired_speed IS 0.
            IF sample["distance"] > handoff_distance {
                SET desired_speed TO MIN(cruise_speed,
                    SQRT(2 * braking_acceleration * (sample["distance"] - stop_distance))).
            }
            LOCAL velocity_error IS sample["bearing"] * desired_speed - sample["velocity"].
            LOCAL error_speed IS velocity_error:MAG.
            LOCAL command IS V(0, 0, 0).
            IF error_speed > MAX(0.22, MIN(0.75, 0.04 * desired_speed)) {
                LOCAL strength IS MAX(0.12, MIN(1, error_speed / (0.7 * braking_authority))).
                SET command TO velocity_error:NORMALIZED * strength.
            }
            rcs_translate(command).

            IF command:MAG < 0.25 OR VDOT(drive_direction, command:NORMALIZED) < 0.8 {
                SET drive_since TO TIME:SECONDS.
                SET drive_velocity TO sample["velocity"].
                SET drive_direction TO command:NORMALIZED.
            } ELSE IF TIME:SECONDS - drive_since >= 2 {
                IF VDOT(sample["velocity"] - drive_velocity, drive_direction) < 0.05 {
                    RETURN "No measurable RCS response after 2 s of translation.".
                }
                SET drive_since TO TIME:SECONDS.
                SET drive_velocity TO sample["velocity"].
            }
            LOCAL next_action IS "RCS braking for the docking handoff.".
            IF sample["distance"] > handoff_distance {
                SET next_action TO "RCS approach. Handoff in about " + MAX(0, CEILING(
                    (sample["distance"] - handoff_distance) / MAX(0.1, sample["closing"]))) + " s at current speed.".
            }
            approach_status(sample, next_action).
            WAIT 0.
            SET sample TO measure_approach().
        }
        rcs_translate(V(0, 0, 0)).
        check_line(maximum_attitude_error <= 10, "RCS attitude hold",
            "peak error " + ROUND(maximum_attitude_error, 2) + " deg, limit 10 deg").
        info_line("RCS approach duration", ROUND(TIME:SECONDS - close_start, 1) + " s using RCS").
        RETURN "".
    }

    LOCAL FUNCTION run_approach {
        LOCAL sample IS measure_approach().
        LOCAL encounter_ut IS TIME:SECONDS.
        LOCAL ignition_ut IS encounter_ut.
        LOCAL intercept_closing IS 0.
        LOCAL needs_intercept IS sample["distance"] > 2000 OR sample["speed"] > 8.
        IF sample["distance"] > handoff_distance {
            SET intercept_closing TO closing_command(sample["distance"]).
        }
        IF sample["distance"] > approach_limit {
            LOCAL search_start IS TIME:SECONDS.
            LOCAL search_end IS search_start + MIN(SHIP:OBT:PERIOD, ETA:APOAPSIS + 240).
            LOCAL intercept_prediction IS closest_approach(station, search_start, search_end).
            SET encounter_ut TO intercept_prediction["ut"].
            LOCAL encounter_velocity IS VELOCITYAT(SHIP, encounter_ut):ORBIT - VELOCITYAT(station, encounter_ut):ORBIT.
            LOCAL encounter_speed IS encounter_velocity:MAG.
            // The predictor samples once per second near the minimum.
            LOCAL minimum_pass IS intercept_prediction["distance"] - encounter_speed / 2.
            LOCAL encounter_eta IS encounter_ut - TIME:SECONDS.
            IF NOT check_line(minimum_pass >= safety_distance AND intercept_prediction["distance"] <= approach_limit
                AND encounter_eta > 0, "Intercept prediction", ROUND(intercept_prediction["distance"], 1)
                + " m in " + ROUND(encounter_eta, 1) + " s at " + ROUND(encounter_speed, 2)
                + " m/s (range " + safety_distance + " to " + approach_limit + " m; lower bound "
                + ROUND(minimum_pass, 1) + " m)") {
                RETURN "No safe intercept found in the upcoming apoapsis passage.".
            }
            IF intercept_prediction["distance"] <= handoff_distance {
                SET intercept_closing TO 0.
            } ELSE {
                SET intercept_closing TO closing_command(intercept_prediction["distance"]).
            }
            LOCAL encounter_bearing IS (POSITIONAT(station, encounter_ut) - POSITIONAT(SHIP, encounter_ut)):NORMALIZED.
            LOCAL intercept_delta_v IS (encounter_bearing * intercept_closing - encounter_velocity):MAG.
            SET ignition_ut TO encounter_ut - burn_duration(intercept_delta_v) - 2.
            LOCAL warp_stop IS ignition_ut - 55.
            IF TIME:SECONDS < warp_stop {
                begin_phase("Coast to intercept", "Intercept burn is scheduled for UT "
                    + ROUND(ignition_ut, 2) + " s, closest approach UT " + ROUND(encounter_ut, 2) + " s.").
                KUNIVERSE:TIMEWARP:WARPTO(warp_stop).
                UNTIL TIME:SECONDS >= warp_stop AND flight_ready() {
                    LOCAL warp_stop_reason IS flight_stop_reason().
                    IF warp_stop_reason <> "" { RETURN warp_stop_reason. }
                    IF TIME:SECONDS > ignition_ut { RETURN "Warp did not settle before the ignition time.". }
                    approach_status(measure_approach(), "Intercept burn in "
                        + MAX(0, CEILING(ignition_ut - TIME:SECONDS)) + " s. Auto-warping.").
                    WAIT 0.
                }
            }
        } ELSE {
            info_line("Starting inside approach range", describe_approach(sample)).
        }

        SAS OFF.
        LOCK THROTTLE TO throttle_cmd.
        LOCK STEERING TO burn_direction.
        SET controls_locked TO TRUE.
        IF needs_intercept {
            LOCAL intercept_stop IS run_main_burn("Intercept burn", intercept_closing, ignition_ut).
            IF intercept_stop <> "" { RETURN intercept_stop. }
            SET sample TO measure_approach().
            IF NOT check_line(sample["distance"] > safety_distance AND sample["distance"] <= approach_limit
                AND sample["sideways"] < 0.5 AND sample["closing"] <= closing_limit,
                "Intercept velocity", describe_approach(sample) + ", desired closing "
                + ROUND(intercept_closing, 2) + " m/s, required sideways speed < 0.5 m/s and range "
                + safety_distance + " to " + approach_limit + " m") {
                RETURN "The intercept ended outside approach limits.".
            }
        } ELSE {
            SET intercept_closing TO 8.
        }

        LOCAL rcs_cruise IS MAX(2, intercept_closing).
        IF needs_intercept AND sample["closing"] > 8 {
            LOCAL main_brake_stop IS coast_to_main_brake(3).
            IF main_brake_stop <> "" { RETURN main_brake_stop. }
            SET sample TO measure_approach().
            SET rcs_cruise TO 3.
        }
        IF sample["distance"] <= safety_distance { RETURN "Too close to start RCS translation.". }
        IF sample["distance"] > handoff_distance OR sample["speed"] >= 0.35 {
            LOCAL close_stop IS close_with_rcs(rcs_cruise).
            IF close_stop <> "" { RETURN close_stop. }
        }
        SET sample TO measure_approach().
        IF NOT check_line(sample["distance"] > safety_distance AND sample["distance"] <= handoff_distance
            AND sample["speed"] < 0.5, "Docking handoff", describe_approach(sample)
            + ", required range " + safety_distance + " to " + handoff_distance + " m and speed < 0.5 m/s") {
            RETURN "The approach ended outside the handoff limits.".
        }
        check_line(engine_starts <= 2, "Main-engine starts", engine_starts + " commanded, limit 2").
        RETURN "".
    }

    LOCAL enabled_rcs IS 0.
    FOR thruster IN SHIP:RCS {
        IF thruster:ENABLED AND thruster:AVAILABLETHRUST > 0 { SET enabled_rcs TO enabled_rcs + 1. }
    }
    IF NOT check_line(flight_ready() AND SHIP:STATUS = "ORBITING" AND station:STATUS = "ORBITING"
        AND SHIP:BODY = station:BODY AND CAREER():CANMAKENODES AND NOT HASNODE
        AND enabled_rcs > 0, "Approach preflight",
        "settled 1x flight controls=" + flight_ready() + ", chaser " + SHIP:STATUS
        + ", target " + station:STATUS + ", same body=" + (SHIP:BODY = station:BODY)
        + ", orbital prediction available=" + CAREER():CANMAKENODES + ", existing node=" + HASNODE
        + ", enabled RCS thrusters " + enabled_rcs + " (required > 0)") { RETURN. }
    SET TARGET TO station.
    TERMINAL:INPUT:CLEAR().
    PRINT "Stay on " + SHIP:NAME + ". Press any key to abort.".
    LOCAL reason IS run_approach().
    IF reason <> "" {
        abort_approach(reason).
        RETURN.
    }
    clear_controls().
    PRINT "Stay on " + SHIP:NAME + " for docking with " + station:NAME + ".".
    transmit_log().
}
