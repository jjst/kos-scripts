// ============================================================
//  land.ks — VTVL descent and landing guidance
// ============================================================
//  Performs PID-guided descent with active guidance back to the
//  launch position saved by launch.ks.

// --- CONFIG (edit these) ------------------------------------
SET gear_deploy_alt   TO 500.
SET telemetry_interval TO 5.
SET entry_telemetry_interval TO 20.
SET entry_brakes_enabled TO TRUE.
SET entry_brakes_deploy_alt_meters TO 70000.
SET entry_brakes_retract_speed_mps TO 1200.
SET entry_aoa_enabled TO TRUE.
SET entry_aoa_high_alt_meters TO 70000.
SET entry_aoa_low_alt_meters TO 35000.
SET entry_aoa_high_deg TO 50.
SET entry_aoa_low_deg TO 5.
SET entry_aoa_retract_speed_mps TO 1200.
SET entry_aoa_pid_enabled TO TRUE.
SET entry_aoa_min_deg TO -45.
SET entry_aoa_max_deg TO 60.
SET entry_aoa_prediction_alt_meters TO 35000.
SET entry_aoa_pid_kp TO 0.00015.
SET entry_aoa_pid_ki TO 0.
SET entry_aoa_pid_kd TO 0.
SET entry_aoa_commanded_deg TO 0.
SET entry_aoa_base_deg_current TO 0.
SET entry_aoa_pid_delta_deg_current TO 0.
SET entry_aoa_pred_miss_meters_current TO 0.
SET entry_aoa_along_error_meters_current TO 0.
// Keep a small non-zero touchdown rate to avoid over-braking hover oscillation.
SET touchdown_speed   TO 2.
// PID gains for powered descent vertical-speed control.
// Increase Kp for faster response, Ki to reduce steady-state bias, Kd for damping.
SET descent_kp        TO 0.035.
SET descent_ki        TO 0.004.
SET descent_kd        TO 0.02.
// Fastest commanded descent rate at high altitude (m/s, negative = downward).
SET descent_min_rate  TO -35.
SET descent_profile_high_alt  TO 400.
SET descent_profile_mid_alt   TO 200.
SET descent_profile_low_alt   TO 50.
SET descent_profile_flare_alt TO 10.
SET descent_profile_mid_rate  TO -12.
SET descent_profile_low_rate  TO -6.
SET descent_pid_min_output TO -0.6.
SET descent_pid_max_output TO  0.6.
// Limit steering aggressiveness to reduce rapid self-spin during descent.
SET descent_max_stopping_time TO 3.5.
// PID error deadband (m/s) to reduce tiny throttle chatter.
SET descent_pid_epsilon TO 0.15.
// D3 horizontal speed target cap: m/s allowed per sqrt-meter AGL.
SET d3_hvel_limit_slope TO 0.5.
// Target descent speed during powered-descent phase (m/s, magnitude).
SET d2_target_speed TO 150.
// Proportional gain for Descent Phase 2 speed hold.
SET d2_speed_kp TO 0.03.
// Descent phase handoff altitudes.
SET powered_steering_alt_meters TO 5000.
SET landing_burn_alt_meters TO 1000.
SET guidance_start_range_meters TO 200000.
SET entry_orbit_retro_alt_meters TO 70000.
// Shared lateral miss corridor based on altitude above ground.
SET handoff_tolerance_slope TO 0.4.   // extra meters allowed per sqrt-meter AGL
// Keep correcting this fraction of predicted miss even inside the corridor.
// The corridor softens guidance effort; it does not create a no-correction dead zone.
SET handoff_min_effort_fraction TO 0.5.
// Lateral guidance PID — output is commanded tilt in degrees away from pad.
// Aerodynamic force from tilt pushes the rocket toward the pad.
// Descent Phase 1 controls handoff miss directly; the tilt clamp is the authority limit.
SET d1_miss_kp           TO 0.16.  // deg per meter of effective handoff miss
SET d1_miss_ki           TO 0.0.
SET d1_miss_kd           TO 0.0.
SET d1_lat_max_tilt      TO 30.    // degrees
// Descent Phase 2 (powered, ~150 m/s).
SET d2_lat_kp            TO 0.5.
SET d2_lat_ki            TO 0.05.
SET d2_lat_kd            TO 0.1.
SET d2_lat_max_tilt      TO 30.    // degrees
// Minimum horizontal distance (m) before applying lateral correction.
SET lat_min_horiz_dist TO 10.
// Landing target written by launch.ks.
SET land_target_path TO "1:/land-target.json".
SET fallback_target_body TO "Kerbin".
SET fallback_target_lat TO -0.0972.
SET fallback_target_lng TO -74.5577.
// Terminal output is mirrored to this file with LOG.
SET log_path TO "land.log".
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

FUNCTION abort_land {
    PARAMETER msg.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    log_line("ABORT: " + msg).
    transmit_log().
    WAIT 5.
    SHUTDOWN.
}

FUNCTION next_telemetry_time {
    RETURN TIME:SECONDS + telemetry_interval.
}

FUNCTION pad_steer_direction {
    PARAMETER horiz_vec, tilt_deg, min_horiz_dist.
    LOCAL srfret IS SHIP:SRFRETROGRADE:FOREVECTOR.
    IF horiz_vec:MAG > min_horiz_dist AND ABS(tilt_deg) > 0.01 {
        // Rotate srfret AWAY from the predicted-miss direction.
        // Aerodynamic force on the tilted body pushes the rocket toward the pad.
        // Axis: toward_pad × srfret — right-hand rotation around this axis
        // moves the nose away from toward_pad.
        LOCAL axis IS VCRS(horiz_vec:NORMALIZED, srfret).
        RETURN ANGLEAXIS(tilt_deg, axis) * srfret.
    }
    RETURN srfret.
}

FUNCTION time_to_alt_delta {
    PARAMETER vs, g, alt_delta.
    IF alt_delta <= 0 OR g <= 0 {
        RETURN 0.
    }
    LOCAL disc IS vs^2 + 2 * g * alt_delta.
    IF disc <= 0 {
        RETURN 0.
    }
    RETURN MAX(0, (vs + SQRT(disc)) / g).
}

FUNCTION predict_miss_vec {
    PARAMETER to_pad_h, horiz_vel, vs, g, alt_delta.
    LOCAL tof IS time_to_alt_delta(vs, g, alt_delta).
    RETURN to_pad_h - horiz_vel * tof.
}

FUNCTION allowed_handoff_miss {
    PARAMETER alt_agl.
    RETURN SQRT(MAX(0, alt_agl)) * handoff_tolerance_slope.
}

FUNCTION target_hclosing_speed {
    PARAMETER horiz_dist, tof, alt_agl.
    LOCAL effective_miss IS guidance_effective_miss(horiz_dist, alt_agl).
    IF effective_miss <= 0 OR tof <= 0 {
        RETURN 0.
    }
    RETURN effective_miss / tof.
}

FUNCTION guidance_effective_miss {
    PARAMETER horiz_dist, alt_agl.
    LOCAL allowed_miss IS allowed_handoff_miss(alt_agl).
    LOCAL outside_miss IS MAX(0, horiz_dist - allowed_miss).
    LOCAL floor_miss IS horiz_dist * handoff_min_effort_fraction.
    RETURN MAX(outside_miss, floor_miss).
}

FUNCTION actual_retro_tilt {
    RETURN VANG(SHIP:FACING:FOREVECTOR, SHIP:SRFRETROGRADE:FOREVECTOR).
}

FUNCTION actual_entry_aoa {
    LOCAL srfret IS SHIP:SRFRETROGRADE:FOREVECTOR.
    LOCAL axis IS VCRS(UP:FOREVECTOR, srfret).
    LOCAL angle IS VANG(SHIP:FACING:FOREVECTOR, srfret).
    IF axis:MAG <= 0.01 {
        RETURN angle.
    }
    IF VDOT(VCRS(srfret, SHIP:FACING:FOREVECTOR), axis:NORMALIZED) < 0 {
        RETURN -angle.
    }
    RETURN angle.
}

FUNCTION roll_rate_deg {
    RETURN VDOT(SHIP:ANGULARVEL, SHIP:FACING:FOREVECTOR) * 57.2958.
}

FUNCTION d3_roll_reference {
    PARAMETER look.
    LOCAL ref IS VXCL(look, HEADING(0, 0):FOREVECTOR).
    IF ref:MAG < 0.01 {
        SET ref TO VXCL(look, HEADING(90, 0):FOREVECTOR).
    }
    RETURN ref.
}

FUNCTION d3_steering_direction {
    LOCAL look IS SHIP:SRFRETROGRADE:FOREVECTOR.
    IF ALT:RADAR < gear_deploy_alt {
        SET look TO UP:FOREVECTOR.
    }
    RETURN LOOKDIRUP(look, d3_roll_reference(look)).
}

FUNCTION roll_error_deg {
    PARAMETER roll_ref.
    RETURN VANG(SHIP:FACING:TOPVECTOR, roll_ref).
}

FUNCTION entry_retrograde_steering {
    IF SHIP:ALTITUDE > entry_orbit_retro_alt_meters {
        RETURN RETROGRADE.
    }
    IF entry_aoa_active() {
        LOCAL srfret IS SHIP:SRFRETROGRADE:FOREVECTOR.
        LOCAL axis IS VCRS(UP:FOREVECTOR, srfret).
        IF axis:MAG > 0.01 {
            RETURN ANGLEAXIS(entry_aoa_command(), axis:NORMALIZED) * srfret.
        }
    }
    RETURN SHIP:SRFRETROGRADE.
}

FUNCTION entry_aoa_active {
    RETURN entry_aoa_enabled AND
           SHIP:ALTITUDE < entry_aoa_high_alt_meters AND
           SHIP:VELOCITY:SURFACE:MAG > entry_aoa_retract_speed_mps.
}

FUNCTION entry_aoa_base_command {
    IF SHIP:ALTITUDE >= entry_aoa_high_alt_meters {
        RETURN entry_aoa_high_deg.
    }
    IF SHIP:ALTITUDE <= entry_aoa_low_alt_meters {
        RETURN entry_aoa_low_deg.
    }

    LOCAL t IS (SHIP:ALTITUDE - entry_aoa_low_alt_meters) /
              (entry_aoa_high_alt_meters - entry_aoa_low_alt_meters).
    RETURN lerp(entry_aoa_low_deg, entry_aoa_high_deg, t).
}

FUNCTION entry_aoa_command {
    IF NOT entry_aoa_active() {
        RETURN 0.
    }
    RETURN entry_aoa_commanded_deg.
}

FUNCTION capped_hvel_target {
    PARAMETER to_pad_h, alt_agl, vs.
    LOCAL time_to_ground IS alt_agl / MAX(ABS(vs), 1).
    LOCAL target_hvel IS to_pad_h / MAX(time_to_ground, 1).
    LOCAL max_hvel IS SQRT(MAX(0, alt_agl)) * d3_hvel_limit_slope.
    IF target_hvel:MAG > max_hvel {
        SET target_hvel TO target_hvel:NORMALIZED * max_hvel.
    }
    RETURN target_hvel.
}

FUNCTION transmit_log {
    LOCAL recovered_on_kerbin IS FALSE.
    IF SHIP:BODY:NAME = "Kerbin" {
        IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            SET recovered_on_kerbin TO TRUE.
        }
    }

    // Archive transfer is allowed after Kerbin recovery or through a live home link.
    IF recovered_on_kerbin OR HOMECONNECTION:ISCONNECTED {
        COPYPATH(log_path, "0:").
        RETURN TRUE.
    }
    RETURN FALSE.
}

FUNCTION target_descent_rate {
    PARAMETER alt_agl.
    IF alt_agl > descent_profile_high_alt {
        RETURN descent_min_rate.
    }
    IF alt_agl > descent_profile_mid_alt {
        LOCAL t1 IS (alt_agl - descent_profile_mid_alt) /
                    (descent_profile_high_alt - descent_profile_mid_alt).
        RETURN lerp(descent_profile_mid_rate, descent_min_rate, t1).
    }
    IF alt_agl > descent_profile_low_alt {
        LOCAL t2 IS (alt_agl - descent_profile_low_alt) /
                    (descent_profile_mid_alt - descent_profile_low_alt).
        RETURN lerp(descent_profile_low_rate, descent_profile_mid_rate, t2).
    }
    IF alt_agl > descent_profile_flare_alt {
        LOCAL t3 IS (alt_agl - descent_profile_flare_alt) /
                    (descent_profile_low_alt - descent_profile_flare_alt).
        RETURN lerp(-touchdown_speed, descent_profile_low_rate, t3).
    }
    RETURN -touchdown_speed.
}

CLEARSCREEN.
log_line("=== land.ks ===").
LOCAL preflight_failed IS FALSE.
LOCAL target_body IS fallback_target_body.
LOCAL target_lat IS fallback_target_lat.
LOCAL target_lng IS fallback_target_lng.
LOCAL target_source IS "fallback KSC launchpad".
LOCAL target_file_found IS EXISTS(land_target_path).
IF target_file_found {
    LOCAL target_data IS READJSON(land_target_path).
    SET target_body TO target_data["body"].
    SET target_lat TO target_data["lat"].
    SET target_lng TO target_data["lng"].
    SET target_source TO land_target_path.
} ELSE {
    log_line("WARN: missing landing target file: " + land_target_path + ".").
    log_line("      Using fallback KSC launchpad coordinates.").
}

LOCAL pad_geo  IS LATLNG(target_lat, target_lng).
LOCAL lat_tilt IS 0.
LOCAL lat_pid  IS PIDLOOP(d1_miss_kp, d1_miss_ki, d1_miss_kd,
                           -d1_lat_max_tilt * 2, d1_lat_max_tilt * 2).
log_line("Gear deploy  : " + gear_deploy_alt + " m AGL").
log_line("Target       : " + ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5) + " on " + target_body).
log_line("Target source: " + target_source).
log_line("Guidance range: " + ROUND(guidance_start_range_meters/1000, 1) + " km").
log_line("Entry attitude: orbit retro above " + ROUND(entry_orbit_retro_alt_meters/1000, 1) + " km, surface retro below.").
log_line("Entry AoA    : " + entry_aoa_high_deg + " deg @ " + ROUND(entry_aoa_high_alt_meters/1000, 1) + " km -> " + entry_aoa_low_deg + " deg @ " + ROUND(entry_aoa_low_alt_meters/1000, 1) + " km while faster than " + ROUND(entry_aoa_retract_speed_mps) + " m/s.").
log_line("Entry AoA PID: " + entry_aoa_min_deg + " to " + entry_aoa_max_deg + " deg  |  gate " + ROUND(entry_aoa_prediction_alt_meters/1000, 1) + " km  |  Kp " + entry_aoa_pid_kp).

log_line("--- Preflight checks ---").
IF target_file_found {
    info_line("Landing target file", target_source).
} ELSE {
    warn_line("Landing target file", "missing; using " + target_source).
}
check_line(target_body = SHIP:BODY:NAME, "Target body", "target " + target_body + ", current " + SHIP:BODY:NAME).
check_line(SHIP:AVAILABLETHRUST > 0, "Available thrust", ROUND(SHIP:AVAILABLETHRUST, 1) + " kN").
check_line(guidance_start_range_meters > 0, "Guidance range", ROUND(guidance_start_range_meters/1000, 1) + " km").
check_line(powered_steering_alt_meters > landing_burn_alt_meters, "Descent handoff altitudes", ROUND(powered_steering_alt_meters) + " m -> " + ROUND(landing_burn_alt_meters) + " m").
check_line(entry_brakes_retract_speed_mps > 0, "Entry brake retract speed", ROUND(entry_brakes_retract_speed_mps) + " m/s").
check_line(entry_aoa_high_alt_meters > entry_aoa_low_alt_meters, "Entry AoA altitude ramp", ROUND(entry_aoa_high_alt_meters/1000, 1) + " km -> " + ROUND(entry_aoa_low_alt_meters/1000, 1) + " km").
check_line(entry_aoa_high_deg >= entry_aoa_low_deg AND entry_aoa_low_deg >= 0, "Entry AoA angle ramp", ROUND(entry_aoa_high_deg, 1) + " deg -> " + ROUND(entry_aoa_low_deg, 1) + " deg").
check_line(entry_aoa_retract_speed_mps > 0, "Entry AoA retract speed", ROUND(entry_aoa_retract_speed_mps) + " m/s").
check_line(entry_aoa_min_deg < entry_aoa_max_deg, "Entry AoA command limits", ROUND(entry_aoa_min_deg, 1) + " to " + ROUND(entry_aoa_max_deg, 1) + " deg").
check_line(entry_aoa_prediction_alt_meters > 0, "Entry AoA prediction gate", ROUND(entry_aoa_prediction_alt_meters/1000, 1) + " km").
info_line("Landing target coordinates", ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5)).
IF preflight_failed {
    abort_land("preflight checks failed.").
}
transmit_log().

SAS OFF.
LOCK THROTTLE TO 0.
LOCAL start_time IS TIME:SECONDS.
LOCAL next_print IS TIME:SECONDS.
LOCAL entry_aoa_pid IS PIDLOOP().
SET entry_aoa_pid:KP TO entry_aoa_pid_kp.
SET entry_aoa_pid:KI TO entry_aoa_pid_ki.
SET entry_aoa_pid:KD TO entry_aoa_pid_kd.
SET entry_aoa_pid:MINOUTPUT TO entry_aoa_min_deg - entry_aoa_high_deg.
SET entry_aoa_pid:MAXOUTPUT TO entry_aoa_max_deg - entry_aoa_low_deg.
SET entry_aoa_pid:SETPOINT TO 0.
LOCAL entry_aoa_negative_logged IS FALSE.

LOCK STEERING TO entry_retrograde_steering().
log_line("--- ENTRY GUIDANCE: Range and energy control ---").
LOCAL entry_brakes_deployed IS entry_brakes_enabled AND SHIP:VELOCITY:SURFACE:MAG > entry_brakes_retract_speed_mps.
IF entry_brakes_deployed {
    BRAKES ON.
    log_line("  Entry brakes armed  |  speed: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s").
}
UNTIL VXCL(UP:FOREVECTOR, pad_geo:POSITION):MAG < guidance_start_range_meters {
    LOCAL surface_speed IS SHIP:VELOCITY:SURFACE:MAG.
    LOCAL to_pad_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
    LOCAL horiz_vel_wait IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
    LOCAL g_wait IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    LOCAL entry_alt_delta IS SHIP:ALTITUDE - entry_aoa_prediction_alt_meters.
    LOCAL entry_pred_vec IS predict_miss_vec(to_pad_h, horiz_vel_wait, SHIP:VERTICALSPEED, g_wait, entry_alt_delta).
    SET entry_aoa_pred_miss_meters_current TO entry_pred_vec:MAG.
    SET entry_aoa_along_error_meters_current TO 0.
    IF horiz_vel_wait:MAG > 1 {
        SET entry_aoa_along_error_meters_current TO VDOT(entry_pred_vec, horiz_vel_wait:NORMALIZED).
    }

    IF entry_aoa_active() {
        SET entry_aoa_base_deg_current TO entry_aoa_base_command().
        IF entry_aoa_pid_enabled {
            SET entry_aoa_pid_delta_deg_current TO entry_aoa_pid:UPDATE(TIME:SECONDS, entry_aoa_along_error_meters_current).
        } ELSE {
            SET entry_aoa_pid_delta_deg_current TO 0.
        }
        SET entry_aoa_commanded_deg TO clamp(entry_aoa_base_deg_current + entry_aoa_pid_delta_deg_current, entry_aoa_min_deg, entry_aoa_max_deg).
        IF entry_aoa_commanded_deg < 0 AND NOT entry_aoa_negative_logged {
            log_line("  Entry AoA negative command  |  cmd: " + ROUND(entry_aoa_commanded_deg, 1) + " deg  |  along: " + ROUND(entry_aoa_along_error_meters_current) + " m").
            SET entry_aoa_negative_logged TO TRUE.
        } ELSE IF entry_aoa_commanded_deg >= 0 {
            SET entry_aoa_negative_logged TO FALSE.
        }
    } ELSE {
        SET entry_aoa_base_deg_current TO 0.
        SET entry_aoa_pid_delta_deg_current TO 0.
        SET entry_aoa_commanded_deg TO 0.
        SET entry_aoa_negative_logged TO FALSE.
    }

    IF entry_brakes_enabled {
        IF NOT entry_brakes_deployed AND SHIP:ALTITUDE < entry_brakes_deploy_alt_meters AND surface_speed > entry_brakes_retract_speed_mps {
            BRAKES ON.
            SET entry_brakes_deployed TO TRUE.
            log_line("  Entry brakes deployed  |  alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  speed: " + ROUND(surface_speed, 1) + " m/s").
        } ELSE IF entry_brakes_deployed AND surface_speed <= entry_brakes_retract_speed_mps {
            BRAKES OFF.
            SET entry_brakes_deployed TO FALSE.
            log_line("  Entry brakes retracted  |  alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  speed: " + ROUND(surface_speed, 1) + " m/s").
        }
    }

    IF TIME:SECONDS >= next_print {
        LOCAL retro_mode IS "surface".
        LOCAL brake_mode IS "off".
        LOCAL aoa_mode IS "off".
        LOCAL aoa_cmd IS 0.
        IF entry_brakes_deployed {
            SET brake_mode TO "on".
        }
        IF SHIP:ALTITUDE > entry_orbit_retro_alt_meters {
            SET retro_mode TO "orbit".
        } ELSE IF entry_aoa_active() {
            SET aoa_mode TO "on".
            SET aoa_cmd TO entry_aoa_commanded_deg.
        }
        log_line("  Range: " + ROUND(to_pad_h:MAG/1000, 1) + " km  |  hdg: " + ROUND(pad_geo:HEADING, 1) + "  |  brg: " + ROUND(pad_geo:BEARING, 1) + "  |  Alt: " + ROUND(ALT:RADAR/1000, 1) + " km AGL  |  spd: " + ROUND(surface_speed, 1) + " m/s  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s").
        log_line("    brakes: " + brake_mode + "  |  retro: " + retro_mode + "  |  aoa: " + aoa_mode + "  |  base: " + ROUND(entry_aoa_base_deg_current, 1) + " deg  |  delta: " + ROUND(entry_aoa_pid_delta_deg_current, 1) + " deg  |  cmd: " + ROUND(aoa_cmd, 1) + " deg  |  actual: " + ROUND(actual_entry_aoa(), 1) + " deg").
        log_line("    gate: " + ROUND(entry_aoa_prediction_alt_meters/1000, 1) + " km  |  pred_miss: " + ROUND(entry_aoa_pred_miss_meters_current) + " m  |  along: " + ROUND(entry_aoa_along_error_meters_current) + " m").
        transmit_log().
        SET next_print TO TIME:SECONDS + entry_telemetry_interval.
    }
    WAIT 0.
}
log_line("  Guidance start  |  range: " + ROUND(VXCL(UP:FOREVECTOR, pad_geo:POSITION):MAG) + " m  |  hdg: " + ROUND(pad_geo:HEADING, 1) + "  |  brg: " + ROUND(pad_geo:BEARING, 1) + "  |  alt: " + ROUND(ALT:RADAR) + " m AGL").
transmit_log().

// Descent Phase 1 — Descending: PID lateral guidance until 5 km handoff
LOCAL original_max_stopping_time IS STEERINGMANAGER:MAXSTOPPINGTIME.
SET STEERINGMANAGER:MAXSTOPPINGTIME TO descent_max_stopping_time.
LOCAL pred_to_pad IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
LOCK STEERING TO pad_steer_direction(pred_to_pad, lat_tilt, lat_min_horiz_dist).
log_line("--- DESCENT PHASE 1: Descending ---").
RCS ON.
SET next_print TO TIME:SECONDS.
UNTIL ALT:RADAR < powered_steering_alt_meters {
    LOCAL alt_agl IS ALT:RADAR.

    LOCAL to_pad_h  IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
    LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
    LOCAL vs        IS SHIP:VERTICALSPEED.
    LOCAL g_d1      IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    LOCAL alt_delta IS alt_agl - powered_steering_alt_meters.
    LOCAL tof       IS time_to_alt_delta(vs, g_d1, alt_delta).
    SET pred_to_pad TO predict_miss_vec(to_pad_h, horiz_vel, vs, g_d1, alt_delta).
    LOCAL pred_miss IS pred_to_pad:MAG.
    LOCAL allowed_miss IS allowed_handoff_miss(alt_agl).
    LOCAL effective_miss IS guidance_effective_miss(pred_miss, alt_agl).
    LOCAL miss_tilt IS 0.
    IF pred_miss > lat_min_horiz_dist {
        // Descent Phase 1 is about fixing the predicted handoff miss now, not pacing it
        // against remaining time.
        SET lat_pid:SETPOINT TO 0.
        SET miss_tilt TO lat_pid:UPDATE(TIME:SECONDS, -effective_miss).
        SET lat_tilt TO clamp(miss_tilt, -d1_lat_max_tilt, d1_lat_max_tilt).
    } ELSE {
        SET lat_tilt TO 0.
    }

    IF TIME:SECONDS >= next_print {
        LOCAL actual_tilt IS actual_retro_tilt().
        log_line("  Alt: " + ROUND(alt_agl) + " m AGL  |  vs: " + ROUND(vs, 1) + " m/s  |  tof_to_d2: " + ROUND(tof, 1) + " s").
        log_line("    horiz: " + ROUND(to_pad_h:MAG) + " m  |  pred_miss: " + ROUND(pred_miss) + " m  |  tol: " + ROUND(allowed_miss) + " m  |  eff_miss: " + ROUND(effective_miss) + " m  |  miss_tilt: " + ROUND(miss_tilt, 1) + " deg  |  tilt_cmd: " + ROUND(lat_tilt, 1) + " deg  |  actual_tilt: " + ROUND(actual_tilt, 1) + " deg").
        SET next_print TO next_telemetry_time().
    }
    WAIT 0.
}
log_line("  DESCENT PHASE 2 handoff  |  alt: " + ROUND(ALT:RADAR) + " m  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s").
transmit_log().

// Descent Phase 2 — Powered descent and launchpad steering
log_line("--- DESCENT PHASE 2: Powered descent / launchpad steering ---").
SET lat_pid TO PIDLOOP(d2_lat_kp, d2_lat_ki, d2_lat_kd,
                        -d2_lat_max_tilt, d2_lat_max_tilt).
BRAKES ON.
LOCK THROTTLE TO 0.
LOCAL d2_target_vs IS -(d2_target_speed).
SET next_print TO TIME:SECONDS.
UNTIL ALT:RADAR <= landing_burn_alt_meters {
    LOCAL alt_agl IS ALT:RADAR.
    LOCAL vs IS SHIP:VERTICALSPEED.
    LOCAL g_d2 IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.

    LOCAL to_pad_h   IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
    LOCAL horiz_vel  IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
    LOCAL alt_delta  IS alt_agl - landing_burn_alt_meters.
    LOCAL tof        IS time_to_alt_delta(vs, g_d2, alt_delta).
    SET pred_to_pad TO predict_miss_vec(to_pad_h, horiz_vel, vs, g_d2, alt_delta).
    LOCAL pred_miss  IS pred_to_pad:MAG.
    LOCAL horiz_dist IS to_pad_h:MAG.
    // Descent Phase 2 is powered, so ballistic miss is diagnostic only here.
    // Guidance uses raw offset while closure direction still follows pred_to_pad.
    LOCAL guidance_miss IS horiz_dist.
    LOCAL allowed_miss IS allowed_handoff_miss(alt_agl).
    LOCAL effective_miss IS guidance_effective_miss(guidance_miss, alt_agl).
    LOCAL hclos      IS 0.
    LOCAL hclos_tgt  IS 0.
    IF horiz_dist > lat_min_horiz_dist {
        SET hclos     TO VDOT(horiz_vel, pred_to_pad:NORMALIZED).
        SET hclos_tgt TO target_hclosing_speed(guidance_miss, tof, alt_agl).
    }
    SET lat_pid:SETPOINT TO hclos_tgt.
    SET lat_tilt TO lat_pid:UPDATE(TIME:SECONDS, hclos).

    IF SHIP:AVAILABLETHRUST <= 0 {
        log_line("  FATAL: no thrust in DESCENT PHASE 2 — forcing DESCENT PHASE 3.").
        BREAK.
    }
    LOCAL hover IS (SHIP:MASS * g_d2) / SHIP:AVAILABLETHRUST.
    LOCAL speed_err IS d2_target_vs - vs.
    LOCAL d2_throttle IS clamp(hover + d2_speed_kp * speed_err, 0, 1).
    LOCK THROTTLE TO d2_throttle.

    IF TIME:SECONDS >= next_print {
        LOCAL actual_tilt IS actual_retro_tilt().
        log_line("  Alt: " + ROUND(alt_agl) + " m  |  vs: " + ROUND(vs, 1) + " m/s  |  tof_to_d3: " + ROUND(tof, 1) + " s  |  thr: " + ROUND(d2_throttle, 2)).
        log_line("    horiz: " + ROUND(to_pad_h:MAG) + " m  |  pred_miss: " + ROUND(pred_miss) + " m  |  guidance_miss: " + ROUND(guidance_miss) + " m  |  tol: " + ROUND(allowed_miss) + " m  |  eff_miss: " + ROUND(effective_miss) + " m  |  hclos: " + ROUND(hclos, 1) + " m/s  |  tgt_hclos: " + ROUND(hclos_tgt, 1) + " m/s  |  tilt_cmd: " + ROUND(lat_tilt, 1) + " deg  |  actual_tilt: " + ROUND(actual_tilt, 1) + " deg").
        SET next_print TO next_telemetry_time().
    }
    WAIT 0.
}
log_line("  DESCENT PHASE 3 handoff  |  alt: " + ROUND(ALT:RADAR) + " m  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s").
transmit_log().

// Descent Phase 3 — Landing burn (retrograde with RCS trim)
log_line("--- DESCENT PHASE 3: Landing burn / RCS trim ---").
// Hold retrograde for braking, then switch to vertical-up at gear deploy
// altitude so the final touchdown attitude does not chase tiny retrograde shifts.
LOCAL gear_deployed IS FALSE.
LOCK STEERING TO d3_steering_direction().
RCS ON.
SET descent_pid TO PIDLOOP(
    descent_kp,
    descent_ki,
    descent_kd,
    descent_pid_min_output,
    descent_pid_max_output,
    descent_pid_epsilon // PID epsilon deadband to reduce throttle chatter.
).
SET thrott_cmd TO 0.
SET descent_aborted TO FALSE.
LOCK THROTTLE TO thrott_cmd.
LOCAL d3_rcs_star_pid IS PIDLOOP().
LOCAL d3_rcs_top_pid IS PIDLOOP().
SET d3_rcs_star_pid:MINOUTPUT TO -1.
SET d3_rcs_star_pid:MAXOUTPUT TO 1.
SET d3_rcs_top_pid:MINOUTPUT TO -1.
SET d3_rcs_top_pid:MAXOUTPUT TO 1.
SET d3_rcs_star_pid:SETPOINT TO 0.
SET d3_rcs_top_pid:SETPOINT TO 0.
SET next_print TO TIME:SECONDS.
UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
    LOCAL g_land IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    LOCAL alt_agl IS ALT:RADAR.
    IF NOT gear_deployed AND alt_agl < gear_deploy_alt {
        GEAR ON.
        SET gear_deployed TO TRUE.
        log_line("  Gear down (powered)  |  alt: " + ROUND(alt_agl) + " m AGL").
    }
    LOCAL thrust_available IS SHIP:AVAILABLETHRUST.
    IF thrust_available <= 0 {
        log_line("  FATAL: no thrust during powered descent  |  status: " + SHIP:STATUS + "  |  alt: " + ROUND(alt_agl) + " m  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s").
        SET descent_aborted TO TRUE.
        SET thrott_cmd TO 0.
        BREAK.
    }

    LOCAL vs_d3     IS SHIP:VERTICALSPEED.
    LOCAL to_pad_h  IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
    LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
    LOCAL horiz_dist IS to_pad_h:MAG.
    LOCAL target_hvel IS capped_hvel_target(to_pad_h, alt_agl, vs_d3).
    LOCAL hvel_error IS horiz_vel - target_hvel.
    LOCAL hspd IS horiz_vel:MAG.
    LOCAL tgt_hspd IS target_hvel:MAG.
    LOCAL max_hspd IS SQRT(MAX(0, alt_agl)) * d3_hvel_limit_slope.
    LOCAL star_err IS VDOT(hvel_error, SHIP:FACING:STARVECTOR).
    LOCAL top_err  IS VDOT(hvel_error, SHIP:FACING:TOPVECTOR).
    LOCAL rcs_cmd IS V(
        d3_rcs_star_pid:UPDATE(TIME:SECONDS, star_err),
        d3_rcs_top_pid:UPDATE(TIME:SECONDS, top_err),
        0
    ).
    SET SHIP:CONTROL:TRANSLATION TO rcs_cmd.
    LOCAL target_vs IS target_descent_rate(alt_agl).
    SET descent_pid:SETPOINT TO target_vs.
    LOCAL hover IS (SHIP:MASS * g_land) / thrust_available.
    LOCAL pid_correction IS descent_pid:UPDATE(TIME:SECONDS, vs_d3).
    SET thrott_cmd TO clamp(hover + pid_correction, 0, 1).
    IF TIME:SECONDS >= next_print {
        LOCAL steering_target IS SHIP:SRFRETROGRADE:FOREVECTOR.
        IF alt_agl < gear_deploy_alt {
            SET steering_target TO UP:FOREVECTOR.
        }
        LOCAL roll_ref IS d3_roll_reference(steering_target).
        LOCAL steer_err IS VANG(SHIP:FACING:FOREVECTOR, steering_target).
        LOCAL roll_err IS roll_error_deg(roll_ref).
        LOCAL roll_rate IS roll_rate_deg().
        log_line("  Alt: " + ROUND(alt_agl) + " m  |  vs: " + ROUND(vs_d3, 1) + " m/s  |  horiz: " + ROUND(horiz_dist) + " m  |  hspd: " + ROUND(hspd, 1) + " m/s  |  tgt_hspd: " + ROUND(tgt_hspd, 1) + " m/s  |  max_hspd: " + ROUND(max_hspd, 1) + " m/s  |  tgt: " + ROUND(target_vs, 1) + " m/s  |  thr: " + ROUND(thrott_cmd, 2) + "  |  rcs: " + ROUND(rcs_cmd:X, 2) + "," + ROUND(rcs_cmd:Y, 2) + "," + ROUND(rcs_cmd:Z, 2)).
        log_line("    facing: " + ROUND(SHIP:FACING:PITCH, 1) + "," + ROUND(SHIP:FACING:YAW, 1) + "," + ROUND(SHIP:FACING:ROLL, 1) + " deg  |  steer_err: " + ROUND(steer_err, 1) + " deg  |  roll_err: " + ROUND(roll_err, 1) + " deg  |  roll_rate: " + ROUND(roll_rate, 1) + " deg/s").
        SET next_print TO next_telemetry_time().
    }
    WAIT 0.
}

SET thrott_cmd TO 0.
SET SHIP:CONTROL:TRANSLATION TO V(0, 0, 0).
SET STEERINGMANAGER:MAXSTOPPINGTIME TO original_max_stopping_time.
UNLOCK THROTTLE.
UNLOCK STEERING.
RCS OFF.
SAS ON.
LOCAL land_offset IS VXCL(UP:FOREVECTOR, pad_geo:POSITION):MAG.
LOCAL land_hspd   IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE):MAG.
LOCAL flight_time IS TIME:SECONDS - start_time.
IF descent_aborted {
    log_line("--- Descent aborted ---").
    log_line("  vs: " + ROUND(SHIP:VERTICALSPEED, 2) + " m/s  |  horiz spd: " + ROUND(land_hspd, 1) + " m/s  |  status: " + SHIP:STATUS).
    log_line("  pad offset: " + ROUND(land_offset, 1) + " m  |  flight time: " + ROUND(flight_time) + " s").
} ELSE IF SHIP:STATUS = "SPLASHED" {
    log_line("--- Splashed down! ---").
    log_line("  vs: " + ROUND(SHIP:VERTICALSPEED, 2) + " m/s  |  horiz spd: " + ROUND(land_hspd, 1) + " m/s").
    log_line("  pad offset: " + ROUND(land_offset, 1) + " m  |  flight time: " + ROUND(flight_time) + " s").
} ELSE {
    log_line("--- Landed! ---").
    log_line("  vs: " + ROUND(SHIP:VERTICALSPEED, 2) + " m/s  |  horiz spd: " + ROUND(land_hspd, 1) + " m/s").
    log_line("  pad offset: " + ROUND(land_offset, 1) + " m  |  flight time: " + ROUND(flight_time) + " s").
}
transmit_log().
