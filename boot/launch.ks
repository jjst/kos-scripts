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

UNTIL SHIP:OBT:ECCENTRICITY < 0.002 {
    LOCAL throttle_frac IS MIN(1.0, SHIP:OBT:ECCENTRICITY * 100).
    LOCK THROTTLE TO MAX(0.05, throttle_frac).
    WAIT 0.
}

LOCK THROTTLE TO 0.

// Done
UNLOCK STEERING.
SAS ON.
PRINT "Orbit achieved!".
PRINT "  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km".
PRINT "  Pe: " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km".
