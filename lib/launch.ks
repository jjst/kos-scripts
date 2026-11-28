@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"

// Describe an upcoming separator stage without igniting or staging anything.
FUNCTION launch_booster_group {
    PARAMETER stage_number.
    LOCAL boosters IS LIST().
    LOCAL separators IS LIST().
    LOCAL retained_count IS 0.
    FOR eng IN SHIP:ENGINES {
        IF eng:DECOUPLEDIN = stage_number {
            LOCAL separator IS eng:DECOUPLER.
            IF NOT separator:ISTYPE("Separator") {
                RETURN LEXICON("engines", LIST(), "reason", "engine " + eng:NAME + " lacks a permanent separator").
            }
            IF separator:STAGE <> stage_number OR NOT separator:STAGED OR separator:ISDECOUPLED {
                RETURN LEXICON("engines", LIST(), "reason", "separator " + separator:NAME + " is not armed for this stage").
            }
            boosters:ADD(eng).
            IF NOT separators:CONTAINS(separator:UID) { separators:ADD(separator:UID). }
        } ELSE {
            SET retained_count TO retained_count + 1.
        }
    }
    IF boosters:LENGTH = 0 { RETURN LEXICON("engines", boosters, "reason", ""). }
    IF retained_count = 0 {
        RETURN LEXICON("engines", LIST(), "reason", "the stage would drop every engine").
    }
    FOR ship_part IN SHIP:PARTS {
        IF ship_part:STAGE = stage_number AND NOT separators:CONTAINS(ship_part:UID) {
            // Recovery hardware on a detached branch may fire with its separator.
            IF ship_part:DECOUPLEDIN <> stage_number OR ship_part:ISTYPE("Decoupler") {
                RETURN LEXICON("engines", LIST(), "reason", "stage also triggers unrelated part " + ship_part:NAME).
            }
        }
    }
    RETURN LEXICON("engines", boosters, "reason", "").
}

FUNCTION launch_to_orbit {
    PARAMETER options.

    LOCAL azimuth IS 90.
    LOCAL target_ap IS 100000.
    LOCAL fairing_policy IS "atmosphere".
    LOCAL atmosphere_top IS SHIP:BODY:ATM:HEIGHT.
    LOCAL minimum_pe IS MAX(0, atmosphere_top + 5000).
    LOCAL last_stage IS 0.
    LOCAL ignition_delay IS 0.
    LOCAL half_dv_timing IS FALSE.
    LOCAL ascent_twr_limit IS 2.2.
    LOCAL scheduled_launch_ut IS -1.
    IF options:HASKEY("heading") { SET azimuth TO options["heading"]. }
    IF options:HASKEY("target_altitude") { SET target_ap TO options["target_altitude"]. }
    IF options:HASKEY("fairing_policy") { SET fairing_policy TO options["fairing_policy"]. }
    IF options:HASKEY("minimum_pe") { SET minimum_pe TO options["minimum_pe"]. }
    IF options:HASKEY("last_stage") { SET last_stage TO options["last_stage"]. }
    IF options:HASKEY("ignition_delay") { SET ignition_delay TO options["ignition_delay"]. }
    IF options:HASKEY("half_dv_timing") { SET half_dv_timing TO options["half_dv_timing"]. }
    IF options:HASKEY("ascent_twr_limit") { SET ascent_twr_limit TO options["ascent_twr_limit"]. }
    IF options:HASKEY("launch_ut") { SET scheduled_launch_ut TO options["launch_ut"]. }

    LOCAL throttle_cmd IS 0.
    LOCAL liftoff_ut IS -1.
    LOCAL liftoff_longitude IS 0.
    LOCAL circularisation_end_ut IS -1.
    LOCAL ascent_angle IS 0.
    LOCAL circularisation_taper_band IS 10000.
    LOCAL pitch IS 90.
    LOCAL next_sample IS 0.
    LOCAL fairings IS LIST().
    IF fairing_policy <> "none" {
        FOR module_item IN SHIP:MODULESNAMED("ModuleProceduralFairing") {
            fairings:ADD(module_item).
        }
    }

    FUNCTION flight_ready {
        RETURN SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:UNPACKED
            AND KUNIVERSE:TIMEWARP:ISSETTLED AND KUNIVERSE:TIMEWARP:RATE <= 1.01.
    }

    FUNCTION finish_launch {
        PARAMETER reason, burn_completed IS FALSE.
        LOCAL ap IS SHIP:APOAPSIS.
        LOCAL pe IS SHIP:PERIAPSIS.
        LOCAL remaining_dv IS SHIP:DELTAV:CURRENT.
        LOCAL ap_error IS ABS(ap - target_ap).
        log_line("Launch cutoff: " + reason + ", status " + SHIP:STATUS
            + ", altitude " + ROUND(SHIP:ALTITUDE, 1) + " m, throttle " + ROUND(throttle_cmd, 2)
            + ", thrust " + ROUND(SHIP:THRUST, 1) + " kN, stage " + STAGE:NUMBER + ".").
        IF burn_completed {
            LOCAL ap_detail IS ROUND(ap, 1) + " m, target " + target_ap + " m, tolerance 3000 m".
            IF ap_error > 3000 {
                warn_line("Apoapsis", ap_detail).
            } ELSE {
                info_line("Apoapsis", ap_detail).
            }
            LOCAL spread IS ap - pe.
            LOCAL spread_detail IS ROUND(spread, 1) + " m, desired 3000 m or less".
            IF spread > 3000 {
                warn_line("Ap-Pe spread", spread_detail).
            } ELSE {
                info_line("Ap-Pe spread", spread_detail).
            }
        }
        LOCAL pe_ok IS check_line(pe >= minimum_pe, "Periapsis",
            ROUND(pe, 1) + " m, minimum " + minimum_pe + " m").
        LOCAL dv_ok IS check_line(remaining_dv > 0, "Remaining delta-v",
            ROUND(remaining_dv, 1) + " m/s, required > 0 m/s").
        LOCAL orbit_ok IS check_line(SHIP:STATUS = "ORBITING", "Vessel status",
            SHIP:STATUS + ", required ORBITING").
        LOCAL success IS burn_completed AND pe_ok AND dv_ok AND orbit_ok.
        LOCAL result_reason IS reason.
        IF burn_completed AND NOT success {
            SET result_reason TO reason + ", post-burn orbit or delta-v checks failed".
        }
        log_line("Launch result: success=" + success + ", " + result_reason + ".").
        transmit_log().
        RETURN LEXICON("success", success, "reason", result_reason, "ap", ap, "pe", pe,
            "remaining_dv", remaining_dv, "liftoff_ut", liftoff_ut,
            "circularisation_end_ut", circularisation_end_ut, "ascent_angle", ascent_angle).
    }

    FUNCTION stop_launch {
        PARAMETER reason.
        log_line("Stopping launch: " + reason + ". Ap " + ROUND(SHIP:APOAPSIS, 1)
            + " m, Pe " + ROUND(SHIP:PERIAPSIS, 1) + " m, thrust " + ROUND(SHIP:THRUST, 1) + " kN.").
        SET throttle_cmd TO 0.
        IF SHIP = KUNIVERSE:ACTIVEVESSEL AND KUNIVERSE:TIMEWARP:RATE > 1.01 {
            SET WARP TO 0.
        }
        WAIT 0.
        UNLOCK THROTTLE.
        UNLOCK STEERING.
        RETURN finish_launch(reason).
    }

    FUNCTION deploy_fairings {
        FOR fairing IN fairings {
            LOCAL deploy_event IS "deploy".
            IF NOT fairing:HASEVENT(deploy_event) { SET deploy_event TO "deploy fairing". }
            IF NOT fairing:HASEVENT(deploy_event) {
                log_line("Fairing deploy event unavailable on " + fairing:PART:NAME
                    + ". Events: " + fairing:ALLEVENTNAMES + ".").
                RETURN FALSE.
            }
            LOCAL mass_before IS SHIP:MASS.
            log_line("Jettisoning " + fairing:PART:NAME + " at " + ROUND(SHIP:ALTITUDE, 1)
                + " m, q " + ROUND(SHIP:Q * CONSTANT:ATMTOKPA, 4)
                + " kPa, mass " + ROUND(mass_before, 4) + " t.").
            fairing:DOEVENT(deploy_event).
            LOCAL verify_by IS TIME:SECONDS + 2.
            WAIT UNTIL (NOT fairing:HASEVENT(deploy_event) AND SHIP:MASS < mass_before)
                OR TIME:SECONDS >= verify_by OR NOT flight_ready().
            LOCAL event_gone IS NOT fairing:HASEVENT(deploy_event).
            LOCAL mass_after IS SHIP:MASS.
            IF NOT check_line(event_gone AND mass_after < mass_before, "Fairing jettison",
                "deploy event gone=" + event_gone + ", mass " + ROUND(mass_before, 4)
                + " t -> " + ROUND(mass_after, 4) + " t, required decrease > 0 t") {
                RETURN FALSE.
            }
        }
        fairings:CLEAR().
        transmit_log().
        RETURN TRUE.
    }

    FUNCTION fire_next_stage {
        PARAMETER reason.
        IF NOT flight_ready() OR NOT STAGE:READY OR STAGE:NUMBER <= last_stage {
            log_line("Stage blocked: current stage " + STAGE:NUMBER + ", last allowed " + last_stage
                + ", stage ready=" + STAGE:READY + ", flight ready=" + flight_ready() + ".").
            RETURN FALSE.
        }
        LOCAL next_stage IS STAGE:NUMBER - 1.
        LOCAL staged_parts IS LIST().
        FOR ship_part IN SHIP:PARTS {
            IF ship_part:STAGE = next_stage {
                staged_parts:ADD(ship_part:NAME + "/" + ship_part:UID).
            }
        }
        log_line("Firing stage " + next_stage + " for " + reason + ". Assigned parts: " + staged_parts + ".").
        STAGE.
        LOCAL ready_by IS TIME:SECONDS + 3.
        WAIT UNTIL STAGE:READY OR TIME:SECONDS >= ready_by OR NOT flight_ready().
        log_line("Stage after command: " + STAGE:NUMBER + ", available thrust "
            + ROUND(SHIP:AVAILABLETHRUST, 1) + " kN.").
        transmit_log().
        RETURN STAGE:NUMBER < next_stage + 1 AND flight_ready().
    }

    FUNCTION has_live_engine {
        FOR eng IN SHIP:ENGINES {
            IF eng:IGNITION AND NOT eng:FLAMEOUT AND eng:AVAILABLETHRUST > 0 { RETURN TRUE. }
        }
        RETURN FALSE.
    }

    FUNCTION boosters_spent {
        PARAMETER booster_engines.
        IF booster_engines:LENGTH = 0 { RETURN FALSE. }
        FOR eng IN booster_engines {
            IF NOT eng:IGNITION OR NOT eng:FLAMEOUT OR eng:THRUST > 0 { RETURN FALSE. }
        }
        RETURN TRUE.
    }

    FUNCTION ascent_sample {
        IF TIME:SECONDS < next_sample { RETURN. }
        SET next_sample TO TIME:SECONDS + 5.
        LOCAL radial_unit IS (SHIP:POSITION - SHIP:BODY:POSITION):NORMALIZED.
        LOCAL nose_vector IS SHIP:FACING:FOREVECTOR.
        LOCAL surface_velocity IS SHIP:VELOCITY:SURFACE.
        LOCAL surface_speed_now IS surface_velocity:MAG.
        LOCAL actual_pitch IS ARCSIN(MAX(-1, MIN(1, VDOT(nose_vector, radial_unit)))).
        LOCAL flight_path_detail IS "flight-path angle and AoA unavailable at zero surface speed".
        IF surface_speed_now > 0 {
            LOCAL vertical_fraction IS VDOT(surface_velocity, radial_unit) / surface_speed_now.
            LOCAL flight_path_angle IS ARCSIN(MAX(-1, MIN(1, vertical_fraction))).
            SET flight_path_detail TO "flight-path angle " + ROUND(flight_path_angle, 1)
                + " deg, AoA " + ROUND(VANG(nose_vector, surface_velocity), 1) + " deg".
        }
        log_line("Ascent: altitude " + ROUND(SHIP:ALTITUDE, 1)
            + " m, Ap " + ROUND(SHIP:APOAPSIS, 1) + " m, Pe " + ROUND(SHIP:PERIAPSIS, 1)
            + " m, surface speed " + ROUND(surface_speed_now, 1)
            + " m/s, pitch target " + ROUND(pitch, 1) + " deg, actual pitch " + ROUND(actual_pitch, 1)
            + " deg, yaw error " + ROUND(STEERINGMANAGER:YAWERROR, 1) + " deg, roll error "
            + ROUND(STEERINGMANAGER:ROLLERROR, 1) + " deg, " + flight_path_detail
            + ", q " + ROUND(SHIP:Q * CONSTANT:ATMTOKPA, 2)
            + " kPa, throttle " + ROUND(throttle_cmd, 2)
            + ", stage delta-v " + ROUND(STAGE:DELTAV:CURRENT, 1) + " m/s.", FALSE).
    }

    FUNCTION circularisation_throttle {
        LOCAL orbit_error IS MAX(ABS(SHIP:APOAPSIS - target_ap), ABS(SHIP:PERIAPSIS - target_ap)).
        RETURN MIN(1, orbit_error / circularisation_taper_band).
    }

    FUNCTION circularisation_sample {
        PARAMETER event_name.
        LOCAL orbit_velocity IS SHIP:VELOCITY:ORBIT.
        LOCAL radial_unit IS (SHIP:POSITION - SHIP:BODY:POSITION):NORMALIZED.
        LOCAL radial_speed IS VDOT(orbit_velocity, radial_unit).
        LOCAL tangential_speed IS (orbit_velocity - radial_speed * radial_unit):MAG.
        log_line("Circularisation " + event_name + ": Ap " + ROUND(SHIP:APOAPSIS, 1)
            + " m, Pe " + ROUND(SHIP:PERIAPSIS, 1) + " m, altitude " + ROUND(SHIP:ALTITUDE, 1)
            + " m, eccentricity " + ROUND(SHIP:OBT:ECCENTRICITY, 8)
            + ", ETA Ap " + ROUND(ETA:APOAPSIS, 2) + " s, radial " + ROUND(radial_speed, 2)
            + " m/s, tangential " + ROUND(tangential_speed, 2) + " m/s, throttle "
            + ROUND(throttle_cmd, 4) + ", thrust " + ROUND(SHIP:THRUST, 2)
            + " kN, mass " + ROUND(SHIP:MASS, 4) + " t, prograde error "
            + ROUND(VANG(SHIP:FACING:FOREVECTOR, orbit_velocity), 2) + " deg.", FALSE).
    }

    log_line("Launch target: heading " + azimuth + " deg, Ap " + target_ap + " m, minimum Pe "
        + minimum_pe + " m, atmosphere top " + atmosphere_top + " m, fairing policy " + fairing_policy + ".").
    LOCAL ready IS check_line(flight_ready(), "Flight controls", "active="
        + (SHIP = KUNIVERSE:ACTIVEVESSEL) + ", unpacked=" + SHIP:UNPACKED
        + ", settled=" + KUNIVERSE:TIMEWARP:ISSETTLED + ", warp " + KUNIVERSE:TIMEWARP:RATE + "x (limit 1.01x)").
    LOCAL valid_site IS check_line(SHIP:STATUS = "PRELAUNCH" OR SHIP:STATUS = "LANDED",
        "Launch site", SHIP:STATUS + ", required PRELAUNCH or LANDED").
    LOCAL valid_target IS check_line(target_ap >= minimum_pe AND target_ap > atmosphere_top + 100
        AND minimum_pe > atmosphere_top AND azimuth >= 0 AND azimuth < 360,
        "Launch targets", "Ap " + target_ap + " m, minimum Pe " + minimum_pe
        + " m, atmosphere top " + atmosphere_top + " m, heading " + azimuth + " deg (0 to <360 deg)").
    LOCAL valid_policy IS check_line(fairing_policy = "atmosphere" OR fairing_policy = "before_ignition"
        OR fairing_policy = "none", "Fairing policy", fairing_policy).
    LOCAL valid_twr IS check_line(ascent_twr_limit > 0, "Ascent TWR limit",
        ascent_twr_limit + " (dimensionless), required > 0").
    IF NOT (ready AND valid_site AND valid_target AND valid_policy AND valid_twr) {
        RETURN finish_launch("preflight checks failed before ignition").
    }
    transmit_log().

    IF options:HASKEY("launch_ut") {
        IF scheduled_launch_ut < TIME:SECONDS + 5 {
            RETURN finish_launch("scheduled launch window missed before ignition").
        }
        LOCAL countdown_ut IS scheduled_launch_ut - 5.
        LOCAL warp_stop IS scheduled_launch_ut - 20.
        IF TIME:SECONDS < warp_stop { KUNIVERSE:TIMEWARP:WARPTO(warp_stop). }
        LOCAL next_pad_display IS 0.
        UNTIL TIME:SECONDS >= countdown_ut AND flight_ready() {
            IF TERMINAL:INPUT:HASCHAR OR SHIP <> KUNIVERSE:ACTIVEVESSEL
                OR (SHIP:STATUS <> "PRELAUNCH" AND SHIP:STATUS <> "LANDED") {
                KUNIVERSE:TIMEWARP:CANCELWARP().
                RETURN finish_launch("scheduled launch cancelled before ignition").
            }
            IF TIME:SECONDS > countdown_ut + 1 {
                KUNIVERSE:TIMEWARP:CANCELWARP().
                RETURN finish_launch("warp did not settle for the scheduled countdown; no ignition").
            }
            IF KUNIVERSE:REALTIME >= next_pad_display {
                SET next_pad_display TO KUNIVERSE:REALTIME + 1.
                LOCAL pad_wait IS MAX(0, CEILING(scheduled_launch_ut - TIME:SECONDS)).
                CLEARSCREEN.
                PRINT "Launch in " + FLOOR(pad_wait / 60) + "m " + MOD(pad_wait, 60) + "s.".
                IF TIME:SECONDS < warp_stop { PRINT "Auto-warping. Stay on this vessel.". }
                ELSE { PRINT "Waiting on the pad. Stay on this vessel.". }
                PRINT "Press any key to cancel before ignition.".
            }
            checkpoint_log("Waiting on the pad for the scheduled launch").
            WAIT 0.
        }
        IF TIME:SECONDS > countdown_ut + 1 {
            RETURN finish_launch("launch countdown window missed before ignition").
        }
    }

    // Keep the pad's roll in the heading frame as pitch changes.
    LOCAL pad_heading IS HEADING(azimuth, 90).
    LOCAL pad_top IS VXCL(pad_heading:FOREVECTOR, SHIP:FACING:TOPVECTOR).
    IF pad_top:MAG < 0.001 { SET pad_top TO pad_heading:TOPVECTOR. }
    LOCAL pad_orientation IS LOOKDIRUP(pad_heading:FOREVECTOR, pad_top).
    LOCAL pad_roll IS pad_heading:INVERSE * pad_orientation.
    info_line("Liftoff roll", "preserving pad orientation, "
        + ROUND(VANG(pad_heading:TOPVECTOR, pad_orientation:TOPVECTOR), 1)
        + " deg from the default heading roll").
    transmit_log().

    SAS OFF.
    RCS OFF.
    GEAR OFF.
    LOCK THROTTLE TO throttle_cmd.
    LOCK STEERING TO HEADING(azimuth, pitch) * pad_roll.
    IF fairing_policy = "before_ignition" AND NOT deploy_fairings() {
        RETURN stop_launch("fairing jettison could not be verified before ignition").
    }
    FROM { LOCAL count IS 5. } UNTIL count = 0 STEP { SET count TO count - 1. } DO {
        CLEARSCREEN.
        PRINT "Launch in " + count + " s. Stay on this vessel.".
        log_line("Launch countdown T-" + count + " s.", FALSE).
        IF scheduled_launch_ut >= 0 {
            PRINT "Press any key to cancel before ignition.".
            UNTIL TIME:SECONDS >= scheduled_launch_ut - count + 1 {
                IF TERMINAL:INPUT:HASCHAR {
                    RETURN stop_launch("scheduled launch cancelled during countdown before ignition").
                }
                IF NOT flight_ready() { RETURN stop_launch("lost pad controls before ignition"). }
                WAIT 0.
            }
        } ELSE { WAIT 1. }
    }
    CLEARSCREEN.
    IF NOT flight_ready() { RETURN stop_launch("lost flight controls during countdown"). }
    IF scheduled_launch_ut >= 0 AND TERMINAL:INPUT:HASCHAR {
        RETURN stop_launch("scheduled launch cancelled before ignition").
    }
    IF scheduled_launch_ut >= 0 AND TIME:SECONDS > scheduled_launch_ut + 1 {
        RETURN stop_launch("scheduled launch window missed before ignition").
    }
    LOCAL pad_altitude IS SHIP:ALTITUDE.
    SET liftoff_longitude TO SHIP:LONGITUDE.
    SET throttle_cmd TO 1.
    IF NOT fire_next_stage("liftoff") { RETURN stop_launch("liftoff stage failed"). }

    LOCAL turn_start IS SHIP:ALTITUDE + 100.
    LOCAL turn_end IS turn_start + 49900.
    LOCAL turn_mid IS 16000.
    IF turn_mid <= turn_start OR turn_mid >= turn_end {
        SET turn_mid TO (turn_start + turn_end) / 2.
    }
    IF options:HASKEY("turn_mid_altitude") {
        LOCAL requested_mid IS options["turn_mid_altitude"].
        IF requested_mid > turn_start AND requested_mid < turn_end {
            SET turn_mid TO requested_mid.
        } ELSE {
            warn_line("Gravity-turn midpoint", requested_mid + " m outside " + ROUND(turn_start, 1)
                + " to " + ROUND(turn_end, 1) + " m. Using " + ROUND(turn_mid, 1) + " m").
        }
    }
    info_line("Gravity turn", "90 deg at " + ROUND(turn_start, 1) + " m, 45 deg at "
        + ROUND(turn_mid, 1) + " m, 0 deg at " + ROUND(turn_end, 1) + " m").
    LOCAL ascent_deadline IS TIME:SECONDS + 600.
    LOCAL liftoff_deadline IS TIME:SECONDS + 10.
    // A stage command can succeed before the engine produces thrust or the
    // vessel leaves the pad. Only arm subsequent automatic staging in flight.
    UNTIL (SHIP:STATUS <> "LANDED" AND SHIP:STATUS <> "PRELAUNCH"
        AND SHIP:ALTITUDE > pad_altitude + 1 AND SHIP:VERTICALSPEED > 0)
        OR TIME:SECONDS >= liftoff_deadline OR NOT flight_ready() {
        checkpoint_log("Waiting for liftoff").
        WAIT 0.
    }
    IF NOT flight_ready() { RETURN stop_launch("lost flight controls while waiting for liftoff"). }
    IF NOT check_line(SHIP:STATUS <> "LANDED" AND SHIP:STATUS <> "PRELAUNCH"
        AND SHIP:ALTITUDE > pad_altitude + 1 AND SHIP:VERTICALSPEED > 0,
        "Liftoff", SHIP:STATUS + ", altitude gain " + ROUND(SHIP:ALTITUDE - pad_altitude, 1)
        + " m (required > 1 m), vertical speed " + ROUND(SHIP:VERTICALSPEED, 1)
        + " m/s (required > 0 m/s), stage " + STAGE:NUMBER + ", thrust "
        + ROUND(SHIP:THRUST, 1) + " kN, within 10 s") {
        FOR eng IN SHIP:ENGINES {
            log_line("Liftoff engine " + eng:NAME + ": stage " + eng:STAGE + ", ignition=" + eng:IGNITION
                + ", flameout=" + eng:FLAMEOUT + ", thrust " + ROUND(eng:THRUST, 1)
                + " kN, available " + ROUND(eng:AVAILABLETHRUST, 1) + " kN.").
        }
        RETURN stop_launch("still on the pad 10 s after ignition; no later stage fired").
    }
    SET liftoff_ut TO TIME:SECONDS.
    IF scheduled_launch_ut >= 0 {
        info_line("Scheduled liftoff", "observed UT " + ROUND(liftoff_ut, 2) + " s, scheduled ignition UT "
            + ROUND(scheduled_launch_ut, 2) + " s, difference " + ROUND(liftoff_ut - scheduled_launch_ut, 2) + " s").
    }
    transmit_log().
    LOCAL inspected_stage IS -1.
    LOCAL pending_boosters IS LIST().
    UNTIL SHIP:APOAPSIS >= target_ap - 100 {
        IF NOT flight_ready() { RETURN stop_launch("lost flight controls during ascent"). }
        IF TIME:SECONDS >= ascent_deadline { RETURN stop_launch("ascent exceeded 600 s"). }
        IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "PRELAUNCH" {
            RETURN stop_launch("vessel returned to the ground during ascent").
        }
        IF fairing_policy = "atmosphere" AND fairings:LENGTH > 0 AND SHIP:ALTITUDE > atmosphere_top {
            SET throttle_cmd TO 0.
            WAIT 0.
            IF NOT flight_ready() OR NOT deploy_fairings() {
                RETURN stop_launch("fairing jettison could not be verified during ascent").
            }
        }
        IF STAGE:NUMBER <> inspected_stage {
            SET inspected_stage TO STAGE:NUMBER.
            SET pending_boosters TO LIST().
            IF inspected_stage > last_stage {
                LOCAL next_group IS launch_booster_group(inspected_stage - 1).
                SET pending_boosters TO next_group["engines"].
                IF pending_boosters:LENGTH > 0 {
                    info_line("Booster stage", "stage " + (inspected_stage - 1) + ", "
                        + pending_boosters:LENGTH + " engines to detach after all flame out").
                } ELSE IF next_group["reason"] <> "" {
                    info_line("Booster stage skipped", "stage " + (inspected_stage - 1) + ", " + next_group["reason"]).
                }
            }
        }
        IF NOT has_live_engine() {
            IF NOT fire_next_stage("engine flameout or no active thrust") {
                RETURN stop_launch("ascent ran out of thrust or allowed stages").
            }
        } ELSE IF STAGE:READY AND boosters_spent(pending_boosters) {
            // Re-read the stage in case its assignments changed since discovery.
            LOCAL current_group IS launch_booster_group(STAGE:NUMBER - 1).
            LOCAL current_boosters IS current_group["engines"].
            SET pending_boosters TO current_boosters.
            IF boosters_spent(current_boosters) {
                LOCAL booster_ids IS LIST().
                FOR eng IN current_boosters { booster_ids:ADD(eng:UID). }
                IF NOT fire_next_stage("all " + booster_ids:LENGTH + " booster engines flamed out; retained thrust available") {
                    RETURN stop_launch("spent booster stage failed").
                }
                LOCAL attached_count IS 0.
                FOR eng IN SHIP:ENGINES {
                    IF booster_ids:CONTAINS(eng:UID) { SET attached_count TO attached_count + 1. }
                }
                IF NOT check_line(attached_count = 0 AND has_live_engine(), "Booster separation",
                    attached_count + " of " + booster_ids:LENGTH + " booster engines still attached (required 0), "
                    + ROUND(SHIP:AVAILABLETHRUST, 1) + " kN available, retained engine live=" + has_live_engine()) {
                    RETURN stop_launch("booster separation or retained thrust failed").
                }
                transmit_log().
            }
        }
        LOCAL altitude_now IS SHIP:ALTITUDE.
        IF altitude_now <= turn_mid {
            SET pitch TO 90 - 45 * MAX(0, (altitude_now - turn_start) / (turn_mid - turn_start)).
        } ELSE {
            SET pitch TO 45 * MAX(0, (turn_end - altitude_now) / (turn_end - turn_mid)).
        }
        LOCAL gravity_here IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
        LOCAL ascent_thrust IS SHIP:AVAILABLETHRUST.
        IF ascent_thrust > 0 {
            SET throttle_cmd TO MAX(0.2, MIN(1, ascent_twr_limit * SHIP:MASS * gravity_here / ascent_thrust)).
        }
        ascent_sample().
        checkpoint_log("").
        WAIT 0.
    }

    SET throttle_cmd TO 0.
    WAIT 0.
    log_line("Ascent cutoff: Ap " + ROUND(SHIP:APOAPSIS, 1) + " m, target " + target_ap
        + " m, altitude " + ROUND(SHIP:ALTITUDE, 1) + " m.").
    transmit_log().
    LOCK STEERING TO PROGRADE.
    LOCAL next_display IS 0.
    UNTIL SHIP:ALTITUDE > atmosphere_top {
        IF NOT flight_ready() { RETURN stop_launch("lost flight controls during the atmospheric coast"). }
        IF SHIP:VERTICALSPEED <= 0 { RETURN stop_launch("coast stopped climbing below the atmosphere ceiling"). }
        IF TIME:SECONDS >= next_display {
            SET next_display TO TIME:SECONDS + 2.
            CLEARSCREEN.
            PRINT "Atmosphere exit in about " + CEILING((atmosphere_top - SHIP:ALTITUDE) / SHIP:VERTICALSPEED)
                + " s. Stay on this vessel.".
        }
        checkpoint_log("Coasting above the atmosphere before warp").
        WAIT 0.
    }
    IF fairing_policy = "atmosphere" AND NOT deploy_fairings() {
        RETURN stop_launch("fairing jettison could not be verified before circularisation").
    }
    IF NOT has_live_engine() {
        RETURN stop_launch("no active engine for circularisation").
    }

    LOCAL mu_body IS SHIP:BODY:MU.
    LOCAL apo_radius IS SHIP:BODY:RADIUS + SHIP:APOAPSIS.
    LOCAL apo_speed IS SQRT(mu_body * (2 / apo_radius - 1 / SHIP:OBT:SEMIMAJORAXIS)).
    LOCAL circ_dv IS MAX(0, SQRT(mu_body / apo_radius) - apo_speed).
    LOCAL wet_mass IS SHIP:MASS.
    LOCAL available_thrust IS SHIP:AVAILABLETHRUST.
    IF available_thrust <= 0 { RETURN stop_launch("no available thrust to plan circularisation"). }
    LOCAL burn_duration IS circ_dv * wet_mass / available_thrust.
    LOCAL original_lead IS burn_duration / 2.
    LOCAL ignition_lead IS original_lead.
    LOCAL timing_method IS "constant starting mass".
    IF half_dv_timing {
        LOCAL mass_flow IS 0.
        LOCAL modeled_thrust IS 0.
        FOR eng IN SHIP:ENGINES {
            IF eng:IGNITION AND NOT eng:FLAMEOUT AND eng:AVAILABLETHRUST > 0 AND eng:VACUUMISP > 0 {
                LOCAL engine_thrust IS eng:AVAILABLETHRUST.
                SET modeled_thrust TO modeled_thrust + engine_thrust.
                SET mass_flow TO mass_flow + engine_thrust / (eng:VACUUMISP * CONSTANT:G0).
            }
        }
        IF mass_flow > 0 AND ABS(modeled_thrust - available_thrust) <= 0.01 {
            // Invert the rocket equation for the time to deliver each delta-v.
            LOCAL exhaust_speed IS modeled_thrust / mass_flow.
            SET burn_duration TO wet_mass / mass_flow * (1 - CONSTANT:E^(-circ_dv / exhaust_speed)).
            SET ignition_lead TO wet_mass / mass_flow * (1 - CONSTANT:E^(-circ_dv / (2 * exhaust_speed))).
            SET timing_method TO "half delta-v".
        } ELSE {
            warn_line("Circularisation timing", "engine data incomplete, using constant starting mass").
        }
    }
    SET ignition_lead TO ignition_lead - ignition_delay.
    LOCAL ignition_ut IS TIME:SECONDS + ETA:APOAPSIS - ignition_lead.
    LOCAL latest_ignition IS ignition_ut + 5.
    LOCAL warp_buffer IS 45.
    log_line("Circularisation plan: " + ROUND(circ_dv, 1) + " m/s, " + ROUND(burn_duration, 1)
        + " s at full throttle, timing " + timing_method + ", lead " + ROUND(ignition_lead, 2)
        + " s, delay vs original " + ROUND(original_lead - ignition_lead, 2)
        + " s, ignition UT " + ROUND(ignition_ut, 2) + " s.").
    transmit_log().
    IF ignition_ut > TIME:SECONDS + warp_buffer {
        KUNIVERSE:TIMEWARP:WARPTO(ignition_ut - warp_buffer).
    }
    SET next_display TO 0.
    UNTIL TIME:SECONDS >= latest_ignition OR SHIP <> KUNIVERSE:ACTIVEVESSEL
        OR (TIME:SECONDS >= ignition_ut AND flight_ready()
        AND VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:ORBIT) <= 5) {
        IF TIME:SECONDS >= next_display {
            SET next_display TO TIME:SECONDS + 2.
            CLEARSCREEN.
            PRINT "Circularisation in " + MAX(0, CEILING(ignition_ut - TIME:SECONDS))
                + " s. Stay on this vessel.".
        }
        checkpoint_log("Coasting to circularisation").
        WAIT 0.
    }
    CLEARSCREEN.
    LOCAL pointing_error IS VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:ORBIT).
    IF TIME:SECONDS >= latest_ignition OR NOT flight_ready() OR pointing_error > 5 OR SHIP:ALTITUDE <= atmosphere_top {
        RETURN stop_launch("circularisation ignition window missed, pointing error "
            + ROUND(pointing_error, 2) + " deg (limit 5), now UT " + ROUND(TIME:SECONDS, 2)
            + " s, latest UT " + ROUND(latest_ignition, 2) + " s, flight ready=" + flight_ready()
            + ", altitude " + ROUND(SHIP:ALTITUDE, 1) + " m (must exceed " + atmosphere_top + " m)").
    }
    log_line("Circularisation burn starting. Throttle tapers once both apsides are within "
        + circularisation_taper_band + " m of " + target_ap + " m.").
    transmit_log().
    circularisation_sample("ignition").
    LOCAL throttle_started_at IS TIME:SECONDS.
    LOCAL thrust_ready_by IS throttle_started_at + 2.
    SET throttle_cmd TO circularisation_throttle().
    WAIT UNTIL SHIP:THRUST > 0 OR SHIP:AVAILABLETHRUST <= 0
        OR TIME:SECONDS >= thrust_ready_by OR NOT flight_ready()
        OR VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:ORBIT) > 5.
    IF NOT flight_ready() {
        RETURN stop_launch("lost flight controls while waiting for circularisation thrust").
    }
    SET pointing_error TO VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:ORBIT).
    IF pointing_error > 5 {
        RETURN stop_launch("circularisation ignition pointing error " + ROUND(pointing_error, 2) + " deg (limit 5)").
    }
    IF NOT check_line(SHIP:THRUST > 0, "Circularisation thrust",
        ROUND(SHIP:THRUST, 2) + " kN measured after " + ROUND(TIME:SECONDS - throttle_started_at, 2)
        + " s, required > 0 kN within 2 s, " + ROUND(SHIP:AVAILABLETHRUST, 2) + " kN available") {
        RETURN stop_launch("circularisation thrust did not start").
    }
    transmit_log().

    LOCAL current_eccentricity IS SHIP:OBT:ECCENTRICITY.
    LOCAL minimum_eccentricity IS current_eccentricity.
    LOCAL eccentricity_tolerance IS 0.0000001.
    SET next_sample TO TIME:SECONDS + 1.
    UNTIL SHIP:AVAILABLETHRUST <= 0 OR current_eccentricity > minimum_eccentricity + eccentricity_tolerance {
        IF NOT flight_ready() {
            circularisation_sample("abort").
            RETURN stop_launch("lost flight controls during circularisation").
        }
        SET pointing_error TO VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:ORBIT).
        IF pointing_error > 5 {
            circularisation_sample("abort").
            RETURN stop_launch("circularisation pointing error " + ROUND(pointing_error, 2) + " deg (limit 5)").
        }
        SET minimum_eccentricity TO MIN(minimum_eccentricity, current_eccentricity).
        SET throttle_cmd TO circularisation_throttle().
        IF TIME:SECONDS >= next_sample {
            SET next_sample TO TIME:SECONDS + 1.
            circularisation_sample("sample").
        }
        checkpoint_log("").
        WAIT 0.
        SET current_eccentricity TO SHIP:OBT:ECCENTRICITY.
    }
    circularisation_sample("cutoff").
    IF SHIP:AVAILABLETHRUST <= 0 { RETURN stop_launch("circularisation ran out of thrust"). }
    log_line("Circularisation cutoff: eccentricity rose from " + ROUND(minimum_eccentricity, 8)
        + " to " + ROUND(current_eccentricity, 8) + " at throttle " + ROUND(throttle_cmd, 2)
        + ", Ap " + ROUND(SHIP:APOAPSIS, 1) + " m, Pe " + ROUND(SHIP:PERIAPSIS, 1) + " m.").
    SET throttle_cmd TO 0.
    SET circularisation_end_ut TO TIME:SECONDS.
    // Longitude is body-fixed. Add the body's sidereal rotation to recover eastward inertial advance.
    LOCAL measured_ascent IS circularisation_end_ut - liftoff_ut.
    SET ascent_angle TO MOD(SHIP:LONGITUDE - liftoff_longitude
        + 360 * measured_ascent / SHIP:BODY:ROTATIONPERIOD + 540, 360) - 180.
    info_line("Ascent calibration", "liftoff UT " + ROUND(liftoff_ut, 2)
        + " s, circularisation cutoff UT " + ROUND(circularisation_end_ut, 2)
        + " s, ascent " + ROUND(measured_ascent, 2) + " s, inertial advance " + ROUND(ascent_angle, 3) + " deg").
    WAIT 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SAS ON.
    RETURN finish_launch("circularisation stopped at minimum eccentricity", TRUE).
}
