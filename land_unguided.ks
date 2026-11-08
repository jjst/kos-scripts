// ============================================================
//  land_unguided.ks — airbrake descent + PID-throttled landing burn
// ============================================================
//  Used when reentry handoff conditions aren't met. Airbrakes
//  retrograde until suicide_burn_alt_meters, then PID-controls
//  throttle to bring vertical speed to touchdown_speed.

PARAMETER reentry_run_id IS -1.
PARAMETER reentry_telemetry_base_name IS "".
PARAMETER reentry_telemetry_segment_index IS -1.
PARAMETER reentry_initial_part_count IS -1.
PARAMETER reentry_airbrake_mode IS "".
PARAMETER reentry_profile_id IS "".

// --- CONFIG (edit these) ------------------------------------
SET suicide_burn_safety_factor TO 1.1.
SET suicide_burn_max_alt TO 2000.
SET gear_deploy_alt TO 500.
SET touchdown_speed TO 2.
SET descent_kp TO 0.035.
SET descent_ki TO 0.004.
SET descent_kd TO 0.02.
SET descent_min_rate TO -35.
SET descent_pid_min_output TO -0.6.
SET descent_pid_max_output TO 0.6.
SET descent_pid_epsilon TO 0.15.
SET telemetry_interval TO 10.
SET rcs_horiz_threshold_mps TO 0.5.
SET log_path TO "land_unguided.log".
SET survival_telemetry_active TO reentry_run_id >= 0 AND reentry_telemetry_segment_index >= 0 AND reentry_initial_part_count > 0.
SET survival_telemetry_sample_interval TO 2.
SET survival_telemetry_checkpoint_interval TO 20.
SET survival_telemetry_next_sample TO TIME:SECONDS.
SET survival_telemetry_next_checkpoint TO TIME:SECONDS.
SET survival_telemetry_last_part_count TO SHIP:PARTS:LENGTH.
SET survival_telemetry_samples TO LIST().
SET survival_telemetry_events TO LIST().
SET survival_telemetry_run TO LEXICON().
SET survival_telemetry_document TO LEXICON().
SET survival_telemetry_pending_paths TO LIST().
SET survival_telemetry_path TO "".
// ------------------------------------------------------------

FUNCTION clamp {
    PARAMETER value, min_value, max_value.
    RETURN MIN(max_value, MAX(min_value, value)).
}

FUNCTION lerp {
    PARAMETER a, b, t.
    RETURN a + (b - a) * t.
}

FUNCTION log_line {
    PARAMETER msg.
    PRINT msg.
    LOG msg TO log_path.
}

FUNCTION start_survival_telemetry_segment {
    IF NOT survival_telemetry_active { RETURN FALSE. }
    SET survival_telemetry_path TO "1:/" + reentry_telemetry_base_name + "_part_" + reentry_telemetry_segment_index + ".json".
    SET survival_telemetry_samples TO LIST().
    SET survival_telemetry_events TO LIST().
    SET survival_telemetry_document TO LEXICON().
    SET survival_telemetry_document["schema"] TO "reentry_airbrake_predictor".
    SET survival_telemetry_document["schema_version"] TO 4.
    SET survival_telemetry_document["status"] TO "running".
    SET survival_telemetry_document["segment_index"] TO reentry_telemetry_segment_index.
    SET survival_telemetry_document["run"] TO survival_telemetry_run.
    SET survival_telemetry_document["samples"] TO survival_telemetry_samples.
    SET survival_telemetry_document["events"] TO survival_telemetry_events.
    RETURN TRUE.
}

FUNCTION transmit_survival_telemetry {
    IF NOT survival_telemetry_active OR NOT HOMECONNECTION:ISCONNECTED { RETURN FALSE. }
    FOR pending_path IN survival_telemetry_pending_paths {
        COPYPATH(pending_path, "0:").
        DELETEPATH(pending_path).
    }
    SET survival_telemetry_pending_paths TO LIST().
    RETURN TRUE.
}

FUNCTION checkpoint_survival_telemetry {
    PARAMETER checkpoint_status IS "running".
    IF NOT survival_telemetry_active { RETURN FALSE. }
    SET survival_telemetry_document["status"] TO checkpoint_status.
    SET survival_telemetry_document["checkpoint_time_s"] TO TIME:SECONDS.
    SET survival_telemetry_document["segment_sample_count"] TO survival_telemetry_samples:LENGTH.
    WRITEJSON(survival_telemetry_document, survival_telemetry_path).
    survival_telemetry_pending_paths:ADD(survival_telemetry_path).
    transmit_survival_telemetry().
    SET reentry_telemetry_segment_index TO reentry_telemetry_segment_index + 1.
    start_survival_telemetry_segment().
    SET survival_telemetry_next_checkpoint TO TIME:SECONDS + survival_telemetry_checkpoint_interval.
    RETURN TRUE.
}

FUNCTION capture_survival_telemetry {
    PARAMETER landing_phase.
    IF NOT survival_telemetry_active OR TIME:SECONDS < survival_telemetry_next_sample { RETURN FALSE. }
    LOCAL current_part_count IS SHIP:PARTS:LENGTH.
    IF current_part_count <> survival_telemetry_last_part_count {
        LOCAL event IS LEXICON().
        SET event["time_s"] TO TIME:SECONDS.
        SET event["event"] TO "vessel_part_count_changed".
        SET event["detail"] TO survival_telemetry_last_part_count + " -> " + current_part_count + " at " + ROUND(SHIP:ALTITUDE) + " m, q " + ROUND(SHIP:Q * CONSTANT:ATMTOKPA, 2) + " kPa".
        survival_telemetry_events:ADD(event).
        SET survival_telemetry_last_part_count TO current_part_count.
    }
    LOCAL sample IS LEXICON().
    SET sample["time_s"] TO TIME:SECONDS.
    SET sample["phase"] TO landing_phase.
    SET sample["latitude_deg"] TO SHIP:GEOPOSITION:LAT.
    SET sample["longitude_deg"] TO SHIP:GEOPOSITION:LNG.
    SET sample["altitude_asl_m"] TO SHIP:ALTITUDE.
    SET sample["altitude_radar_m"] TO ALT:RADAR.
    SET sample["surface_speed_mps"] TO SHIP:VELOCITY:SURFACE:MAG.
    SET sample["vertical_speed_mps"] TO SHIP:VERTICALSPEED.
    SET sample["dynamic_pressure_kpa"] TO SHIP:Q * CONSTANT:ATMTOKPA.
    SET sample["mass_t"] TO SHIP:MASS.
    SET sample["vessel_part_count"] TO current_part_count.
    SET sample["airbrake_part_count"] TO SHIP:PARTSTAGGED("airbrake"):LENGTH.
    SET sample["vessel_status"] TO SHIP:STATUS.
    survival_telemetry_samples:ADD(sample).
    SET survival_telemetry_next_sample TO TIME:SECONDS + survival_telemetry_sample_interval.
    IF TIME:SECONDS >= survival_telemetry_next_checkpoint { checkpoint_survival_telemetry(). }
    RETURN TRUE.
}

FUNCTION initialize_survival_telemetry {
    IF NOT survival_telemetry_active { RETURN FALSE. }
    SET survival_telemetry_run["run_id"] TO reentry_run_id.
    SET survival_telemetry_run["airbrake_control_mode"] TO reentry_airbrake_mode.
    SET survival_telemetry_run["trajectories_profile_id"] TO reentry_profile_id.
    SET survival_telemetry_run["initial_vessel_part_count"] TO reentry_initial_part_count.
    start_survival_telemetry_segment().
    capture_survival_telemetry("landing_handoff").
    checkpoint_survival_telemetry().
    RETURN TRUE.
}

FUNCTION finalize_survival_telemetry {
    PARAMETER final_status.
    IF NOT survival_telemetry_active { RETURN FALSE. }
    SET survival_telemetry_next_sample TO TIME:SECONDS.
    capture_survival_telemetry("landing_final").
    LOCAL event IS LEXICON().
    SET event["time_s"] TO TIME:SECONDS.
    SET event["event"] TO final_status.
    SET event["detail"] TO "vessel parts " + SHIP:PARTS:LENGTH + "/" + reentry_initial_part_count + ", status " + SHIP:STATUS.
    survival_telemetry_events:ADD(event).
    checkpoint_survival_telemetry(final_status).
    transmit_survival_telemetry().
    SET survival_telemetry_active TO FALSE.
    RETURN TRUE.
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

FUNCTION suicide_burn_altitude {
    LOCAL vs IS SHIP:VELOCITY:SURFACE:MAG.
    LOCAL g IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    IF SHIP:AVAILABLETHRUST <= 0 { RETURN 0. }
    LOCAL net_decel IS SHIP:AVAILABLETHRUST / SHIP:MASS - g.
    IF net_decel <= 0 { RETURN 0. }
    RETURN MIN(suicide_burn_max_alt, suicide_burn_safety_factor * MAX(0, vs^2 - touchdown_speed^2) / (2 * net_decel)).
}

FUNCTION target_descent_rate {
    PARAMETER alt_agl.
    LOCAL t IS clamp(alt_agl / suicide_burn_alt_meters, 0, 1).
    RETURN lerp(-touchdown_speed, descent_min_rate, t).
}

initialize_survival_telemetry().
CLEARSCREEN.
log_line("=== land_unguided.ks ===").
log_line("Unguided descent: airbrakes retrograde, computed suicide burn (factor " + suicide_burn_safety_factor + "), then PID landing burn.").

SAS OFF.
LOCK THROTTLE TO 0.
BRAKES ON.
LOCK STEERING TO SRFRETROGRADE.

log_line("--- Airbrake descent ---").
LOCAL next_print IS TIME:SECONDS.
LOCAL suicide_burn_alt_meters IS suicide_burn_altitude().
UNTIL ALT:RADAR < suicide_burn_alt_meters {
    capture_survival_telemetry("unguided_airbrake_descent").
    SET suicide_burn_alt_meters TO suicide_burn_altitude().
    IF TIME:SECONDS >= next_print {
        log_line("  Alt: " + ROUND(SHIP:ALTITUDE/1000, 2) + " km  |  AGL: " + ROUND(ALT:RADAR) + " m  |  spd: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s  |  burn_alt: " + ROUND(suicide_burn_alt_meters) + " m").
        transmit_log().
        SET next_print TO TIME:SECONDS + telemetry_interval.
    }
    WAIT 0.
}

BRAKES OFF.
log_line("--- Landing burn ---  |  AGL: " + ROUND(ALT:RADAR) + " m  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s  |  spd: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s").

LOCAL descent_pid IS PIDLOOP(
    descent_kp, descent_ki, descent_kd,
    descent_pid_min_output, descent_pid_max_output,
    descent_pid_epsilon
).
LOCAL thrott_cmd IS 0.
LOCAL gear_deployed IS FALSE.
LOCAL landing_aborted IS FALSE.
LOCK THROTTLE TO thrott_cmd.
LOCK STEERING TO SRFRETROGRADE.
SET next_print TO TIME:SECONDS.

UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
    capture_survival_telemetry("unguided_landing_burn").
    LOCAL alt_agl IS ALT:RADAR.
    LOCAL vs IS SHIP:VERTICALSPEED.
    LOCAL g IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.

    IF NOT gear_deployed AND alt_agl < gear_deploy_alt {
        GEAR ON.
        RCS ON.
        LOCK STEERING TO UP.
        SET gear_deployed TO TRUE.
        log_line("  Gear down  |  AGL: " + ROUND(alt_agl) + " m").
    }

    IF gear_deployed {
        LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
        IF horiz_vel:MAG > rcs_horiz_threshold_mps {
            LOCAL correction IS -horiz_vel:NORMALIZED.
            SET SHIP:CONTROL:TRANSLATION TO V(
                VDOT(correction, SHIP:FACING:STARVECTOR),
                VDOT(correction, SHIP:FACING:TOPVECTOR),
                VDOT(correction, SHIP:FACING:FOREVECTOR)
            ).
        } ELSE {
            SET SHIP:CONTROL:TRANSLATION TO V(0, 0, 0).
        }
    }

    IF SHIP:AVAILABLETHRUST <= 0 {
        SET thrott_cmd TO 0.
        SET landing_aborted TO TRUE.
        log_line("  FATAL: no thrust  |  AGL: " + ROUND(alt_agl) + " m  |  vs: " + ROUND(vs, 1) + " m/s").
        BREAK.
    }

    LOCAL target_vs IS target_descent_rate(alt_agl).
    SET descent_pid:SETPOINT TO target_vs.
    LOCAL hover IS (SHIP:MASS * g) / SHIP:AVAILABLETHRUST.
    LOCAL pid_correction IS descent_pid:UPDATE(TIME:SECONDS, vs).
    SET thrott_cmd TO clamp(hover + pid_correction, 0, 1).

    IF TIME:SECONDS >= next_print {
        log_line("  AGL: " + ROUND(alt_agl) + " m  |  vs: " + ROUND(vs, 1) + " m/s  |  tgt_vs: " + ROUND(target_vs, 1) + " m/s  |  thr: " + ROUND(thrott_cmd, 2)).
        transmit_log().
        SET next_print TO TIME:SECONDS + 2.
    }
    WAIT 0.
}

SET thrott_cmd TO 0.
SET SHIP:CONTROL:TRANSLATION TO V(0, 0, 0).
RCS OFF.
UNLOCK THROTTLE.
UNLOCK STEERING.
log_line("Landed  |  vs: " + ROUND(SHIP:VERTICALSPEED, 2) + " m/s  |  status: " + SHIP:STATUS).
LOCAL survival_final_status IS "landed".
IF landing_aborted { SET survival_final_status TO "landing_abort". }
IF SHIP:STATUS = "SPLASHED" { SET survival_final_status TO "splashed". }
finalize_survival_telemetry(survival_final_status).
transmit_log().
