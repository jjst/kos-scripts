// Assign /boot/jeblink_carrier.ks to the carrier processor.
// To restart manually, RUNPATH("0:/boot/jeblink_carrier.ks", original_count).
DECLARE PARAMETER constellation_size IS 0.

LOCAL log_name IS "jeblink-carrier-" + ROUND(TIME:SECONDS * 1000) + ".log".
LOCAL log_path IS "1:/" + log_name.
LOCAL checkpoint_interval IS 20.
LOCAL next_checkpoint IS TIME:SECONDS + checkpoint_interval.
LOCAL next_display IS 0.
LOCAL warp_buffer IS 20.

FUNCTION log_line {
    PARAMETER msg, show_in_terminal IS TRUE.
    LOCAL entry IS ROUND(TIME:SECONDS, 2) + " " + msg.
    IF show_in_terminal { PRINT entry. }
    LOG entry TO log_path.
}

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

FUNCTION transmit_log {
    IF HOMECONNECTION:ISCONNECTED {
        COPYPATH(log_path, "0:/" + log_name).
    }
}

FUNCTION checkpoint_log {
    PARAMETER phase.
    IF TIME:SECONDS < next_checkpoint { RETURN. }
    IF phase <> "" {
        LOCAL detail IS phase + ": " + SHIP:STATUS + ", active "
            + (SHIP = KUNIVERSE:ACTIVEVESSEL) + ", unpacked " + SHIP:UNPACKED
            + ", warp " + KUNIVERSE:TIMEWARP:RATE + "x".
        IF SHIP:STATUS = "ORBITING" {
            SET detail TO detail + ", Ap " + ROUND(SHIP:APOAPSIS / 1000, 2)
                + " km, Pe " + ROUND(SHIP:PERIAPSIS / 1000, 2)
                + " km, ETA Ap " + ROUND(ETA:APOAPSIS, 1) + " s".
        }
        log_line(detail + ".", FALSE).
    }
    transmit_log().
    SET next_checkpoint TO TIME:SECONDS + checkpoint_interval.
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
    IF constellation_size = 0 { SET constellation_size TO remaining. }
    IF remaining = 0 OR constellation_size < remaining OR constellation_size < 2
        OR constellation_size <> FLOOR(constellation_size) {
        log_line("No valid Jeblink constellation count.").
        RETURN.
    }

    LOCAL mu IS SHIP:BODY:MU.
    LOCAL radius IS SHIP:BODY:RADIUS.
    LOCAL target_apoapsis IS SHIP:APOAPSIS.
    LOCAL apo_radius IS radius + target_apoapsis.
    LOCAL circular_period IS 2 * CONSTANT:PI * SQRT(apo_radius^3 / mu).
    LOCAL coast_laps IS 1.
    LOCAL target_period IS 0.
    LOCAL target_axis IS 0.
    LOCAL target_pe IS 0.
    UNTIL target_pe >= 75000 OR coast_laps > 12 {
        SET target_period TO circular_period * (1 - 1 / (constellation_size * coast_laps)).
        SET target_axis TO apo_radius * (target_period / circular_period)^(2 / 3).
        SET target_pe TO 2 * target_axis - apo_radius - radius.
        IF target_pe < 75000 { SET coast_laps TO coast_laps + 1. }
    }
    IF target_pe < 75000 {
        log_line("No phasing orbit above 75 km found within 12 carrier laps per release.").
        RETURN.
    }
    LOCAL period_tolerance IS circular_period / (360 * coast_laps).
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
        LOCAL carrier_engines IS LIST().
        FOR eng IN SHIP:ENGINES {
            IF eng:NAME = "liquidEngine2-2.v2" OR eng:NAME = "liquidEngine2-2_v2" {
                carrier_engines:ADD(eng).
            }
        }
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
        LOCAL delta_v IS SQRT(mu * (2 / apo_radius - 1 / SHIP:OBT:SEMIMAJORAXIS))
            - SQRT(mu * (2 / apo_radius - 1 / target_axis)).
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

    LOCAL release_lead IS 45.
    LOCAL earliest_release IS 0.
    LOCAL release_deadline IS 0.
    UNTIL remaining = 0 {
        IF NOT orbit_ready() {
            log_line("Carrier is outside the phasing orbit tolerance. Releases stopped.").
            RETURN.
        }
        LOCAL satellite_number IS constellation_size - remaining + 1.
        LOCAL release_label IS "Satellite " + satellite_number + " of " + constellation_size.
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
        IF satellites:LENGTH <> remaining {
            log_line("Mounted satellite count changed unexpectedly. Releases stopped.").
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
        log_line("Releasing satellite at ETA Ap " + ROUND(ETA:APOAPSIS, 2)
            + " s, carrier period error " + ROUND(SHIP:OBT:PERIOD - target_period, 2) + " s.").
        IF release_module:HASEVENT("Decouple") {
            release_module:DOEVENT("Decouple").
        } ELSE IF release_module:HASACTION("Decouple") {
            release_module:DOACTION("Decouple", TRUE).
        } ELSE {
            log_line("Decouple unavailable. Events: " + release_module:ALLEVENTNAMES
                + ", actions: " + release_module:ALLACTIONNAMES).
            RETURN.
        }
        LOCAL release_time IS TIME:SECONDS.
        LOCAL verify_deadline IS release_time + 2.
        WAIT UNTIL SHIP:PARTSNAMED("probeCoreCube"):LENGTH <> remaining
            OR TIME:SECONDS >= verify_deadline.
        SET remaining TO remaining - 1.
        IF SHIP:PARTSNAMED("probeCoreCube"):LENGTH <> remaining {
            log_line("Expected exactly one QBE to detach. Releases stopped.").
            RETURN.
        }
        log_line(release_label + " released. Stay on the carrier at 1x while the probe circularizes.").
        transmit_log().
        SET earliest_release TO release_time + (coast_laps - 0.5) * target_period.
        SET release_deadline TO earliest_release + target_period.
    }
}

deploy_constellation().
transmit_log().
