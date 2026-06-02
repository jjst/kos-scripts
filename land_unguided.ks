// ============================================================
//  land_unguided.ks — airbrake descent + PID-throttled landing burn
// ============================================================
//  Used when reentry handoff conditions aren't met. Airbrakes
//  retrograde until suicide_burn_alt_meters, then PID-controls
//  throttle to bring vertical speed to touchdown_speed.

// --- CONFIG (edit these) ------------------------------------
SET suicide_burn_safety_factor TO 1.25.
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
LOCK THROTTLE TO thrott_cmd.
LOCK STEERING TO SRFRETROGRADE.
SET next_print TO TIME:SECONDS.

UNTIL SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
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
transmit_log().
