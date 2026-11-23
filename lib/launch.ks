@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"

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
    IF options:HASKEY("heading") { SET azimuth TO options["heading"]. }
    IF options:HASKEY("target_altitude") { SET target_ap TO options["target_altitude"]. }
    IF options:HASKEY("fairing_policy") { SET fairing_policy TO options["fairing_policy"]. }
    IF options:HASKEY("minimum_pe") { SET minimum_pe TO options["minimum_pe"]. }
    IF options:HASKEY("last_stage") { SET last_stage TO options["last_stage"]. }
    IF options:HASKEY("ignition_delay") { SET ignition_delay TO options["ignition_delay"]. }
    IF options:HASKEY("half_dv_timing") { SET half_dv_timing TO options["half_dv_timing"]. }

    LOCAL throttle_cmd IS 0.
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
            "remaining_dv", remaining_dv).
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

    FUNCTION ascent_sample {
        IF TIME:SECONDS < next_sample { RETURN. }
        SET next_sample TO TIME:SECONDS + 5.
        log_line("Ascent: altitude " + ROUND(SHIP:ALTITUDE, 1)
            + " m, Ap " + ROUND(SHIP:APOAPSIS, 1) + " m, Pe " + ROUND(SHIP:PERIAPSIS, 1)
            + " m, surface speed " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1)
            + " m/s, pitch target " + ROUND(pitch, 1) + " deg, throttle " + ROUND(throttle_cmd, 2)
            + ", stage delta-v " + ROUND(STAGE:DELTAV:CURRENT, 1) + " m/s.", FALSE).
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
    IF NOT (ready AND valid_site AND valid_target AND valid_policy) {
        RETURN finish_launch("preflight checks failed before ignition").
    }
    transmit_log().

    SAS OFF.
    RCS OFF.
    GEAR OFF.
    LOCK THROTTLE TO throttle_cmd.
    LOCK STEERING TO HEADING(azimuth, pitch).
    IF fairing_policy = "before_ignition" AND NOT deploy_fairings() {
        RETURN stop_launch("fairing jettison could not be verified before ignition").
    }
    FROM { LOCAL count IS 5. } UNTIL count = 0 STEP { SET count TO count - 1. } DO {
        CLEARSCREEN.
        PRINT "Launch in " + count + " s. Stay on this vessel.".
        log_line("Launch countdown T-" + count + " s.", FALSE).
        WAIT 1.
    }
    CLEARSCREEN.
    IF NOT flight_ready() { RETURN stop_launch("lost flight controls during countdown"). }
    SET throttle_cmd TO 1.
    IF NOT fire_next_stage("liftoff") { RETURN stop_launch("liftoff stage failed"). }

    LOCAL turn_start IS SHIP:ALTITUDE + 100.
    LOCAL turn_end IS turn_start + 49900.
    LOCAL ascent_deadline IS TIME:SECONDS + 600.
    LOCAL liftoff_deadline IS TIME:SECONDS + 10.
    UNTIL SHIP:APOAPSIS >= target_ap - 100 {
        IF NOT flight_ready() { RETURN stop_launch("lost flight controls during ascent"). }
        IF TIME:SECONDS >= ascent_deadline { RETURN stop_launch("ascent exceeded 600 s"). }
        IF TIME:SECONDS >= liftoff_deadline AND (SHIP:STATUS = "LANDED" OR SHIP:STATUS = "PRELAUNCH") {
            RETURN stop_launch("still on the pad 10 s after ignition").
        }
        IF fairing_policy = "atmosphere" AND fairings:LENGTH > 0 AND SHIP:ALTITUDE > atmosphere_top {
            SET throttle_cmd TO 0.
            WAIT 0.
            IF NOT flight_ready() OR NOT deploy_fairings() {
                RETURN stop_launch("fairing jettison could not be verified during ascent").
            }
        }
        IF NOT has_live_engine() AND NOT fire_next_stage("engine flameout or no active thrust") {
            RETURN stop_launch("ascent ran out of thrust or allowed stages").
        }
        LOCAL turn_fraction IS MAX(0, MIN(1, (SHIP:ALTITUDE - turn_start) / (turn_end - turn_start))).
        SET pitch TO 90 * (1 - turn_fraction).
        LOCAL gravity_here IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
        IF SHIP:AVAILABLETHRUST > 0 {
            SET throttle_cmd TO MAX(0.2, MIN(1, 2.5 * SHIP:MASS * gravity_here / SHIP:AVAILABLETHRUST)).
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
    log_line("Circularisation burn starting.").
    transmit_log().
    circularisation_sample("ignition").
    // Preserve launch.ks's tested taper and eccentricity cutoff.
    LOCAL previous_eccentricity IS SHIP:OBT:ECCENTRICITY.
    LOCAL current_eccentricity IS previous_eccentricity.
    SET next_sample TO TIME:SECONDS + 1.
    UNTIL SHIP:AVAILABLETHRUST <= 0 OR current_eccentricity > previous_eccentricity {
        IF NOT flight_ready() {
            circularisation_sample("abort").
            RETURN stop_launch("lost flight controls during circularisation").
        }
        SET pointing_error TO VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:ORBIT).
        IF pointing_error > 5 {
            circularisation_sample("abort").
            RETURN stop_launch("circularisation pointing error " + ROUND(pointing_error, 2) + " deg (limit 5)").
        }
        SET previous_eccentricity TO current_eccentricity.
        SET throttle_cmd TO MIN(1, current_eccentricity / 0.05).
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
    log_line("Circularisation cutoff: eccentricity rose from " + ROUND(previous_eccentricity, 8)
        + " to " + ROUND(current_eccentricity, 8) + " at throttle " + ROUND(throttle_cmd, 2)
        + ", Ap " + ROUND(SHIP:APOAPSIS, 1) + " m, Pe " + ROUND(SHIP:PERIAPSIS, 1) + " m.").
    SET throttle_cmd TO 0.
    WAIT 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    SAS ON.
    RETURN finish_launch("circularisation stopped at minimum eccentricity", TRUE).
}
