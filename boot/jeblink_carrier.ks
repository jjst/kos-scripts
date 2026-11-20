// Assign /boot/jeblink_carrier.ks to the carrier processor.
// To restart manually, RUNPATH("0:/boot/jeblink_carrier.ks", original_count).
DECLARE PARAMETER constellation_size IS 0.

LOCAL log_name IS "jeblink-carrier-" + ROUND(TIME:SECONDS * 1000) + ".log".
LOCAL log_path IS "1:/" + log_name.

FUNCTION log_line {
    PARAMETER msg.
    LOCAL entry IS ROUND(TIME:SECONDS, 2) + " " + msg.
    PRINT entry.
    LOG entry TO log_path.
}

FUNCTION transmit_log {
    IF HOMECONNECTION:ISCONNECTED {
        COPYPATH(log_path, "0:/" + log_name).
    }
}

FUNCTION parking_orbit_ready {
    RETURN SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:UNPACKED
        AND SHIP:BODY:NAME = "Kerbin" AND SHIP:STATUS = "ORBITING"
        AND SHIP:PERIAPSIS >= 75000.
}

FUNCTION deploy_constellation {
    log_line("Jeblink carrier booted. Waiting for an active Kerbin parking orbit with Pe at least 75 km.").
    WAIT UNTIL parking_orbit_ready().
    LOCAL armed IS FALSE.
    UNTIL armed {
        log_line("Press Enter to begin phasing once the parking orbit is final and any ascent script has finished.").
        TERMINAL:INPUT:CLEAR().
        WAIT UNTIL TERMINAL:INPUT:GETCHAR() = TERMINAL:INPUT:RETURN.
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
                + ", SAS " + SAS + "/" + SASMODE).
        }
        LOCK THROTTLE TO throttle_cmd.
        SET NAVMODE TO "ORBIT".
        SAS OFF.
        WAIT 0.
        SAS ON.
        WAIT 0.
        SET SASMODE TO "RETROGRADE".
        WAIT 0.
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
        WAIT UNTIL ETA:APOAPSIS > burn_lead OR SHIP <> KUNIVERSE:ACTIVEVESSEL.
        WAIT UNTIL ETA:APOAPSIS <= burn_lead OR SHIP <> KUNIVERSE:ACTIVEVESSEL.
        log_insertion_state("Insertion window opened").
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
            WAIT 0.
        }
        SET throttle_cmd TO 0.
        WAIT 0.
        log_insertion_state("Insertion cutoff").
        carrier_engine:SHUTDOWN().
        UNLOCK THROTTLE.
        log_line("Insertion ended at Pe " + ROUND(SHIP:PERIAPSIS / 1000, 2)
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
        log_line("Press Enter on the carrier to arm the next release. Switch to the probe after release.").
        TERMINAL:INPUT:CLEAR().
        WAIT UNTIL TERMINAL:INPUT:GETCHAR() = TERMINAL:INPUT:RETURN.
        IF earliest_release = 0 {
            WAIT UNTIL ETA:APOAPSIS > release_lead.
        }
        WAIT UNTIL (TIME:SECONDS >= earliest_release AND ETA:APOAPSIS <= release_lead)
            OR (release_deadline > 0 AND TIME:SECONDS >= release_deadline).
        IF (release_deadline > 0 AND TIME:SECONDS >= release_deadline)
            OR ETA:APOAPSIS < release_lead - 5 OR NOT orbit_ready()
            OR SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED
            OR KUNIVERSE:TIMEWARP:RATE > 1.01 OR SHIP:THRUST > 0 {
            log_line("Release window missed or carrier not ready. Releases stopped.").
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
        log_line("Satellite released. " + remaining + " still mounted.").
        transmit_log().
        SET earliest_release TO release_time + (coast_laps - 0.5) * target_period.
        SET release_deadline TO earliest_release + target_period.
    }
}

deploy_constellation().
transmit_log().
