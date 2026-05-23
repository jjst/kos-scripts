// ============================================================
//  launch.ks — Gravity-turn ascent to circular orbit
//  Target: 100 km circular orbit, 90° azimuth (equatorial)
// ============================================================

// --- CONFIG (edit these) ------------------------------------
SET target_apoapsis  TO 100000.
SET target_periapsis TO 100000.
SET turn_start_alt   TO 100.
SET turn_end_alt     TO 50000.
SET launch_azimuth   TO 90.
SET max_twr          TO 2.5.
SET stage_fuel_min   TO 0.1.
SET circularize_ecc_tol        TO 0.002.
SET apoapsis_wrap_tolerance    TO 1.
SET circularize_window_eta     TO 15.
SET circularize_throttle_scale TO 15000.
// ------------------------------------------------------------

CLEARSCREEN.
PRINT "Boot script loaded. Press ENTER to begin launch sequence.".
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
TERMINAL:INPUT:GETCHAR().

SAS OFF.
RCS OFF.
GEAR OFF.
LOCK THROTTLE TO 0.

// Steering helper: pitch = gravity turn interpolation
FUNCTION ascent_pitch {
    LOCAL frac IS (SHIP:ALTITUDE - turn_start_alt) /
                  (turn_end_alt  - turn_start_alt).
    SET frac TO MAX(0, MIN(1, frac)).
    RETURN 90 - (90 * frac).
}

// Phase 1 — Countdown
LOCK STEERING TO HEADING(launch_azimuth, 90).
PRINT "Launch sequence initiated.".
FROM {LOCAL i IS 5.} UNTIL i = 0 STEP {SET i TO i - 1.} DO {
    PRINT "T-" + i + "...".
    WAIT 1.
}
PRINT "Ignition!".
LOCK THROTTLE TO 1.0.
STAGE.

// Phase 2 — Hold vertical until turn_start_alt
PRINT "Launch — holding vertical.".
WAIT UNTIL SHIP:ALTITUDE > turn_start_alt.

// Phase 3 — Gravity turn loop
PRINT "Beginning gravity turn.".
SET stage_armed TO TRUE.
UNTIL SHIP:APOAPSIS >= target_apoapsis {

    IF stage_armed AND STAGE:LIQUIDFUEL < stage_fuel_min {
        PRINT "Staging!".
        STAGE.
        SET stage_armed TO FALSE.
        WAIT 1.
    }

    IF STAGE:LIQUIDFUEL >= stage_fuel_min {
        SET stage_armed TO TRUE.
    }

    LOCK STEERING TO HEADING(launch_azimuth, ascent_pitch()).

    // TWR-limited throttle, halved when closing in on target Ap
    LOCAL max_thrust        IS SHIP:AVAILABLETHRUST.
    LOCAL weight            IS SHIP:MASS * SHIP:BODY:MU /
                              (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    LOCAL effective_max_twr IS max_twr.
    IF SHIP:APOAPSIS > (target_apoapsis * 0.9) {
        SET effective_max_twr TO max_twr * 0.5.
    }
    LOCAL twr_throttle IS (effective_max_twr * weight) / max_thrust.

    LOCK THROTTLE TO MIN(1.0, twr_throttle).

    WAIT 0.
}

// Phase 4 — Cut engines, coast to apoapsis
LOCK THROTTLE TO 0.
PRINT "Target Ap reached. Coasting to apoapsis.".
LOCK STEERING TO PROGRADE.

UNTIL ETA:APOAPSIS < 45 {
    SET WARP TO 3.
    WAIT 1.
}
SET WARP TO 0.
WAIT UNTIL ETA:APOAPSIS < 15.

// Phase 5 — Circularisation burn at apoapsis
PRINT "Circularisation burn.".
LOCK STEERING TO PROGRADE.

IF SHIP:AVAILABLETHRUST <= 0 {
    PRINT "Circularisation ended early: no thrust available.".
} ELSE {
    UNLOCK THROTTLE.
    SET last_apoapsis_eta TO ETA:APOAPSIS.
    UNTIL SHIP:PERIAPSIS >= target_periapsis OR SHIP:OBT:ECCENTRICITY < circularize_ecc_tol {
        IF SHIP:AVAILABLETHRUST <= 0 {
            PRINT "Circularisation ended early: no thrust available.".
            BREAK.
        }

        LOCAL eta_now IS ETA:APOAPSIS.
        IF eta_now > (last_apoapsis_eta + apoapsis_wrap_tolerance) {
            PRINT "Missed apoapsis window. Coasting to next pass.".
            SET THROTTLE TO 0.
            WAIT UNTIL ETA:APOAPSIS < circularize_window_eta.
            SET last_apoapsis_eta TO ETA:APOAPSIS.
            CONTINUE.
        }
        SET last_apoapsis_eta TO eta_now.

        LOCAL periapsis_error IS MAX(0, target_periapsis - SHIP:PERIAPSIS).
        LOCAL throttle_frac IS MIN(1.0, periapsis_error / circularize_throttle_scale).
        SET THROTTLE TO throttle_frac.
        WAIT 0.
    }
}

LOCK THROTTLE TO 0.

// Done
UNLOCK STEERING.
SAS ON.
PRINT "Orbit achieved!".
PRINT "  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km".
PRINT "  Pe: " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km".
