// Run from the Jeblink carrier in a bound Kerbin parking orbit at 1x.
// On restart, pass the original constellation size to keep the planned spacing.
DECLARE PARAMETER constellation_size IS 0.

FUNCTION deploy_constellation {
    LOCAL satellites IS SHIP:PARTSNAMED("probeCoreCube").
    LOCAL remaining IS satellites:LENGTH.
    IF constellation_size = 0 { SET constellation_size TO remaining. }
    IF remaining = 0 OR constellation_size < remaining OR constellation_size < 2
        OR constellation_size <> FLOOR(constellation_size)
        OR SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED
        OR SHIP:BODY:NAME <> "Kerbin" OR SHIP:STATUS <> "ORBITING"
        OR SHIP:PERIAPSIS < 75000 {
        PRINT "Use the active Jeblink carrier in Kerbin orbit with Pe at least 75 km.".
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
        PRINT "No phasing orbit above 75 km found within 12 carrier laps per release.".
        RETURN.
    }
    LOCAL period_tolerance IS circular_period / (360 * coast_laps).
    PRINT remaining + " mounted, " + constellation_size + " planned, "
        + ROUND(360 / constellation_size, 2) + " deg spacing.".
    PRINT "Carrier target Pe " + ROUND(target_pe / 1000, 2) + " km, Ap "
        + ROUND(target_apoapsis / 1000, 2) + " km, " + coast_laps + " lap(s) per release.".

    FUNCTION orbit_ready {
        RETURN SHIP:PERIAPSIS >= 75000
            AND ABS(SHIP:APOAPSIS - target_apoapsis) <= 1000
            AND ABS(SHIP:OBT:PERIOD - target_period) <= period_tolerance.
    }

    IF NOT orbit_ready() {
        IF SHIP:PERIAPSIS <= target_pe {
            PRINT "Carrier orbit is already below the target periapsis. Raise Pe and rerun.".
            RETURN.
        }
        LOCAL carrier_engines IS LIST().
        FOR eng IN SHIP:ENGINES {
            IF eng:NAME = "liquidEngine2-2.v2" OR eng:NAME = "liquidEngine2-2_v2" {
                carrier_engines:ADD(eng).
            }
        }
        IF carrier_engines:LENGTH <> 1 {
            PRINT "Expected one Jeblink carrier Poodle. No insertion burn.".
            RETURN.
        }
        LOCAL carrier_engine IS carrier_engines[0].
        LOCAL throttle_cmd IS 0.
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
            PRINT "Expected thrust from the carrier Poodle only. No insertion burn.".
            RETURN.
        }
        LOCAL delta_v IS SQRT(mu * (2 / apo_radius - 1 / SHIP:OBT:SEMIMAJORAXIS))
            - SQRT(mu * (2 / apo_radius - 1 / target_axis)).
        LOCAL burn_lead IS MAX(0.5, delta_v * SHIP:MASS / thrust_available / 2).
        PRINT "Insertion burn: " + ROUND(delta_v, 1) + " m/s, ignition "
            + ROUND(burn_lead, 1) + " s before apoapsis.".
        WAIT UNTIL ETA:APOAPSIS > burn_lead OR SHIP <> KUNIVERSE:ACTIVEVESSEL.
        WAIT UNTIL ETA:APOAPSIS <= burn_lead OR SHIP <> KUNIVERSE:ACTIVEVESSEL.
        LOCAL arrival_deadline IS TIME:SECONDS + 2 * burn_lead + 10.
        UNTIL orbit_ready() OR SHIP:PERIAPSIS <= target_pe
            OR SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED
            OR KUNIVERSE:TIMEWARP:RATE > 1.01 OR TIME:SECONDS >= arrival_deadline
            OR VANG(SHIP:FACING:FOREVECTOR, -SHIP:VELOCITY:ORBIT) > 5 {
            SET throttle_cmd TO MAX(0.02, MIN(1, (SHIP:PERIAPSIS - target_pe) / 5000)).
            WAIT 0.
        }
        SET throttle_cmd TO 0.
        WAIT 0.
        carrier_engine:SHUTDOWN().
        UNLOCK THROTTLE.
        PRINT "Insertion ended at Pe " + ROUND(SHIP:PERIAPSIS / 1000, 2)
            + " km, period error " + ROUND(SHIP:OBT:PERIOD - target_period, 2) + " s.".
    }

    LOCAL release_lead IS 45.
    LOCAL earliest_release IS 0.
    LOCAL release_deadline IS 0.
    UNTIL remaining = 0 {
        IF NOT orbit_ready() {
            PRINT "Carrier is outside the phasing orbit tolerance. Releases stopped.".
            RETURN.
        }
        PRINT "Press Enter on the carrier to arm the next release. Switch to the probe after release.".
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
            PRINT "Release window missed or carrier not ready. Releases stopped.".
            RETURN.
        }

        SET satellites TO SHIP:PARTSNAMED("probeCoreCube").
        IF satellites:LENGTH <> remaining {
            PRINT "Mounted satellite count changed unexpectedly. Releases stopped.".
            RETURN.
        }
        LOCAL separator IS satellites[0]:DECOUPLER.
        IF NOT separator:ISTYPE("Separator") {
            PRINT "No separator found for the next QBE. Releases stopped.".
            RETURN.
        }
        IF NOT separator:HASMODULE("ModuleAnchoredDecoupler") {
            PRINT "Expected the Jeblink radial decoupler. Releases stopped.".
            RETURN.
        }
        LOCAL release_module IS separator:GETMODULE("ModuleAnchoredDecoupler").
        IF release_module:HASEVENT("Decouple") {
            release_module:DOEVENT("Decouple").
        } ELSE IF release_module:HASACTION("Decouple") {
            release_module:DOACTION("Decouple", TRUE).
        } ELSE {
            PRINT "Decouple unavailable. Events: " + release_module:ALLEVENTNAMES
                + ", actions: " + release_module:ALLACTIONNAMES.
            RETURN.
        }
        LOCAL release_time IS TIME:SECONDS.
        LOCAL verify_deadline IS release_time + 2.
        WAIT UNTIL SHIP:PARTSNAMED("probeCoreCube"):LENGTH <> remaining
            OR TIME:SECONDS >= verify_deadline.
        SET remaining TO remaining - 1.
        IF SHIP:PARTSNAMED("probeCoreCube"):LENGTH <> remaining {
            PRINT "Expected exactly one QBE to detach. Releases stopped.".
            RETURN.
        }
        PRINT "Satellite released. " + remaining + " still mounted.".
        SET earliest_release TO release_time + (coast_laps - 0.5) * target_period.
        SET release_deadline TO earliest_release + target_period.
    }
}

deploy_constellation().
