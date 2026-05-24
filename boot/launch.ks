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
// PID gains for sensor-based TWR control — tune for your rocket
SET twr_kp TO 0.05.
SET twr_ki TO 0.006.
SET twr_kd TO 0.001.
// ------------------------------------------------------------

// ---- FUNCTIONS ---------------------------------------------

FUNCTION ascent_pitch {
    LOCAL frac IS (SHIP:ALTITUDE - turn_start_alt) /
                  (turn_end_alt  - turn_start_alt).
    SET frac TO MAX(0, MIN(1, frac)).
    RETURN 90 - (90 * frac).
}

FUNCTION local_g {
    RETURN SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
}

FUNCTION calc_twr_throttle {
    // Direct physics calculation: throttle needed to achieve target TWR.
    PARAMETER target_twr.
    LOCAL max_thrust IS SHIP:AVAILABLETHRUST.
    IF max_thrust <= 0 { RETURN 0. }
    RETURN MIN(1.0, (target_twr * SHIP:MASS * local_g()) / max_thrust).
}

FUNCTION measure_gforce {
    // Net thrust acceleration in g's (requires accelerometer + gravioli detector).
    RETURN (SHIP:SENSORS:ACC - SHIP:SENSORS:GRAV):MAG / local_g().
}

FUNCTION ap_error_factor {
    // Returns [0,1]: smooth throttle ramp-down over the final 10% of apoapsis climb.
    // 1.0 = far from target (full authority), 0.0 = target reached (cut thrust).
    RETURN MAX(0, MIN(1, (target_apoapsis - SHIP:APOAPSIS) / (target_apoapsis * 0.1))).
}

FUNCTION sensors_available {
    // Sensor-based TWR control requires both the gravioli detector and accelerometer.
    // Absent sensors report zero vectors, so require plausible non-zero readings.
    LOCAL gravity_mag IS SHIP:SENSORS:GRAV:MAG.
    LOCAL accel_mag   IS SHIP:SENSORS:ACC:MAG.
    RETURN gravity_mag > (local_g() * 0.5) AND accel_mag > 0.
}

// ------------------------------------------------------------

// #include "0:/lib/logger"
RUNONCEPATH("0:/lib/logger").

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

// Phase 0 — Sensor validation
PRINT "--- Phase 0: Sensor check ---".
LOCAL use_pid IS sensors_available().
SET twr_pid TO PIDLOOP(twr_kp, twr_ki, twr_kd).
SET twr_pid:MAXOUTPUT TO 0.5.
SET twr_pid:MINOUTPUT TO -0.5.
IF use_pid {
    PRINT "  [OK] Sensors detected — PID throttle control active.".
    PRINT "       Kp=" + twr_kp + "  Ki=" + twr_ki + "  Kd=" + twr_kd.
} ELSE {
    PRINT "  [WARN] No gravioli/accelerometer detected.".
    PRINT "         Using calculated TWR throttle (fallback).".
}
PRINT " ".
PRINT "Press ENTER to begin launch sequence.".
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
TERMINAL:INPUT:GETCHAR().

logger_init("launch").

SAS OFF.
RCS OFF.
GEAR OFF.
LOCK THROTTLE TO 0.

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
logger_log("countdown", "ignition", 1.0, "").

// Phase 2 — Hold vertical until turn_start_alt
PRINT "--- Phase 2: Vertical ascent to " + ROUND(turn_start_alt) + " m ---".
LOCAL next_print IS TIME:SECONDS.
UNTIL SHIP:ALTITUDE > turn_start_alt {
    IF TIME:SECONDS >= next_print {
        PRINT "  Alt: " + ROUND(SHIP:ALTITUDE) + " m  |  vel: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s".
        SET next_print TO TIME:SECONDS + 1.
        logger_log("vertical_ascent", "telemetry", 1.0, "").
    }
    WAIT 0.
}

// Phase 3 — Gravity turn loop
PRINT "--- Phase 3: Gravity turn ---".
SET stage_armed TO TRUE.
SET next_print TO TIME:SECONDS.
LOCAL thrott IS 1.0.
LOCK THROTTLE TO thrott.

UNTIL SHIP:APOAPSIS >= target_apoapsis {

    IF stage_armed AND STAGE:LIQUIDFUEL < stage_fuel_min {
        PRINT "  Staging!".
        STAGE.
        logger_log("gravity_turn", "staging", thrott, "").
        SET stage_armed TO FALSE.
        WAIT 1.
        PRINT "  New stage  |  fuel: " + ROUND(STAGE:LIQUIDFUEL, 1) + " u".
    }

    IF STAGE:LIQUIDFUEL >= stage_fuel_min {
        SET stage_armed TO TRUE.
    }

    LOCAL pitch IS ascent_pitch().
    LOCK STEERING TO HEADING(launch_azimuth, pitch).

    LOCAL ap_fac IS ap_error_factor().
    IF use_pid {
        // Reduce setpoint as Ap approaches target so PID naturally backs off thrust.
        SET twr_pid:SETPOINT TO max_twr * ap_fac.
        SET thrott TO MIN(1.0, MAX(0.0, thrott + twr_pid:UPDATE(TIME:SECONDS, measure_gforce()))).
    } ELSE {
        SET thrott TO MIN(calc_twr_throttle(max_twr), ap_fac).
    }

    IF TIME:SECONDS >= next_print {
        LOCAL mode IS "pid".
        IF NOT use_pid { SET mode TO "calc". }
        PRINT "  Alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  pitch: " + ROUND(pitch) + " deg  |  thr: " + ROUND(thrott, 2) + " [" + mode + "]".
        SET next_print TO TIME:SECONDS + 2.
        logger_log("gravity_turn", "telemetry", thrott, mode).
    }

    WAIT 0.
}

// Phase 4 — Cut engines, coast to apoapsis
LOCK THROTTLE TO 0.
PRINT "--- Phase 4: Coasting to apoapsis ---".
PRINT "  Cutoff  |  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  Pe: " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km  |  ecc: " + ROUND(SHIP:OBT:ECCENTRICITY, 3).
logger_log("coast", "cutoff", 0, "").
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
        logger_log("coast", "telemetry", 0, "").
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
    logger_log("circ", "abort_no_thrust", 0, "").
} ELSE {
    LOCAL prev_ecc IS SHIP:OBT:ECCENTRICITY.
    LOCAL cur_ecc  IS prev_ecc.
    LOCAL circ_thrott IS 1.0.
    LOCK THROTTLE TO circ_thrott.
    SET next_print TO TIME:SECONDS.
    UNTIL SHIP:AVAILABLETHRUST <= 0 OR cur_ecc > prev_ecc {
        SET prev_ecc TO cur_ecc.
        LOCAL ecc_thr IS MIN(1.0, cur_ecc / circularize_ecc_throttle_scale).
        SET circ_thrott TO MIN(calc_twr_throttle(max_twr), ecc_thr).
        IF TIME:SECONDS >= next_print {
            PRINT "  ecc: " + ROUND(cur_ecc, 4) + "  |  thr: " + ROUND(circ_thrott, 2).
            SET next_print TO TIME:SECONDS + 2.
            logger_log("circ", "telemetry", circ_thrott, "").
        }
        WAIT 0.
        SET cur_ecc TO SHIP:OBT:ECCENTRICITY.
    }
    IF SHIP:AVAILABLETHRUST <= 0 {
        PRINT "  Ended early: no thrust available.".
        logger_log("circ", "abort_no_thrust", circ_thrott, "").
    }
}

LOCK THROTTLE TO 0.
UNLOCK STEERING.
SAS ON.
PRINT "--- Orbit achieved! ---".
PRINT "  Ap:  " + ROUND(SHIP:APOAPSIS/1000, 1) + " km".
PRINT "  Pe:  " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km".
PRINT "  ecc: " + ROUND(SHIP:OBT:ECCENTRICITY, 4).
logger_log("orbit", "achieved", 0, "").
logger_finalize().
