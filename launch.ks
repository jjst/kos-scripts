// ============================================================
//  launch.ks — Gravity-turn ascent to circular orbit
// ============================================================

// --- CONFIG (edit these) ------------------------------------
SET target_apoapsis  TO 100000.
SET turn_start_alt   TO 100.
SET turn_end_alt     TO 50000.
SET launch_azimuth   TO 90.
SET max_twr          TO 2.5.
SET circularize_ecc_throttle_scale TO 0.05.
SET ascent_min_throttle TO 0.2.
SET apoapsis_cutoff_margin TO 100.
SET telemetry_interval TO 5.
SET land_target_path TO "1:/land-target.json".
SET log_path TO "launch.log".
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

FUNCTION mark_telemetry_logged {
    SET next_print TO TIME:SECONDS + telemetry_interval.
}

FUNCTION ascent_throttle {
    PARAMETER requested_throttle.
    IF requested_throttle <= 0 {
        RETURN 0.
    }
    RETURN MAX(ascent_min_throttle, requested_throttle).
}

FUNCTION log_line {
    PARAMETER msg.
    PRINT msg.
    LOG msg TO log_path.
}

FUNCTION check_line {
    PARAMETER ok, label, detail.
    LOCAL mark IS "[x]".
    IF ok {
        SET mark TO "[✓]".
    } ELSE {
        SET preflight_failed TO TRUE.
    }
    log_line(mark + " " + label + " - " + detail).
}

FUNCTION info_line {
    PARAMETER label, detail.
    log_line("[i] " + label + " - " + detail).
}

FUNCTION warn_line {
    PARAMETER label, detail.
    log_line("[!] " + label + " - " + detail).
}

FUNCTION abort_launch {
    PARAMETER msg.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    log_line("ABORT: " + msg).
    transmit_log().
    WAIT 5.
    SHUTDOWN.
}

FUNCTION transmit_log {
    LOCAL recovered_on_kerbin IS FALSE.
    IF SHIP:BODY:NAME = "Kerbin" {
        IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            SET recovered_on_kerbin TO TRUE.
        }
    }

    IF recovered_on_kerbin OR HOMECONNECTION:ISCONNECTED {
        COPYPATH(log_path, "0:").
        RETURN TRUE.
    }
    RETURN FALSE.
}

FUNCTION current_stage_burn_time_remaining {
    PARAMETER throttle_cmd.
    IF throttle_cmd <= 0 {
        RETURN 0.
    }
    LOCAL stage_duration IS STAGE:DELTAV:DURATION.
    IF stage_duration <= 0 {
        RETURN 0.
    }
    RETURN stage_duration / throttle_cmd.
}

FUNCTION current_stage_dv {
    RETURN STAGE:DELTAV:CURRENT.
}

FUNCTION active_engine_flameout {
    LOCAL engine_list IS LIST().
    LIST ENGINES IN engine_list.
    FOR eng IN engine_list {
        IF eng:IGNITION AND eng:FLAMEOUT {
            RETURN TRUE.
        }
    }
    RETURN FALSE.
}

FUNCTION sensors_available {
    // Sensor-based TWR control requires both the gravioli detector and accelerometer.
    // LIST SENSORS avoids raising if the craft lacks one of the sensor modules.
    LOCAL sense_list IS LIST().
    LOCAL has_acc IS FALSE.
    LOCAL has_grav IS FALSE.
    LIST SENSORS IN sense_list.
    FOR sense_part IN sense_list {
        IF sense_part:TYPE = "ACC" {
            SET has_acc TO TRUE.
            IF NOT sense_part:ACTIVE {
                sense_part:TOGGLE().
            }
        }
        IF sense_part:TYPE = "GRAV" {
            SET has_grav TO TRUE.
            IF NOT sense_part:ACTIVE {
                sense_part:TOGGLE().
            }
        }
    }
    RETURN has_acc AND has_grav.
}

FUNCTION save_landing_target {
    LOCAL launch_geo IS SHIP:GEOPOSITION.
    LOCAL target_data IS LEXICON().
    target_data:ADD("lat", launch_geo:LAT).
    target_data:ADD("lng", launch_geo:LNG).
    target_data:ADD("body", SHIP:BODY:NAME).
    WRITEJSON(target_data, land_target_path).
}

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

// Preflight checks
LOCAL preflight_failed IS FALSE.
log_line("--- Preflight checks ---").
LOCAL use_pid IS sensors_available().
SET twr_pid TO PIDLOOP(twr_kp, twr_ki, twr_kd).
SET twr_pid:MAXOUTPUT TO 0.5.
SET twr_pid:MINOUTPUT TO -0.5.
IF use_pid {
    info_line("Throttle mode", "sensor PID active; Kp=" + twr_kp + " Ki=" + twr_ki + " Kd=" + twr_kd).
} ELSE {
    warn_line("Throttle mode", "sensor PID unavailable; using calculated TWR fallback").
}
check_line(SHIP:AVAILABLETHRUST > 0, "Available thrust", ROUND(SHIP:AVAILABLETHRUST, 1) + " kN").
check_line(max_twr > 0, "Max TWR config", max_twr).
check_line(target_apoapsis > 0, "Target apoapsis config", ROUND(target_apoapsis/1000, 1) + " km default").
check_line(turn_end_alt > turn_start_alt, "Gravity turn config", ROUND(turn_start_alt) + " m -> " + ROUND(turn_end_alt/1000, 1) + " km").
check_line(land_target_path:LENGTH > 0, "Landing target path", land_target_path).
IF preflight_failed {
    abort_launch("preflight checks failed.").
}
transmit_log().
PRINT " ".

PRINT "Press Return to keep each default value.".
SET launch_azimuth TO prompt_number_or_default("Launch heading (deg)", launch_azimuth).
LOCAL target_altitude_km IS prompt_number_or_default("Target orbit altitude (km)", target_apoapsis / 1000).
SET target_apoapsis TO target_altitude_km * 1000.

log_line("=== launch.ks ===").
log_line("Target orbit : " + ROUND(target_apoapsis/1000, 0) + " km  |  azimuth: " + launch_azimuth + " deg").
log_line("Max TWR      : " + max_twr + "  |  gravity turn: " + ROUND(turn_start_alt) + " m -> " + ROUND(turn_end_alt/1000, 0) + " km").
save_landing_target().
log_line("Landing target saved to " + land_target_path + ".").
PRINT " ".

PRINT "Press ENTER to begin launch sequence.".
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
TERMINAL:INPUT:GETCHAR().

SAS OFF.
RCS OFF.
GEAR OFF.
LOCK THROTTLE TO 0.

// Phase 1 — Countdown
LOCK STEERING TO HEADING(launch_azimuth, 90).
log_line("--- Phase 1: Countdown ---").
FROM {LOCAL i IS 5.} UNTIL i = 0 STEP {SET i TO i - 1.} DO {
    log_line("T-" + i + "...").
    WAIT 1.
}
log_line("Ignition!").
LOCK THROTTLE TO 1.0.
STAGE.
transmit_log().

// Phase 2 — Hold vertical until turn_start_alt
log_line("--- Phase 2: Vertical ascent to " + ROUND(turn_start_alt) + " m ---").
LOCAL next_print IS TIME:SECONDS.
UNTIL SHIP:ALTITUDE > turn_start_alt {
    IF TIME:SECONDS >= next_print {
        log_line("  Alt: " + ROUND(SHIP:ALTITUDE) + " m  |  vel: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s  |  stage dv: " + ROUND(current_stage_dv(), 1) + " m/s  |  burn: " + ROUND(current_stage_burn_time_remaining(1.0), 1) + " s").
        mark_telemetry_logged().
    }
    WAIT 0.
}
transmit_log().

// Phase 3 — Gravity turn loop
log_line("--- Phase 3: Gravity turn ---").
SET next_print TO TIME:SECONDS.
LOCAL thrott IS 1.0.
LOCK THROTTLE TO thrott.

UNTIL SHIP:APOAPSIS >= target_apoapsis - apoapsis_cutoff_margin {

    IF active_engine_flameout() AND STAGE:READY {
        log_line("  Engine flameout detected; staging.").
        STAGE.
        WAIT UNTIL STAGE:READY.
        log_line("  New stage  |  stage dv: " + ROUND(current_stage_dv(), 1) + " m/s  |  burn: " + ROUND(current_stage_burn_time_remaining(1.0), 1) + " s").
    }

    LOCAL pitch IS ascent_pitch().
    LOCK STEERING TO HEADING(launch_azimuth, pitch).

    IF use_pid {
        SET twr_pid:SETPOINT TO max_twr.
        SET thrott TO ascent_throttle(MIN(1.0, MAX(0.0, thrott + twr_pid:UPDATE(TIME:SECONDS, measure_gforce())))).
    } ELSE {
        SET thrott TO ascent_throttle(calc_twr_throttle(max_twr)).
    }

    IF TIME:SECONDS >= next_print {
        LOCAL mode IS "pid".
        IF NOT use_pid { SET mode TO "calc". }
        log_line("  Alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  pitch: " + ROUND(pitch) + " deg  |  thr: " + ROUND(thrott, 2) + " [" + mode + "]  |  stage dv: " + ROUND(current_stage_dv(), 1) + " m/s  |  burn: " + ROUND(current_stage_burn_time_remaining(thrott), 1) + " s").
        mark_telemetry_logged().
    }

    WAIT 0.
}
transmit_log().

// Phase 4 — Cut engines, coast to apoapsis
LOCK THROTTLE TO 0.
log_line("--- Phase 4: Coasting to apoapsis ---").
log_line("  Cutoff  |  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  Pe: " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km  |  ecc: " + ROUND(SHIP:OBT:ECCENTRICITY, 3)).
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
log_line("  Circ dv: " + ROUND(circ_dv, 1) + " m/s  |  est. burn: " + ROUND(burn_duration, 1) + " s  |  igniting at T-" + ROUND(burn_duration / 2, 1) + " s").

LOCAL burn_start_eta IS burn_duration / 2.
SET next_print TO TIME:SECONDS.
UNTIL ETA:APOAPSIS < burn_start_eta + 60 {
    SET WARP TO 3.
    IF TIME:SECONDS >= next_print {
        log_line("  Coasting...  ETA Ap: " + ROUND(ETA:APOAPSIS) + " s").
        SET next_print TO TIME:SECONDS + 30.
    }
    WAIT 1.
}
SET WARP TO 0.
UNTIL ETA:APOAPSIS < burn_start_eta {
    log_line("  Igniting in " + ROUND(ETA:APOAPSIS - burn_start_eta, 1) + " s...").
    WAIT 1.
}
transmit_log().

// Phase 5 — Circularisation burn at apoapsis
log_line("--- Phase 5: Circularisation burn ---").
LOCK STEERING TO PROGRADE.

IF SHIP:AVAILABLETHRUST <= 0 {
    log_line("  Ended early: no thrust available.").
} ELSE {
    LOCAL prev_ecc IS SHIP:OBT:ECCENTRICITY.
    LOCAL cur_ecc  IS prev_ecc.
    LOCAL circ_thrott IS 1.0.
    LOCK THROTTLE TO circ_thrott.
    SET next_print TO TIME:SECONDS.
    UNTIL SHIP:AVAILABLETHRUST <= 0 OR cur_ecc > prev_ecc {
        SET prev_ecc TO cur_ecc.
        LOCAL ecc_thr IS MIN(1.0, cur_ecc / circularize_ecc_throttle_scale).
        SET circ_thrott TO ecc_thr.
        IF TIME:SECONDS >= next_print {
            log_line("  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  Pe: " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km  |  ecc: " + ROUND(cur_ecc, 4) + "  |  thr: " + ROUND(circ_thrott, 2) + "  |  stage dv: " + ROUND(current_stage_dv(), 1) + " m/s  |  burn: " + ROUND(current_stage_burn_time_remaining(circ_thrott), 1) + " s").
            mark_telemetry_logged().
        }
        WAIT 0.
        SET cur_ecc TO SHIP:OBT:ECCENTRICITY.
    }
    IF SHIP:AVAILABLETHRUST <= 0 {
        log_line("  Ended early: no thrust available.").
    }
}

LOCK THROTTLE TO 0.
UNLOCK STEERING.
SAS ON.
log_line("--- Orbit achieved! ---").
log_line("  Ap:  " + ROUND(SHIP:APOAPSIS/1000, 1) + " km").
log_line("  Pe:  " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km").
log_line("  ecc: " + ROUND(SHIP:OBT:ECCENTRICITY, 4)).
transmit_log().
