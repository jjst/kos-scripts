@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/rcs.ks"

LOCAL FUNCTION clearance_to_segment {
    PARAMETER from_center, destination.
    LOCAL step_vector IS destination - from_center.
    LOCAL fraction IS MAX(0, MIN(1, -VDOT(from_center, step_vector) / MAX(0.001, VDOT(step_vector, step_vector)))).
    RETURN (from_center + step_vector * fraction):MAG.
}

LOCAL FUNCTION limited_velocity {
    PARAMETER offset, gain_factor, speed_limit.
    RETURN offset:NORMALIZED * MIN(speed_limit, gain_factor * offset:MAG).
}

FUNCTION dock_to_station {
    PARAMETER station_name, options.
    LOCAL station_matches IS LIST().
    LOCAL flying_vessels IS LIST().
    LIST TARGETS IN flying_vessels.
    FOR other_vessel IN flying_vessels {
        IF other_vessel:NAME = station_name { station_matches:ADD(other_vessel). }
    }
    IF NOT check_line(station_matches:LENGTH = 1, "Docking station",
        station_name + ", " + station_matches:LENGTH + " matching vessels, required 1") { RETURN. }
    LOCAL station IS station_matches[0].
    LOCAL chaser_tag IS "".
    LOCAL station_tag IS "".
    IF options:HASKEY("chaser_port_tag") { SET chaser_tag TO options["chaser_port_tag"]. }
    IF options:HASKEY("station_port_tag") { SET station_tag TO options["station_port_tag"]. }
    LOCAL open_shield IS FALSE.
    IF options:HASKEY("open_chaser_shield") { SET open_shield TO options["open_chaser_shield"]. }

    LOCAL rcs_force IS 0.
    FOR thruster IN SHIP:RCS {
        IF thruster:ENABLED { SET rcs_force TO rcs_force + thruster:AVAILABLETHRUST. }
    }
    LOCAL initial_speed IS (SHIP:VELOCITY:ORBIT - station:VELOCITY:ORBIT):MAG.
    IF NOT check_line(SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:UNPACKED AND station:UNPACKED
        AND SHIP:BODY = station:BODY AND KUNIVERSE:TIMEWARP:ISSETTLED
        AND KUNIVERSE:TIMEWARP:RATE <= 1.01 AND station:DISTANCE <= 210
        AND initial_speed <= 1 AND rcs_force > 0, "Docking preflight",
        station:NAME + " at " + ROUND(station:DISTANCE, 1) + " m (limit 210 m), relative speed "
        + ROUND(initial_speed, 2) + " m/s (limit 1), station unpacked=" + station:UNPACKED
        + ", rated RCS " + ROUND(rcs_force, 2) + " kN (required > 0 kN)") { RETURN. }

    LOCAL chaser_ports IS LIST().
    FOR own_candidate IN SHIP:DOCKINGPORTS {
        IF chaser_tag = "" OR own_candidate:TAG = chaser_tag {
            IF own_candidate:STATE = "Ready" OR (open_shield AND own_candidate:STATE = "Disabled"
                AND own_candidate:HASMODULE("ModuleAnimateGeneric")) { chaser_ports:ADD(own_candidate). }
        }
    }
    IF NOT check_line(chaser_ports:LENGTH = 1, "Chaser port selection",
        chaser_ports:LENGTH + " usable ports for tag '" + chaser_tag + "' (required 1). "
        + "Open the port shield or specify a unique port tag if needed.") { RETURN. }
    LOCAL chaser_port IS chaser_ports[0].
    LOCAL station_port IS 0.
    LOCAL best_route IS 1000000.
    LOCAL compatible_ports IS 0.
    FOR offer_port IN station:DOCKINGPORTS {
        IF offer_port:NODETYPE = chaser_port:NODETYPE AND offer_port:TARGETABLE
            AND offer_port:STATE = "Ready" AND (station_tag = "" OR offer_port:TAG = station_tag) {
            SET compatible_ports TO compatible_ports + 1.
            LOCAL gate_point IS offer_port:NODEPOSITION + offer_port:PORTFACING:FOREVECTOR * 50.
            LOCAL gate_range IS (gate_point - chaser_port:NODEPOSITION):MAG.
            IF gate_range < best_route {
                SET best_route TO gate_range.
                SET station_port TO offer_port.
            }
        }
    }
    IF NOT check_line(compatible_ports > 0 AND (station_tag = "" OR compatible_ports = 1),
        "Station port selection", compatible_ports + " Ready compatible " + chaser_port:NODETYPE
        + " ports for tag '" + station_tag + "' (required 1 tagged or at least 1 untagged)") { RETURN. }
    info_line("Docking ports", chaser_port:TITLE + " #" + chaser_port:UID + " to " + station_port:TITLE
        + " #" + station_port:UID + ", " + chaser_port:NODETYPE + ", selection by tag or nearest compatible gate").
    transmit_log().

    TERMINAL:INPUT:CLEAR().
    IF chaser_port:STATE = "Disabled" {
        LOCAL shield_module IS chaser_port:GETMODULE("ModuleAnimateGeneric").
        IF NOT check_line(shield_module:HASEVENT("Open Shield"), "Open docking shield",
            "Open Shield event on " + chaser_port:TITLE) { RETURN. }
        shield_module:DOEVENT("Open Shield").
        LOCAL ready_by IS TIME:SECONDS + 15.
        CLEARSCREEN.
        PRINT "Stay on " + SHIP:NAME + ". Opening the docking shield. Press any key to abort.".
        UNTIL chaser_port:STATE = "Ready" OR TIME:SECONDS >= ready_by OR TERMINAL:INPUT:HASCHAR { WAIT 0. }
        IF NOT check_line(chaser_port:STATE = "Ready" AND NOT TERMINAL:INPUT:HASCHAR, "Chaser port ready",
            chaser_port:STATE + " (required Ready), abort requested=" + TERMINAL:INPUT:HASCHAR) { RETURN. }
    }

    LOCAL station_box IS station:BOUNDS.
    LOCAL chaser_box IS SHIP:BOUNDS.
    LOCAL clearance IS (station_box:ABSCENTER - station:POSITION):MAG + station_box:EXTENTS:MAG
        + (chaser_box:ABSCENTER - chaser_port:NODEPOSITION):MAG + chaser_box:EXTENTS:MAG + 3.
    LOCAL gate_distance IS MAX(50, clearance + 15).
    LOCAL original_control IS SHIP:CONTROLPART.
    LOCAL had_sas IS SAS.
    LOCAL had_rcs IS RCS.
    LOCAL phase_name IS "Line up with port".
    LOCAL phase_deadline IS TIME:SECONDS + 110.
    LOCAL next_display IS 0.
    LOCAL next_sample IS 0.
    LOCAL latest_state IS "".
    LOCAL stable_since IS 0.
    LOCAL failure_text IS "".
    LOCAL contact_speed IS -1.
    LOCAL last_speed IS 0.
    LOCAL capture_since IS 0.
    LOCAL retreat_required IS FALSE.
    LOCAL backed_off IS FALSE.
    LOCAL stopped_relative IS FALSE.
    LOCAL docked_ok IS FALSE.
    LOCAL steer_goal IS SHIP:FACING.
    LOCAL rcs_scale IS MAX(0.12, 0.35 * rcs_force / SHIP:MASS).
    LOCAL prior_offset IS chaser_port:NODEPOSITION - station_port:NODEPOSITION.
    LOCAL prior_ut IS TIME:SECONDS.
    LOCAL port_motion IS SHIP:VELOCITY:ORBIT - station:VELOCITY:ORBIT.

    LOCAL FUNCTION change_docking_phase {
        PARAMETER next_phase, seconds_allowed, detail.
        SET phase_name TO next_phase.
        SET phase_deadline TO TIME:SECONDS + seconds_allowed.
        SET next_display TO 0.
        SET next_sample TO 0.
        SET stable_since TO 0.
        info_line(next_phase, detail).
        transmit_log().
    }

    LOCAL FUNCTION drive_docking_velocity {
        PARAMETER wanted_motion.
        LOCAL motion_error IS wanted_motion - port_motion.
        LOCAL translation IS V(0, 0, 0).
        IF motion_error:MAG > 0.028 {
            SET translation TO motion_error:NORMALIZED * MAX(0.13, MIN(1, motion_error:MAG / (0.65 * rcs_scale))).
        }
        rcs_translate(translation).
    }

    SAS OFF.
    chaser_port:CONTROLFROM().
    SET TARGET TO station_port.
    LOCAL main_throttle IS 0.
    LOCK THROTTLE TO main_throttle.
    RCS ON.
    WAIT 0.
    LOCK STEERING TO steer_goal.
    info_line("Docking corridor", "keep-out " + ROUND(clearance, 1) + " m from station center before lineup, "
        + ROUND(gate_distance, 1) + " m gate from port").
    transmit_log().

    UNTIL docked_ok {
        LOCAL own_state IS chaser_port:STATE.
        IF own_state:STARTSWITH("Docked") AND chaser_port:HASPARTNER {
            SET docked_ok TO chaser_port:PARTNER:UID = station_port:UID.
            IF NOT docked_ok { SET failure_text TO "The port attached to a different partner.". }
            BREAK.
        }
        IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED OR NOT station:UNPACKED
            OR NOT KUNIVERSE:TIMEWARP:ISSETTLED OR KUNIVERSE:TIMEWARP:RATE > 1.01 OR NOT RCS {
            SET failure_text TO "Lost active, settled 1x docking controls or station physics.".
            BREAK.
        }
        LOCAL other_state IS station_port:STATE.
        LOCAL capture_active IS own_state = "PreAttached" OR other_state = "PreAttached"
            OR own_state:STARTSWITH("Acquire") OR other_state:STARTSWITH("Acquire").
        IF own_state + " / " + other_state <> latest_state {
            SET latest_state TO own_state + " / " + other_state.
            info_line("Docking port states", latest_state).
            transmit_log().
        }

        LOCAL port_facing IS station_port:PORTFACING.
        LOCAL outward_axis IS port_facing:FOREVECTOR.
        LOCAL ship_port_basis IS chaser_port:PORTFACING:INVERSE * SHIP:FACING.
        SET steer_goal TO LOOKDIRUP(-outward_axis, port_facing:TOPVECTOR) * ship_port_basis.
        LOCAL offset IS chaser_port:NODEPOSITION - station_port:NODEPOSITION.
        LOCAL axial IS VDOT(offset, outward_axis).
        LOCAL lateral IS offset - outward_axis * axial.
        LOCAL now_ut IS TIME:SECONDS.
        IF now_ut - prior_ut >= 0.04 {
            LOCAL measured_velocity IS (offset - prior_offset) / (now_ut - prior_ut).
            LOCAL sample_weight IS MIN(1, (now_ut - prior_ut) / 0.20).
            SET port_motion TO port_motion * (1 - sample_weight) + measured_velocity * sample_weight.
            SET prior_offset TO offset.
            SET prior_ut TO now_ut.
        }
        LOCAL speed_in IS -VDOT(port_motion, outward_axis).
        LOCAL pointing_angle IS VANG(chaser_port:PORTFACING:FOREVECTOR, -outward_axis).
        LOCAL turn_rate IS SHIP:ANGULARVEL:MAG * 180 / CONSTANT:PI.
        LOCAL aligned IS pointing_angle <= 4 AND turn_rate <= 3.
        LOCAL detail IS ROUND(offset:MAG, 2) + " m port range, axial " + ROUND(axial, 2)
            + " m, drift " + ROUND(lateral:MAG, 2) + " m, closing " + ROUND(speed_in, 3)
            + " m/s, pointing " + ROUND(pointing_angle, 2) + " deg, turn " + ROUND(turn_rate, 2) + " deg/s".

        IF TERMINAL:INPUT:HASCHAR {
            LOCAL abort_key IS TERMINAL:INPUT:GETCHAR().
            IF failure_text = "" { SET failure_text TO "Operator abort key " + UNCHAR(abort_key) + ".". }
        }
        IF now_ut >= phase_deadline AND failure_text = "" {
            SET failure_text TO phase_name + " timed out.".
        }
        IF (own_state = "Disabled" OR other_state = "Disabled") AND failure_text = "" {
            SET failure_text TO "A docking port became disabled.".
        }

        LOCAL wanted_motion IS V(0, 0, 0).
        IF capture_active {
            IF capture_since = 0 {
                SET capture_since TO now_ut.
                SET contact_speed TO MAX(0, last_speed).
                info_line("Magnetic capture", "last controlled closure " + ROUND(contact_speed, 3) + " m/s. " + detail).
                transmit_log().
            }
            rcs_translate(V(0, 0, 0)).
            IF now_ut >= capture_since + 25 {
                SET failure_text TO "Magnetic capture did not produce a docked pair within 25 s.".
                BREAK.
            }
        } ELSE {
            SET capture_since TO 0.
            IF failure_text <> "" AND phase_name <> "Back away" {
                SET retreat_required TO phase_name = "Approach on port axis" AND axial < 12
                    AND axial >= -0.15 AND lateral:MAG < 0.6.
                change_docking_phase("Back away", 45, failure_text + " " + detail).
            }
            IF phase_name = "Back away" {
                IF now_ut >= phase_deadline { BREAK. }
                IF (NOT retreat_required OR axial >= 12) AND port_motion:MAG < 0.13 {
                    SET backed_off TO retreat_required.
                    SET stopped_relative TO TRUE.
                    BREAK.
                }
                IF retreat_required AND axial < 12 { SET wanted_motion TO outward_axis * 0.55. }
            } ELSE IF phase_name = "Line up with port" {
                IF aligned {
                    IF stable_since = 0 { SET stable_since TO now_ut. }
                    IF now_ut >= stable_since + 0.5 {
                        change_docking_phase("Fly to port axis", 360, detail).
                    }
                } ELSE { SET stable_since TO 0. }
            } ELSE IF phase_name = "Fly to port axis" {
                LOCAL gate_error IS outward_axis * gate_distance - offset.
                LOCAL center_offset IS chaser_port:NODEPOSITION - station:POSITION.
                LOCAL gate_from_center IS center_offset + gate_error.
                IF gate_error:MAG <= 0.8 AND port_motion:MAG <= 0.3 AND aligned {
                    change_docking_phase("Approach on port axis", 300, detail).
                } ELSE IF aligned {
                    IF clearance_to_segment(center_offset, gate_from_center) < clearance {
                        LOCAL radial IS center_offset:NORMALIZED.
                        LOCAL onward IS VXCL(radial, gate_from_center).
                        IF onward:MAG < 0.1 { SET onward TO VXCL(radial, port_facing:TOPVECTOR). }
                        IF onward:MAG < 0.1 { SET onward TO VXCL(radial, port_facing:STARVECTOR). }
                        LOCAL around_point IS (radial * COS(25) + onward:NORMALIZED * SIN(25))
                            * MAX(gate_from_center:MAG, clearance + 12).
                        SET gate_error TO around_point - center_offset.
                    }
                    SET wanted_motion TO limited_velocity(gate_error, 0.28, 1.8).
                }
            } ELSE IF phase_name = "Approach on port axis" {
                IF axial < -0.15 OR (axial < 1 AND lateral:MAG > 0.35) {
                    SET failure_text TO "The ports left the capture corridor.".
                } ELSE IF aligned {
                    SET wanted_motion TO limited_velocity(-lateral, 0.60, 0.4).
                    IF lateral:MAG <= MAX(0.075, MIN(1, 0.045 * axial)) {
                        LOCAL axial_speed IS MIN(1.5, MAX(0.12, 0.075 * axial)).
                        SET wanted_motion TO wanted_motion - outward_axis * axial_speed.
                    }
                }
            }
            drive_docking_velocity(wanted_motion).
            SET last_speed TO speed_in.
        }

        IF KUNIVERSE:REALTIME >= next_display {
            SET next_display TO KUNIVERSE:REALTIME + 2.
            CLEARSCREEN.
            PRINT "Stay on " + SHIP:NAME + ". Press any key to abort.".
            PRINT phase_name + ".".
            PRINT detail.
        }
        IF KUNIVERSE:REALTIME >= next_sample {
            SET next_sample TO KUNIVERSE:REALTIME + 5.
            log_line(phase_name + ". " + detail, FALSE).
        }
        checkpoint_log("").
        WAIT 0.
    }

    rcs_translate(V(0, 0, 0)).
    SET SHIP:CONTROL:NEUTRALIZE TO TRUE.
    WAIT 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SET RCS TO had_rcs.
    SET SAS TO had_sas.
    IF NOT docked_ok AND SHIP = KUNIVERSE:ACTIVEVESSEL { original_control:CONTROLFROM(). }
    CLEARSCREEN.
    IF docked_ok {
        check_line(TRUE, "Docking confirmed", SHIP:NAME + ", selected port #" + station_port:UID
            + ", chaser port state " + chaser_port:STATE + ", partner verified").
        IF contact_speed >= 0 {
            check_line(contact_speed <= 0.20, "Capture approach speed", ROUND(contact_speed, 3)
                + " m/s at start of magnetic capture (limit 0.20 m/s)").
        }
        PRINT "Docked to " + station_name + ". Flight controls released.".
    } ELSE {
        check_line(FALSE, "Docking stopped", failure_text + " Backed off=" + backed_off
            + ", relative motion stopped=" + stopped_relative + ".").
        PRINT "Check port state and clearance before retrying.".
    }
    transmit_log().
}
