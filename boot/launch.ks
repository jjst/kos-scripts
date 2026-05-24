// ============================================================
//  launch.ks — Gravity-turn ascent to circular orbit
// ============================================================

// --- CONFIG (edit these) ------------------------------------
SET target_apoapsis  TO 100000.
SET turn_start_alt   TO 100.
SET turn_end_alt     TO 50000.
SET launch_azimuth   TO 90.
SET max_twr          TO 2.5.
SET stage_fuel_min   TO 0.1.
SET circularize_ecc_throttle_scale TO 0.05.
// ------------------------------------------------------------

CLEARSCREEN.
TERMINAL:INPUT:CLEAR().

FUNCTION read_line {
    LOCAL buffer IS "".
    LOCAL done IS FALSE.
    UNTIL done {
        LOCAL ch IS TERMINAL:INPUT:GETCHAR().
        IF ch = TERMINAL:INPUT:RETURN {
            SET done TO TRUE.
        } ELSE IF ch = TERMINAL:INPUT:BACKSPACE {
            IF buffer:LENGTH > 0 {
                SET buffer TO buffer:SUBSTRING(0, buffer:LENGTH - 1).
            }
        } ELSE {
            SET buffer TO buffer + ch.
        }
    }
    RETURN buffer.
}

FUNCTION prompt_number_or_default {
    PARAMETER prompt_label, default_value.
    PRINT prompt_label + " (default " + default_value + "):".
    LOCAL raw_value IS read_line():TRIM.
    IF raw_value:LENGTH = 0 {
        RETURN default_value.
    }
    LOCAL number_pattern IS "^[-+]?(([0-9]+[.]?[0-9]*)|([.][0-9]+))([eE][-+]?[0-9]+)?$".
    IF NOT raw_value:MATCHESPATTERN(number_pattern) {
        PRINT "Invalid input '" + raw_value + "' - using default " + default_value + ".".
        RETURN default_value.
    }
    RETURN raw_value:TONUMBER().
}

PRINT "Press Return to keep each default value.".
SET launch_azimuth TO prompt_number_or_default("Launch heading (deg)", launch_azimuth).
LOCAL target_altitude_km IS prompt_number_or_default("Target orbit altitude (km)", target_apoapsis / 1000).
SET target_apoapsis TO target_altitude_km * 1000.

PRINT "=== launch.ks ===".
PRINT "Target orbit : " + ROUND(target_apoapsis/1000, 0) + " km  |  azimuth: " + launch_azimuth + " deg".
PRINT "Max TWR      : " + max_twr + "  |  gravity turn: " + ROUND(turn_start_alt) + " m -> " + ROUND(turn_end_alt/1000, 0) + " km".
PRINT " ".
PRINT "Press ENTER to begin launch sequence.".
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
TERMINAL:INPUT:GETCHAR().

SAS OFF.
RCS OFF.
GEAR OFF.
LOCK THROTTLE TO 0.

FUNCTION ascent_pitch {
    LOCAL frac IS (SHIP:ALTITUDE - turn_start_alt) /
                  (turn_end_alt  - turn_start_alt).
    SET frac TO MAX(0, MIN(1, frac)).
    RETURN 90 - (90 * frac).
}

// Phase 1 — Countdown
LOCK STEERING TO HEADING(launch_azimuth, 90).
PRINT "--- Phase 1: Countdown ---".
FROM {LOCAL i IS 5.} UNTIL i = 0 STEP {SET i TO i - 1.} DO {
    PRINT "T-" + i + "...".
    WAIT 1.
}
PRINT "Ignition!".
LOCK THROTTLE TO 1.0.
STAGE.

// Phase 2 — Hold vertical until turn_start_alt
PRINT "--- Phase 2: Vertical ascent to " + ROUND(turn_start_alt) + " m ---".
LOCAL next_print IS TIME:SECONDS.
UNTIL SHIP:ALTITUDE > turn_start_alt {
    IF TIME:SECONDS >= next_print {
        PRINT "  Alt: " + ROUND(SHIP:ALTITUDE) + " m  |  vel: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s".
        SET next_print TO TIME:SECONDS + 1.
    }
    WAIT 0.
}

// Phase 3 — Gravity turn loop
PRINT "--- Phase 3: Gravity turn ---".
SET stage_armed TO TRUE.
SET next_print TO TIME:SECONDS.
LOCAL throttle_reduced IS FALSE.
UNTIL SHIP:APOAPSIS >= target_apoapsis {

    IF stage_armed AND STAGE:LIQUIDFUEL < stage_fuel_min {
        PRINT "  Staging!".
        STAGE.
        SET stage_armed TO FALSE.
        WAIT 1.
        PRINT "  New stage  |  fuel: " + ROUND(STAGE:LIQUIDFUEL, 1) + " u".
    }

    IF STAGE:LIQUIDFUEL >= stage_fuel_min {
        SET stage_armed TO TRUE.
    }

    LOCAL pitch IS ascent_pitch().
    LOCK STEERING TO HEADING(launch_azimuth, pitch).

    LOCAL max_thrust IS SHIP:AVAILABLETHRUST.
    LOCAL weight IS SHIP:MASS * SHIP:BODY:MU /
                    (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    LOCAL effective_max_twr IS max_twr.
    IF SHIP:APOAPSIS > (target_apoapsis * 0.9) {
        IF NOT throttle_reduced {
            PRINT "  Ap > 90% of target — reducing max TWR to " + (max_twr * 0.5) + ".".
            SET throttle_reduced TO TRUE.
        }
        SET effective_max_twr TO max_twr * 0.5.
    }
    LOCAL twr_throttle IS (effective_max_twr * weight) / max_thrust.
    LOCAL actual_throttle IS MIN(1.0, twr_throttle).
    LOCK THROTTLE TO actual_throttle.

    IF TIME:SECONDS >= next_print {
        PRINT "  Alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  pitch: " + ROUND(pitch) + " deg  |  thr: " + ROUND(actual_throttle, 2).
        SET next_print TO TIME:SECONDS + 2.
    }

    WAIT 0.
}

// Phase 4 — Cut engines, coast to apoapsis
LOCK THROTTLE TO 0.
PRINT "--- Phase 4: Coasting to apoapsis ---".
PRINT "  Cutoff  |  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  Pe: " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km  |  ecc: " + ROUND(SHIP:OBT:ECCENTRICITY, 3).
LOCK STEERING TO PROGRADE.

LOCAL mu_body  IS SHIP:BODY:MU.
LOCAL r_ap     IS SHIP:BODY:RADIUS + SHIP:APOAPSIS.
LOCAL a_cur    IS SHIP:OBT:SEMIMAJORAXIS.
LOCAL v_at_ap  IS SQRT(mu_body * (2 / r_ap - 1 / a_cur)).
LOCAL v_circ   IS SQRT(mu_body / r_ap).
LOCAL circ_dv  IS MAX(0, v_circ - v_at_ap).
LOCAL burn_duration IS 0.
IF SHIP:AVAILABLETHRUST > 0 {
    SET burn_duration TO (circ_dv * SHIP:MASS) / SHIP:AVAILABLETHRUST.
}
PRINT "  Circ dv: " + ROUND(circ_dv, 1) + " m/s  |  est. burn: " + ROUND(burn_duration, 1) + " s  |  igniting at T-" + ROUND(burn_duration / 2, 1) + " s".

LOCAL burn_start_eta IS burn_duration / 2.
SET next_print TO TIME:SECONDS.
UNTIL ETA:APOAPSIS < burn_start_eta + 60 {
    SET WARP TO 3.
    IF TIME:SECONDS >= next_print {
        PRINT "  Coasting...  ETA Ap: " + ROUND(ETA:APOAPSIS) + " s".
        SET next_print TO TIME:SECONDS + 30.
    }
    WAIT 1.
}
SET WARP TO 0.
UNTIL ETA:APOAPSIS < burn_start_eta {
    PRINT "  Igniting in " + ROUND(ETA:APOAPSIS - burn_start_eta, 1) + " s...".
    WAIT 1.
}

// Phase 5 — Circularisation burn at apoapsis
PRINT "--- Phase 5: Circularisation burn ---".
LOCK STEERING TO PROGRADE.

IF SHIP:AVAILABLETHRUST <= 0 {
    PRINT "  Ended early: no thrust available.".
} ELSE {
    UNLOCK THROTTLE.
    LOCAL prev_ecc IS SHIP:OBT:ECCENTRICITY.
    LOCAL cur_ecc  IS prev_ecc.
    SET next_print TO TIME:SECONDS.
    UNTIL SHIP:AVAILABLETHRUST <= 0 OR cur_ecc > prev_ecc {
        SET prev_ecc TO cur_ecc.
        LOCAL max_thrust IS SHIP:AVAILABLETHRUST.
        LOCAL weight IS SHIP:MASS * SHIP:BODY:MU /
                        (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
        LOCAL twr_throttle IS (max_twr * weight) / max_thrust.
        LOCAL ecc_throttle IS MIN(1.0, cur_ecc / circularize_ecc_throttle_scale).
        LOCAL actual_throttle IS MIN(twr_throttle, ecc_throttle).
        LOCK THROTTLE TO actual_throttle.
        IF TIME:SECONDS >= next_print {
            PRINT "  ecc: " + ROUND(cur_ecc, 4) + "  |  thr: " + ROUND(actual_throttle, 2).
            SET next_print TO TIME:SECONDS + 2.
        }
        WAIT 0.
        SET cur_ecc TO SHIP:OBT:ECCENTRICITY.
    }
    IF SHIP:AVAILABLETHRUST <= 0 {
        PRINT "  Ended early: no thrust available.".
    }
}

LOCK THROTTLE TO 0.

UNLOCK STEERING.
SAS ON.
PRINT "--- Orbit achieved! ---".
PRINT "  Ap:  " + ROUND(SHIP:APOAPSIS/1000, 1) + " km".
PRINT "  Pe:  " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km".
PRINT "  ecc: " + ROUND(SHIP:OBT:ECCENTRICITY, 4).
