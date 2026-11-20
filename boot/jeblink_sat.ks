// Assign this boot file to each Jeblink satellite processor.
// Release one satellite per apoapsis: 313 x 500 km for eight satellites,
// or 376 x 500 km for twelve.

FUNCTION deploy_satellite {
    LOCAL apoapsis_margin IS 1000.
    LOCAL periapsis_tolerance IS 150.
    LOCAL angular_tolerance IS 2.

    PRINT "Jeblink: waiting for separation.".
    // The carrier and each satellite have their own command core and engine.
    // Check both so the last satellite also waits until it is off the carrier.
    UNTIL SHIP:UNPACKED AND SHIP:MODULESNAMED("ModuleCommand"):LENGTH = 1
        AND SHIP:ENGINES:LENGTH = 1 {
        WAIT 1.
    }
    WAIT 3.
    WAIT UNTIL SHIP:UNPACKED.

    FOR panel IN SHIP:MODULESNAMED("ModuleDeployableSolarPanel") {
        IF panel:HASEVENT("Extend Panels") {
            panel:DOEVENT("Extend Panels").
        }
    }

    FUNCTION pointing_error {
        RETURN VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:ORBIT).
    }

    LOCAL release_apoapsis IS SHIP:APOAPSIS.
    LOCAL target_periapsis IS release_apoapsis - periapsis_tolerance.
    LOCAL apoapsis_limit IS release_apoapsis + apoapsis_margin.
    LOCAL sat_engine IS SHIP:ENGINES[0].
    LOCAL throttle_cmd IS 0.
    LOCK THROTTLE TO throttle_cmd.
    SAS OFF.
    LOCK STEERING TO PROGRADE.

    LOCAL alignment_deadline IS TIME:SECONDS + 20.
    WAIT UNTIL pointing_error() <= angular_tolerance
        OR TIME:SECONDS >= alignment_deadline OR NOT SHIP:UNPACKED.
    IF SHIP:UNPACKED AND pointing_error() <= angular_tolerance {
        sat_engine:ACTIVATE().
        LOCAL burn_deadline IS TIME:SECONDS + 30.
        UNTIL SHIP:PERIAPSIS >= target_periapsis
            OR SHIP:APOAPSIS > apoapsis_limit
            OR TIME:SECONDS >= burn_deadline OR NOT SHIP:UNPACKED
            OR pointing_error() > 5 OR sat_engine:FLAMEOUT {
            SET throttle_cmd TO MAX(0.08, MIN(1, (target_periapsis - SHIP:PERIAPSIS) / 3000)).
            WAIT 0.
        }
        SET throttle_cmd TO 0.
        sat_engine:SHUTDOWN().
    }
    WAIT 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.

    IF SHIP:PERIAPSIS >= target_periapsis
        AND SHIP:APOAPSIS <= apoapsis_limit {
        PRINT "Jeblink: circularization complete.".
    } ELSE {
        PRINT "Jeblink: circularization incomplete. Check attitude and orbit.".
    }
    PRINT "Ap " + ROUND(SHIP:APOAPSIS / 1000, 2)
        + " km, Pe " + ROUND(SHIP:PERIAPSIS / 1000, 2) + " km.".
}

deploy_satellite().
