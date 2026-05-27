// ============================================================
//  hop.ks — VTVL proof-of-concept vertical hop and landing
// ============================================================
//  Flies a straight-up hop, then performs a PID-guided powered
//  descent with active guidance back to launchpad.

// --- CONFIG (edit these) ------------------------------------
SET hop_altitude      TO 20000.
SET max_twr           TO 2.5.
SET gear_deploy_alt   TO 500.
SET telemetry_interval TO 5.
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
// Shared lateral miss corridor based on altitude above ground.
SET handoff_tolerance_slope TO 0.4.   // extra meters allowed per sqrt-meter AGL
// Keep correcting this fraction of predicted miss even inside the corridor.
// The corridor softens guidance effort; it does not create a no-correction dead zone.
SET handoff_min_effort_fraction TO 0.5.
// Minimum downward speed (m/s, negative) before engaging Descent Phase 1 steering.
// Avoids locking to SRFRETROGRADE at apoapsis when surface velocity is near-zero
// and the retrograde vector is undefined/unstable.
SET d1_entry_vs TO -50.
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
// Launch deflection — tilts the ascent trajectory to seed a lateral drift for testing.
// Set to 0 for a nominal straight-up hop.
SET launch_deflect_deg TO 1.
SET launch_deflect_hdg_deg TO 27.
// Terminal output is mirrored to this file with LOG.
SET log_path TO "hop.log".
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

LOCAL pad_geo  IS SHIP:GEOPOSITION.
LOCAL lat_tilt IS 0.
LOCAL lat_pid  IS PIDLOOP(d1_miss_kp, d1_miss_ki, d1_miss_kd,
                           -d1_lat_max_tilt * 2, d1_lat_max_tilt * 2).

CLEARSCREEN.
log_line("=== hop.ks ===").
log_line("Hop altitude : " + ROUND(hop_altitude/1000, 1) + " km  |  max TWR: " + max_twr).
log_line("Gear deploy  : " + gear_deploy_alt + " m AGL").
log_line("Launch deflect: " + launch_deflect_deg + " deg toward hdg " + launch_deflect_hdg_deg + " deg").
log_line(" ").
log_line("Press ENTER to begin launch sequence.").
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
TERMINAL:INPUT:GETCHAR().

SAS OFF.
RCS OFF.
GEAR OFF.
BRAKES OFF.
LOCK THROTTLE TO 0.
LOCK STEERING TO HEADING(launch_deflect_hdg_deg, 90 - launch_deflect_deg).

// Countdown
log_line("--- Countdown ---").
FROM {LOCAL i IS 5.} UNTIL i = 0 STEP {SET i TO i - 1.} DO {
    log_line("T-" + i + "...").
    WAIT 1.
}
log_line("Ignition!").
LOCK THROTTLE TO 1.0.
STAGE.
LOCAL start_time IS TIME:SECONDS.

// Vertical ascent
log_line("--- Vertical ascent to " + ROUND(hop_altitude/1000, 1) + " km Ap ---").
LOCAL next_print IS TIME:SECONDS.
UNTIL SHIP:APOAPSIS >= hop_altitude {
    LOCAL max_thrust IS SHIP:AVAILABLETHRUST.
    LOCAL weight IS SHIP:MASS * SHIP:BODY:MU /
                   (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    LOCAL twr_throttle IS (max_twr * weight) / max_thrust.
    LOCAL actual_throttle IS MIN(1.0, twr_throttle).
    LOCK THROTTLE TO actual_throttle.
    IF TIME:SECONDS >= next_print {
        LOCAL to_pad_h  IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
        LOCAL horiz_dist IS to_pad_h:MAG.
        log_line("  Alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  thr: " + ROUND(actual_throttle, 2) + "  |  horiz: " + ROUND(horiz_dist) + " m").
        SET next_print TO next_telemetry_time().
    }
    WAIT 0.
}

// Cutoff and coast
LOCK THROTTLE TO 0.
log_line("--- Coasting ---").
log_line("  Cutoff  |  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  Pe: " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km").
UNTIL SHIP:VERTICALSPEED < d1_entry_vs {
    IF TIME:SECONDS >= next_print {
        LOCAL to_pad_h  IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
        LOCAL horiz_dist IS to_pad_h:MAG.
        log_line("  Alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s  |  horiz: " + ROUND(horiz_dist) + " m").
        SET next_print TO next_telemetry_time().
    }
    WAIT 0.
}

// Descent Phase 1 — Descending: PID lateral guidance until 5 km handoff
LOCAL original_max_stopping_time IS STEERINGMANAGER:MAXSTOPPINGTIME.
SET STEERINGMANAGER:MAXSTOPPINGTIME TO descent_max_stopping_time.
LOCAL pred_to_pad IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
LOCK STEERING TO pad_steer_direction(pred_to_pad, lat_tilt, lat_min_horiz_dist).
log_line("--- DESCENT PHASE 1: Descending ---").
// Jettison fairing / pretend payload before descent so reentry aero matches
// the post-deployment vehicle.
STAGE.
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
UNTIL SHIP:STATUS = "LANDED" {
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
    log_line("  deflection: " + launch_deflect_deg + " deg hdg " + launch_deflect_hdg_deg).
} ELSE {
    log_line("--- Landed! ---").
    log_line("  vs: " + ROUND(SHIP:VERTICALSPEED, 2) + " m/s  |  horiz spd: " + ROUND(land_hspd, 1) + " m/s").
    log_line("  pad offset: " + ROUND(land_offset, 1) + " m  |  flight time: " + ROUND(flight_time) + " s").
    log_line("  deflection: " + launch_deflect_deg + " deg hdg " + launch_deflect_hdg_deg).
}
transmit_log().
