// Assign /boot/jeblink_carrier.ks to the carrier processor.
// To restart manually, RUNPATH("0:/boot/jeblink_carrier.ks", original_count).
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/launch.ks"
DECLARE PARAMETER constellation_size IS 0.

LOCAL next_display IS 0.
LOCAL warp_buffer IS 20.

FUNCTION coast_display {
    PARAMETER event_name, seconds_left, aligning IS FALSE.
    IF TIME:SECONDS < next_display { RETURN. }
    SET next_display TO TIME:SECONDS + 2.
    LOCAL seconds_remaining IS MAX(0, CEILING(seconds_left)).
    CLEARSCREEN.
    PRINT event_name + " in " + FLOOR(seconds_remaining / 60) + "m "
        + MOD(seconds_remaining, 60) + "s".
    IF aligning {
        PRINT "Aligning for insertion. Stay on the carrier at 1x.".
    } ELSE IF KUNIVERSE:TIMEWARP:RATE > 1.01 {
        PRINT "Auto-warping. Stay on the carrier.".
    } ELSE {
        PRINT "Stay on the carrier. No input needed.".
    }
    PRINT "The carrier acts automatically.".
}

FUNCTION time_to_release {
    PARAMETER earliest_release, release_lead.
    LOCAL next_pass IS TIME:SECONDS + ETA:APOAPSIS - release_lead.
    LOCAL period IS SHIP:OBT:PERIOD.
    LOCAL first_eligible_time IS MAX(TIME:SECONDS, earliest_release).
    LOCAL extra_laps IS MAX(0, CEILING((first_eligible_time - next_pass) / period)).
    RETURN next_pass + extra_laps * period - TIME:SECONDS.
}

FUNCTION warp_to_coast_end {
    PARAMETER event_name, seconds_until_event.
    IF seconds_until_event > warp_buffer {
        log_line("Auto-warping to " + warp_buffer + " s before " + event_name
            + ". Planned " + event_name + " in " + ROUND(seconds_until_event, 1) + " s.").
        transmit_log().
        KUNIVERSE:TIMEWARP:WARPTO(TIME:SECONDS + seconds_until_event - warp_buffer).
    }
}

FUNCTION wait_for_enter {
    PARAMETER phase.
    TERMINAL:INPUT:CLEAR().
    UNTIL FALSE {
        IF TERMINAL:INPUT:HASCHAR {
            IF TERMINAL:INPUT:GETCHAR() = TERMINAL:INPUT:RETURN { RETURN. }
        }
        checkpoint_log(phase).
        WAIT 0.
    }
}

FUNCTION parking_orbit_ready {
    RETURN SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:UNPACKED
        AND SHIP:BODY:NAME = "Kerbin" AND SHIP:STATUS = "ORBITING"
        AND SHIP:PERIAPSIS >= 75000.
}

FUNCTION carrier_poodles {
    LOCAL poodles IS LIST().
    FOR eng IN SHIP:ENGINES {
        IF eng:NAME = "liquidEngine2-2.v2" OR eng:NAME = "liquidEngine2-2_v2" {
            poodles:ADD(eng).
        }
    }
    RETURN poodles.
}

FUNCTION poodle_reserve_dv {
    PARAMETER poodle.
    LOCAL propellants IS poodle:CONSUMEDRESOURCES.
    IF NOT (propellants:HASKEY("LiquidFuel") AND propellants:HASKEY("Oxidizer")) {
        warn_line("Poodle propellants", "LiquidFuel and Oxidizer data are required for the reserve estimate").
        RETURN 0.
    }
    LOCAL fuel IS propellants["LiquidFuel"].
    LOCAL oxidizer IS propellants["Oxidizer"].
    LOCAL wet_mass IS SHIP:MASS.
    LOCAL vacuum_isp IS poodle:VACUUMISP.
    info_line("Poodle propellant", "LiquidFuel " + ROUND(fuel:AMOUNT, 2) + " u, Oxidizer "
        + ROUND(oxidizer:AMOUNT, 2) + " u, vessel mass " + ROUND(wet_mass, 3)
        + " t, vacuum Isp " + ROUND(vacuum_isp, 1) + " s").
    IF fuel:RATIO <= 0 OR oxidizer:RATIO <= 0 OR fuel:DENSITY <= 0
        OR oxidizer:DENSITY <= 0 OR vacuum_isp <= 0 {
        warn_line("Poodle propellant", "Fuel ratios, densities, and vacuum Isp must be positive").
        RETURN 0.
    }
    LOCAL mixtures IS MIN(fuel:AMOUNT / fuel:RATIO, oxidizer:AMOUNT / oxidizer:RATIO).
    LOCAL usable_mass IS mixtures * (fuel:RATIO * fuel:DENSITY + oxidizer:RATIO * oxidizer:DENSITY).
    IF usable_mass <= 0 OR usable_mass >= wet_mass {
        warn_line("Poodle propellant", ROUND(usable_mass, 3) + " t usable, must be > 0 and below "
            + ROUND(wet_mass, 3) + " t wet mass").
        RETURN 0.
    }
    info_line("Poodle usable propellant", ROUND(usable_mass, 3) + " t at the engine mixture ratio").
    RETURN vacuum_isp * CONSTANT:G0 * LN(wet_mass / (wet_mass - usable_mass)).
}

FUNCTION carrier_phasing_plan {
    PARAMETER relay_count.
    LOCAL mu IS SHIP:BODY:MU.
    LOCAL radius IS SHIP:BODY:RADIUS.
    LOCAL apo_radius IS radius + SHIP:APOAPSIS.
    LOCAL circular_period IS 2 * CONSTANT:PI * SQRT(apo_radius^3 / mu).
    FROM { LOCAL laps IS 1. } UNTIL laps > 12 STEP { SET laps TO laps + 1. } DO {
        LOCAL target_period IS circular_period * (1 - 1 / (relay_count * laps)).
        LOCAL target_axis IS apo_radius * (target_period / circular_period)^(2 / 3).
        LOCAL target_pe IS 2 * target_axis - apo_radius - radius.
        IF target_pe >= 75000 {
            LOCAL insertion_dv IS SQRT(mu * (2 / apo_radius - 1 / SHIP:OBT:SEMIMAJORAXIS))
                - SQRT(mu * (2 / apo_radius - 1 / target_axis)).
            RETURN LEXICON("laps", laps, "period", target_period, "pe", target_pe,
                "tolerance", circular_period / (360 * laps), "insertion_dv", insertion_dv).
        }
    }
    RETURN LEXICON().
}

FUNCTION launch_setting {
    PARAMETER label, default_value, lower, upper.
    UNTIL FALSE {
        PRINT label + " (" + lower + " to " + upper + ", Enter for " + default_value + ")".
        LOCAL buffer IS "".
        LOCAL input_row IS TERMINAL:HEIGHT - 2.
        PRINT ">                     " AT (0, input_row).
        UNTIL FALSE {
            IF TERMINAL:INPUT:HASCHAR {
                LOCAL key IS TERMINAL:INPUT:GETCHAR().
                IF key = TERMINAL:INPUT:RETURN { BREAK. }
                IF key = TERMINAL:INPUT:BACKSPACE AND buffer:LENGTH > 0 {
                    SET buffer TO buffer:SUBSTRING(0, buffer:LENGTH - 1).
                } ELSE IF key:MATCHESPATTERN("^[0-9.]$") AND buffer:LENGTH < 10 {
                    SET buffer TO buffer + key.
                }
                PRINT "> " + buffer + "              " AT (0, input_row).
            }
            checkpoint_log("Waiting for " + label).
            WAIT 0.
        }
        IF buffer = "" { RETURN default_value. }
        LOCAL entered IS buffer:TONUMBER(-1).
        IF entered >= lower AND entered <= upper { RETURN entered. }
        CLEARSCREEN.
        PRINT "Enter a number from " + lower + " to " + upper + ".".
    }
}

FUNCTION launch_carrier_from_pad {
    log_line("Select the Jeblink carrier and settle at 1x for pad preflight.").
    transmit_log().
    UNTIL SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:UNPACKED
        AND KUNIVERSE:TIMEWARP:ISSETTLED AND KUNIVERSE:TIMEWARP:RATE <= 1.01 {
        checkpoint_log("Waiting for pad flight controls").
        WAIT 0.
    }
    LOCAL engines IS carrier_poodles().
    LOCAL poodle_ok IS check_line(engines:LENGTH = 1, "Carrier Poodle count",
        engines:LENGTH + ", required 1").
    LOCAL fairing_count IS 0.
    FOR fairing IN SHIP:MODULESNAMED("ModuleProceduralFairing") {
        IF fairing:HASEVENT("deploy") OR fairing:HASEVENT("deploy fairing") {
            SET fairing_count TO fairing_count + 1.
            info_line("Fairing placement", fairing:PART:NAME + ", configured stage " + fairing:PART:STAGE).
        } ELSE {
            warn_line("Fairing deploy event unavailable", fairing:PART:NAME + ", events " + fairing:ALLEVENTNAMES).
        }
    }
    LOCAL fairing_ok IS check_line(fairing_count > 0, "Deployable fairing count",
        fairing_count + ", required at least 1").
    IF NOT (poodle_ok AND fairing_ok) {
        log_line("Launch stopped before ignition. Check the carrier engine and payload fairing in the VAB.").
        RETURN FALSE.
    }

    LOCAL poodle_stage IS engines[0]:STAGE.
    LOCAL relays IS SHIP:PARTSNAMED("probeCoreCube").
    LOCAL relay_layout_ok IS check_line(relays:LENGTH >= 2, "Mounted relays",
        relays:LENGTH + ", required at least 2").
    LOCAL stages_ok IS check_line(poodle_stage >= 0 AND poodle_stage < STAGE:NUMBER, "Poodle stage",
        "Poodle stage " + poodle_stage + ", current stage " + STAGE:NUMBER + ", required 0 <= Poodle stage < current stage").
    FOR relay IN relays {
        LOCAL separation_stage IS relay:DECOUPLEDIN.
        LOCAL relay_ok IS check_line(separation_stage < poodle_stage, "Relay stages " + relay:UID,
            "separation stage " + separation_stage + ", must be below last ascent stage " + poodle_stage + " or -1").
        SET relay_layout_ok TO relay_layout_ok AND relay_ok.
    }
    IF NOT (relay_layout_ok AND stages_ok) {
        log_line("Launch stopped before ignition. Remove relay separators from ascent staging and rerun.").
        RETURN FALSE.
    }
    LOCAL site_ok IS check_line(SHIP:BODY:NAME = "Kerbin" AND SHIP = KUNIVERSE:ACTIVEVESSEL
        AND SHIP:UNPACKED AND KUNIVERSE:TIMEWARP:ISSETTLED AND KUNIVERSE:TIMEWARP:RATE <= 1.01,
        "Carrier launch site", SHIP:BODY:NAME + ", active=" + (SHIP = KUNIVERSE:ACTIVEVESSEL)
        + ", unpacked=" + SHIP:UNPACKED + ", settled=" + KUNIVERSE:TIMEWARP:ISSETTLED
        + ", warp " + KUNIVERSE:TIMEWARP:RATE + "x (limit 1.01x)").
    IF NOT site_ok {
        log_line("Launch stopped before ignition. Select the unpacked carrier on Kerbin at 1x and rerun.").
        RETURN FALSE.
    }
    transmit_log().
    CLEARSCREEN.
    TERMINAL:INPUT:CLEAR().
    LOCAL azimuth IS launch_setting("Launch heading in degrees", 90, 0, 359.999).
    CLEARSCREEN.
    LOCAL altitude_km IS launch_setting("Constellation altitude in km", 100, 80, 9999).
    CLEARSCREEN.
    log_line("Press Enter to launch Jeblink, heading " + azimuth + " deg, target " + altitude_km + " km.").
    transmit_log().
    wait_for_enter("Waiting for launch confirmation").
    CLEARSCREEN.
    LOCAL result IS launch_to_orbit(LEXICON("heading", azimuth, "target_altitude", altitude_km * 1000,
        "minimum_pe", 75000, "fairing_policy", "atmosphere", "last_stage", poodle_stage)).
    IF NOT result["success"] {
        log_line("Phasing was skipped. Launch stopped: " + result["reason"]
            + ". Check the logged orbit and recover the carrier before restarting.").
        RETURN FALSE.
    }
    LOCAL mounted_count IS SHIP:PARTSNAMED("probeCoreCube"):LENGTH.
    IF NOT check_line(mounted_count = relays:LENGTH, "Relays after ascent",
        mounted_count + " mounted, expected " + relays:LENGTH) {
        log_line("Phasing was skipped. The mounted relay count changed during ascent.").
        RETURN FALSE.
    }
    LOCAL planned_count IS relays:LENGTH.
    IF constellation_size > planned_count { SET planned_count TO constellation_size. }
    LOCAL plan IS carrier_phasing_plan(planned_count).
    IF plan:LENGTH = 0 {
        log_line("Phasing was skipped. No phasing orbit can keep Pe at least 75 km within 12 laps per release.").
        RETURN FALSE.
    }
    LOCAL poodle IS engines[0].
    LOCAL poodle_ready IS check_line(STAGE:NUMBER = poodle_stage AND poodle:IGNITION
        AND NOT poodle:FLAMEOUT AND poodle:AVAILABLETHRUST > 0
        AND SHIP:AVAILABLETHRUST <= poodle:AVAILABLETHRUST + 0.01,
        "Poodle insertion engine", "stage " + STAGE:NUMBER + " (expected " + poodle_stage + ")"
        + ", ignition=" + poodle:IGNITION + ", flameout=" + poodle:FLAMEOUT
        + ", engine " + ROUND(poodle:AVAILABLETHRUST, 2) + " kN, vessel "
        + ROUND(SHIP:AVAILABLETHRUST, 2) + " kN (extra thrust limit 0.01 kN)").
    info_line("KSP delta-v readouts", "stage " + ROUND(STAGE:DELTAV:VACUUM, 1)
        + " m/s, vessel " + ROUND(result["remaining_dv"], 1) + " m/s").
    LOCAL remaining_dv IS 0.
    IF poodle_ready { SET remaining_dv TO poodle_reserve_dv(poodle). }
    LOCAL insertion_dv IS plan["insertion_dv"].
    LOCAL required_dv IS MAX(0, insertion_dv) + 10.
    LOCAL dv_ok IS check_line(remaining_dv >= required_dv, "Poodle insertion delta-v",
        ROUND(remaining_dv, 1) + " m/s estimated from accessible propellant, " + ROUND(MAX(0, insertion_dv), 1)
        + " m/s burn plus 10 m/s margin").
    IF NOT (poodle_ready AND dv_ok) {
        log_line("Phasing was skipped. Confirm the Poodle is the sole active engine and has the logged fuel margin.").
        RETURN FALSE.
    }
    RETURN TRUE.
}

FUNCTION padded_number {
    PARAMETER number.
    IF number < 10 { RETURN "0" + number. }
    RETURN "" + number.
}

FUNCTION random_train_code {
    LOCAL alphabet IS "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".
    LOCAL train_code IS "".
    UNTIL train_code:LENGTH = 4 {
        LOCAL index IS FLOOR(RANDOM() * alphabet:LENGTH).
        SET train_code TO train_code + alphabet:SUBSTRING(index, 1).
    }
    RETURN train_code.
}

FUNCTION deploy_constellation {
    log_line("Jeblink carrier booted. Waiting for an active Kerbin parking orbit with Pe at least 75 km.").
    transmit_log().
    UNTIL parking_orbit_ready() {
        checkpoint_log("Waiting for parking orbit").
        WAIT 0.
    }
    LOCAL armed IS FALSE.
    UNTIL armed {
        log_line("Press Enter to begin phasing once the parking orbit is final and any ascent script has finished.").
        transmit_log().
        wait_for_enter("Waiting for phasing confirmation").
        LOCAL active_carrier IS SHIP = KUNIVERSE:ACTIVEVESSEL.
        LOCAL warp_rate IS KUNIVERSE:TIMEWARP:RATE.
        SET armed TO parking_orbit_ready() AND warp_rate <= 1.01.
        IF NOT armed {
            IF NOT active_carrier { log_line("Cannot arm: carrier is not the active vessel."). }
            IF NOT SHIP:UNPACKED { log_line("Cannot arm: carrier is outside full physics."). }
            IF SHIP:BODY:NAME <> "Kerbin" OR SHIP:STATUS <> "ORBITING" {
                log_line("Cannot arm: expected Kerbin orbit, got " + SHIP:BODY:NAME + " / " + SHIP:STATUS + ".").
            }
            IF SHIP:PERIAPSIS < 75000 {
                log_line("Cannot arm: Pe is " + ROUND(SHIP:PERIAPSIS / 1000, 3) + " km. Minimum is 75 km.").
            }
            IF warp_rate > 1.01 {
                log_line("Cannot arm: time warp is " + ROUND(warp_rate, 2) + "x. Return to 1x.").
            }
            transmit_log().
        }
    }

    LOCAL satellites IS SHIP:PARTSNAMED("probeCoreCube").
    LOCAL remaining IS satellites:LENGTH.
    LOCAL train_name IS "".
    // Keep the original constellation size with the code across processor reboots.
    IF SHIP:ROOTPART:TAG:MATCHESPATTERN("^[A-Z0-9]{4}/[0-9]+$") {
        LOCAL train_fields IS SHIP:ROOTPART:TAG:SPLIT("/").
        SET train_name TO train_fields[0].
        LOCAL original_count IS train_fields[1]:TONUMBER().
        IF constellation_size <> 0 AND constellation_size <> original_count {
            log_line("This train already has " + original_count + " relay slots. Rerun with that count.").
            RETURN.
        }
        SET constellation_size TO original_count.
    }
    IF constellation_size = 0 { SET constellation_size TO remaining. }
    IF remaining = 0 OR constellation_size < remaining OR constellation_size < 2
        OR constellation_size <> FLOOR(constellation_size) {
        log_line("No valid Jeblink constellation count.").
        RETURN.
    }
    IF train_name = "" {
        SET train_name TO random_train_code().
        SET SHIP:ROOTPART:TAG TO train_name + "/" + constellation_size.
    }
    LOCAL carrier_name IS "Jeblink JL-" + train_name + "-CARRIER".
    SET SHIP:NAME TO carrier_name.
    SET SHIP:TYPE TO "Probe".
    log_line("Carrier identity: " + SHIP:NAME + ", core UID " + SHIP:ROOTPART:UID + ".").
    LOCAL relay_slot IS constellation_size - remaining + 1.
    FOR probe_core IN satellites {
        IF NOT probe_core:TAG:MATCHESPATTERN("^" + train_name + "-[0-9]{2,}$") {
            SET probe_core:TAG TO train_name + "-" + padded_number(relay_slot).
        }
        log_line("Mounted relay " + probe_core:TAG + ", QBE UID " + probe_core:UID + ".", FALSE).
        SET relay_slot TO relay_slot + 1.
    }

    LOCAL target_apoapsis IS SHIP:APOAPSIS.
    LOCAL plan IS carrier_phasing_plan(constellation_size).
    IF plan:LENGTH = 0 {
        log_line("No phasing orbit above 75 km found within 12 carrier laps per release.").
        RETURN.
    }
    LOCAL coast_laps IS plan["laps"].
    LOCAL target_period IS plan["period"].
    LOCAL target_pe IS plan["pe"].
    LOCAL period_tolerance IS plan["tolerance"].
    log_line("Starting orbit: Ap " + ROUND(SHIP:APOAPSIS / 1000, 2) + " km, Pe "
        + ROUND(SHIP:PERIAPSIS / 1000, 2) + " km, period " + ROUND(SHIP:OBT:PERIOD, 2) + " s.").
    log_line(remaining + " mounted, " + constellation_size + " planned, "
        + ROUND(360 / constellation_size, 2) + " deg spacing.").
    log_line("Carrier target Pe " + ROUND(target_pe / 1000, 2) + " km, Ap "
        + ROUND(target_apoapsis / 1000, 2) + " km, " + coast_laps + " lap(s) per release.").

    FUNCTION orbit_ready {
        RETURN SHIP:PERIAPSIS >= 75000
            AND ABS(SHIP:APOAPSIS - target_apoapsis) <= 1000
            AND ABS(SHIP:OBT:PERIOD - target_period) <= period_tolerance.
    }

    IF NOT orbit_ready() {
        IF SHIP:PERIAPSIS <= target_pe {
            log_line("Carrier orbit is already below the target periapsis. Raise Pe and rerun.").
            RETURN.
        }
        LOCAL carrier_engines IS carrier_poodles().
        IF carrier_engines:LENGTH <> 1 {
            log_line("Expected one Jeblink carrier Poodle. No insertion burn.").
            RETURN.
        }
        LOCAL carrier_engine IS carrier_engines[0].
        LOCAL throttle_cmd IS 0.
        FUNCTION log_insertion_state {
            PARAMETER phase.
            log_line(phase + ": Ap " + ROUND(SHIP:APOAPSIS / 1000, 2)
                + " km, Pe " + ROUND(SHIP:PERIAPSIS / 1000, 2)
                + " km, ETA Ap " + ROUND(ETA:APOAPSIS, 1)
                + " s, period error " + ROUND(SHIP:OBT:PERIOD - target_period, 2)
                + " s, retrograde error " + ROUND(VANG(SHIP:FACING:FOREVECTOR, -SHIP:VELOCITY:ORBIT), 2)
                + " deg, throttle " + ROUND(throttle_cmd, 2) + ", thrust "
                + ROUND(carrier_engine:THRUST, 2) + " kN, flameout " + carrier_engine:FLAMEOUT
                + ", SAS " + SAS + "/" + SASMODE, FALSE).
        }
        LOCK THROTTLE TO throttle_cmd.
        carrier_engine:ACTIVATE().
        WAIT 0.
        LOCAL thrust_available IS carrier_engine:AVAILABLETHRUST.
        IF thrust_available <= 0 OR SHIP:AVAILABLETHRUST > thrust_available + 0.01 {
            carrier_engine:SHUTDOWN().
            UNLOCK THROTTLE.
            log_line("Expected thrust from the carrier Poodle only. No insertion burn.").
            RETURN.
        }
        LOCAL delta_v IS plan["insertion_dv"].
        LOCAL burn_lead IS MAX(0.5, delta_v * SHIP:MASS / thrust_available / 2).
        log_line("Insertion burn: " + ROUND(delta_v, 1) + " m/s, ignition "
            + ROUND(burn_lead, 1) + " s before apoapsis.").
        LOCAL seconds_until_insertion IS ETA:APOAPSIS - burn_lead.
        IF seconds_until_insertion <= 0 {
            SET seconds_until_insertion TO seconds_until_insertion + SHIP:OBT:PERIOD.
        }
        LOCAL ignition_time IS TIME:SECONDS + seconds_until_insertion.
        LOCAL latest_ignition IS ignition_time + 2.
        log_line("Planned insertion ignition UT " + ROUND(ignition_time, 2) + " s.", FALSE).
        warp_to_coast_end("insertion ignition", seconds_until_insertion).
        SET next_display TO 0.
        UNTIL TIME:SECONDS >= ignition_time - warp_buffer OR SHIP <> KUNIVERSE:ACTIVEVESSEL {
            coast_display("Insertion burn", ignition_time - TIME:SECONDS).
            checkpoint_log("Coasting to insertion").
            WAIT 0.
        }
        UNTIL (KUNIVERSE:TIMEWARP:ISSETTLED AND KUNIVERSE:TIMEWARP:RATE <= 1.01 AND SHIP:UNPACKED)
            OR TIME:SECONDS >= latest_ignition OR SHIP <> KUNIVERSE:ACTIVEVESSEL {
            checkpoint_log("Waiting for full physics after insertion warp").
            WAIT 0.
        }
        CLEARSCREEN.
        log_insertion_state("After insertion coast").
        IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR KUNIVERSE:TIMEWARP:RATE > 1.01
            OR NOT KUNIVERSE:TIMEWARP:ISSETTLED OR NOT SHIP:UNPACKED OR TIME:SECONDS >= latest_ignition {
            log_line("Insertion skipped: carrier did not reach the ignition window ready. Active="
                + (SHIP = KUNIVERSE:ACTIVEVESSEL) + ", rate "
                + KUNIVERSE:TIMEWARP:RATE + "x, settled=" + KUNIVERSE:TIMEWARP:ISSETTLED
                + ", unpacked=" + SHIP:UNPACKED + ", seconds past planned ignition="
                + ROUND(TIME:SECONDS - ignition_time, 2) + " (limit 2).").
            carrier_engine:SHUTDOWN().
            UNLOCK THROTTLE.
            RETURN.
        }
        SET next_display TO 0.
        coast_display("Planned ignition", ignition_time - TIME:SECONDS, TRUE).
        SET NAVMODE TO "ORBIT".
        SAS OFF.
        WAIT 0.
        SAS ON.
        WAIT 0.5.
        SET SASMODE TO "STABILITYASSIST".
        WAIT 0.
        log_insertion_state("Stability Assist selected after coast").
        LOCAL next_sas_request IS TIME:SECONDS.
        UNTIL (TIME:SECONDS >= ignition_time
            AND SAS AND SASMODE = "RETROGRADE"
            AND VANG(SHIP:FACING:FOREVECTOR, -SHIP:VELOCITY:ORBIT) <= 5)
            OR TIME:SECONDS >= latest_ignition OR SHIP <> KUNIVERSE:ACTIVEVESSEL
            OR NOT SHIP:UNPACKED OR KUNIVERSE:TIMEWARP:RATE > 1.01 {
            coast_display("Planned ignition", ignition_time - TIME:SECONDS, TRUE).
            IF TIME:SECONDS >= next_sas_request AND SAS AND SASMODE <> "RETROGRADE" {
                SET SASMODE TO "RETROGRADE".
                WAIT 0.
                log_insertion_state("Retrograde requested after coast").
                SET next_sas_request TO TIME:SECONDS + 0.5.
            }
            checkpoint_log("Aligning and waiting for timed insertion").
            WAIT 0.
        }
        LOCAL ignition_error IS VANG(SHIP:FACING:FOREVECTOR, -SHIP:VELOCITY:ORBIT).
        log_insertion_state("Insertion ignition check").
        IF TIME:SECONDS >= latest_ignition OR SHIP <> KUNIVERSE:ACTIVEVESSEL
            OR NOT SHIP:UNPACKED OR KUNIVERSE:TIMEWARP:RATE > 1.01
            OR NOT SAS OR SASMODE <> "RETROGRADE" OR ignition_error > 5 {
            log_line("Insertion skipped: error " + ROUND(ignition_error, 2)
                + " deg (limit 5), SAS " + SAS + "/" + SASMODE + ", active="
                + (SHIP = KUNIVERSE:ACTIVEVESSEL) + ", unpacked=" + SHIP:UNPACKED
                + ", warp " + KUNIVERSE:TIMEWARP:RATE + "x, seconds past planned ignition="
                + ROUND(TIME:SECONDS - ignition_time, 2) + " (limit 2).").
            carrier_engine:SHUTDOWN().
            UNLOCK THROTTLE.
            RETURN.
        }
        log_line("Insertion burn started. Stay on the carrier at 1x.").
        LOCAL arrival_deadline IS TIME:SECONDS + 2 * burn_lead + 10.
        LOCAL next_sample IS TIME:SECONDS + 0.5.
        UNTIL orbit_ready() OR SHIP:PERIAPSIS <= target_pe
            OR SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED
            OR KUNIVERSE:TIMEWARP:RATE > 1.01 OR TIME:SECONDS >= arrival_deadline
            OR VANG(SHIP:FACING:FOREVECTOR, -SHIP:VELOCITY:ORBIT) > 5 {
            SET throttle_cmd TO MAX(0.02, MIN(1, (SHIP:PERIAPSIS - target_pe) / 5000)).
            IF TIME:SECONDS >= next_sample {
                log_insertion_state("Insertion burn").
                SET next_sample TO TIME:SECONDS + 0.5.
            }
            checkpoint_log("").
            WAIT 0.
        }
        LOCAL cutoff_reason IS "target orbit reached".
        IF NOT orbit_ready() {
            IF SHIP:PERIAPSIS <= target_pe {
                SET cutoff_reason TO "periapsis reached the target, but the orbit is outside tolerance".
            } ELSE IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED {
                SET cutoff_reason TO "carrier lost focus or full physics".
            } ELSE IF KUNIVERSE:TIMEWARP:RATE > 1.01 {
                SET cutoff_reason TO "warp exceeded 1x".
            } ELSE IF TIME:SECONDS >= arrival_deadline {
                SET cutoff_reason TO "burn time limit reached".
            } ELSE {
                SET cutoff_reason TO "retrograde error exceeded 5 deg".
            }
        }
        log_insertion_state("Insertion cutoff: " + cutoff_reason).
        SET throttle_cmd TO 0.
        WAIT 0.
        carrier_engine:SHUTDOWN().
        UNLOCK THROTTLE.
        log_line("Insertion ended: " + cutoff_reason + ". Pe " + ROUND(SHIP:PERIAPSIS / 1000, 2)
            + " km, period error " + ROUND(SHIP:OBT:PERIOD - target_period, 2) + " s.").
        transmit_log().
    }

    LOCAL release_lead IS 30.
    LOCAL earliest_release IS 0.
    LOCAL release_deadline IS 0.
    UNTIL remaining = 0 {
        IF NOT orbit_ready() {
            log_line("Carrier is outside the phasing orbit tolerance. Releases stopped.").
            RETURN.
        }
        LOCAL satellite_number IS constellation_size - remaining + 1.
        LOCAL relay_name IS satellites[0]:TAG.
        LOCAL relay_uid IS satellites[0]:UID.
        LOCAL release_label IS relay_name + " (" + satellite_number + " of " + constellation_size + ")".
        IF earliest_release > 0 {
            log_line("After confirming the previous probe's burn, press Enter to arm "
                + release_label + " and auto-warp.").
        } ELSE {
            log_line("Press Enter to arm " + release_label + " and auto-warp.").
        }
        transmit_log().
        wait_for_enter("Waiting for release arming").
        IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT orbit_ready() {
            log_line("Cannot arm auto-warp: active="
                + (SHIP = KUNIVERSE:ACTIVEVESSEL) + ", period error "
                + ROUND(SHIP:OBT:PERIOD - target_period, 2) + " s (limit "
                + ROUND(period_tolerance, 2) + " s). Select the carrier in its phasing orbit and rerun.").
            RETURN.
        }
        LOCAL seconds_until_release IS time_to_release(earliest_release, release_lead).
        IF (release_deadline > 0 AND TIME:SECONDS + seconds_until_release >= release_deadline) {
            log_line("Scheduled release pass already missed. No warp started.").
            RETURN.
        }
        warp_to_coast_end("release", seconds_until_release).
        SET next_display TO 0.
        IF earliest_release = 0 {
            UNTIL ETA:APOAPSIS > release_lead {
                coast_display(release_label + " release", ETA:APOAPSIS + SHIP:OBT:PERIOD - release_lead).
                checkpoint_log("Waiting for current release window to pass").
                WAIT 0.
            }
        }
        UNTIL (TIME:SECONDS >= earliest_release AND ETA:APOAPSIS <= release_lead)
            OR (release_deadline > 0 AND TIME:SECONDS >= release_deadline) {
            coast_display(release_label + " release", time_to_release(earliest_release, release_lead)).
            checkpoint_log("Coasting to release").
            WAIT 0.
        }
        CLEARSCREEN.
        FOR fairing IN SHIP:MODULESNAMED("ModuleProceduralFairing") {
            IF fairing:HASEVENT("deploy") OR fairing:HASEVENT("deploy fairing") {
                log_line("No relay released. A deployable fairing remains. Jettison it and restart the carrier.").
                RETURN.
            }
        }
        IF (release_deadline > 0 AND TIME:SECONDS >= release_deadline)
            OR ETA:APOAPSIS < release_lead - 5 OR NOT orbit_ready()
            OR SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED
            OR KUNIVERSE:TIMEWARP:RATE > 1.01 OR NOT KUNIVERSE:TIMEWARP:ISSETTLED OR SHIP:THRUST > 0 {
            IF ETA:APOAPSIS < release_lead - 5 OR (release_deadline > 0 AND TIME:SECONDS >= release_deadline) {
                log_line("Release window missed. ETA to apoapsis: " + ROUND(ETA:APOAPSIS, 1) + " s.").
            }
            IF NOT orbit_ready() {
                log_line("Carrier outside phasing orbit tolerance. Period error "
                    + ROUND(SHIP:OBT:PERIOD - target_period, 2) + " s, limit " + ROUND(period_tolerance, 2) + " s.").
            }
            IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED {
                log_line("Select the carrier and return to full physics.").
            }
            IF KUNIVERSE:TIMEWARP:RATE > 1.01 OR NOT KUNIVERSE:TIMEWARP:ISSETTLED {
                log_line("Warp had not settled at 1x. Actual rate: " + KUNIVERSE:TIMEWARP:RATE + "x.").
            }
            IF SHIP:THRUST > 0 { log_line("Release blocked by thrust: " + ROUND(SHIP:THRUST, 2) + " kN."). }
            log_line("No satellite released. Restart the carrier script with the original count to replan.").
            RETURN.
        }

        SET satellites TO SHIP:PARTSNAMED("probeCoreCube").
        IF satellites:LENGTH <> remaining OR satellites[0]:UID <> relay_uid {
            log_line("Mounted satellite count or release order changed. Releases stopped.").
            RETURN.
        }
        LOCAL separator IS satellites[0]:DECOUPLER.
        IF NOT separator:ISTYPE("Separator") {
            log_line("No separator found for the next QBE. Releases stopped.").
            RETURN.
        }
        IF NOT separator:HASMODULE("ModuleAnchoredDecoupler") {
            log_line("Expected the Jeblink radial decoupler. Releases stopped.").
            RETURN.
        }
        LOCAL release_module IS separator:GETMODULE("ModuleAnchoredDecoupler").
        LOCAL use_event IS release_module:HASEVENT("Decouple").
        IF NOT use_event AND NOT release_module:HASACTION("Decouple") {
            log_line("Decouple unavailable. Events: " + release_module:ALLEVENTNAMES
                + ", actions: " + release_module:ALLACTIONNAMES).
            RETURN.
        }
        LOCAL probe_batteries IS LIST().
        FOR resource IN satellites[0]:RESOURCES {
            IF resource:NAME = "ElectricCharge" { probe_batteries:ADD(resource). }
        }
        IF probe_batteries:LENGTH <> 1 {
            log_line("Release blocked: expected one QBE battery, found " + probe_batteries:LENGTH + ".").
            RETURN.
        }
        LOCAL probe_battery IS probe_batteries[0].
        LOCAL battery_was_enabled IS probe_battery:ENABLED.
        // Enable the reserve while the carrier can still power the probe processor.
        IF NOT battery_was_enabled AND probe_battery:TOGGLEABLE {
            SET probe_battery:ENABLED TO TRUE.
        }
        log_line("Probe battery at release: " + ROUND(probe_battery:AMOUNT, 2) + "/"
            + probe_battery:CAPACITY + " EC, flow=" + probe_battery:ENABLED + ".").
        IF NOT probe_battery:ENABLED OR probe_battery:AMOUNT <= 0 {
            IF NOT battery_was_enabled AND probe_battery:ENABLED {
                SET probe_battery:ENABLED TO FALSE.
            }
            log_line("Release blocked: probe battery needs charge and enabled flow.").
            RETURN.
        }
        log_line("Releasing satellite at ETA Ap " + ROUND(ETA:APOAPSIS, 2)
            + " s, carrier period error " + ROUND(SHIP:OBT:PERIOD - target_period, 2) + " s.").
        log_line("Releasing relay " + relay_name + ", QBE UID " + relay_uid + ".").
        IF use_event {
            release_module:DOEVENT("Decouple").
        } ELSE {
            release_module:DOACTION("Decouple", TRUE).
        }
        LOCAL release_time IS TIME:SECONDS.
        LOCAL verify_deadline IS release_time + 2.
        WAIT UNTIL SHIP:PARTSNAMED("probeCoreCube"):LENGTH <> remaining
            OR TIME:SECONDS >= verify_deadline.
        IF SHIP:PARTSNAMED("probeCoreCube"):LENGTH = remaining AND NOT battery_was_enabled {
            SET probe_battery:ENABLED TO FALSE.
        }
        SET remaining TO remaining - 1.
        IF SHIP:PARTSNAMED("probeCoreCube"):LENGTH <> remaining {
            log_line("Expected exactly one QBE to detach. Releases stopped.").
            RETURN.
        }
        SET satellites TO SHIP:PARTSNAMED("probeCoreCube").
        SET SHIP:NAME TO carrier_name.
        SET SHIP:TYPE TO "Probe".
        log_line(release_label + " released. Stay on the carrier at 1x while the probe circularizes.").
        transmit_log().
        SET earliest_release TO release_time + (coast_laps - 0.5) * target_period.
        SET release_deadline TO earliest_release + target_period.
    }
}

FUNCTION run_carrier {
    open_log("jeblink-carrier").
    IF SHIP:STATUS = "PRELAUNCH" OR SHIP:STATUS = "LANDED" {
        COPYPATH("0:/lib/launch.ks", "1:/lib/launch.ks").
        RUNONCEPATH(PATH("1:/lib/launch.ks")).
        IF NOT launch_carrier_from_pad() {
            transmit_log().
            RETURN.
        }
    }
    deploy_constellation().
    transmit_log().
}

COPYPATH("0:/lib/telemetry.ks", "1:/lib/telemetry.ks").
RUNONCEPATH(PATH("1:/lib/telemetry.ks")).
run_carrier().
