// ============================================================
//  hop.ks — VTVL proof-of-concept vertical hop and landing
// ============================================================
//  Flies a straight-up hop, then performs a PID-guided powered
//  descent with a gradual vertical-speed target down to ~3 m/s.

// --- CONFIG (edit these) ------------------------------------
SET hop_altitude      TO 10000.
SET max_twr           TO 2.5.
SET burn_safety       TO 1.2.
SET gear_deploy_alt   TO 200.
// Keep a small non-zero touchdown rate to avoid over-braking hover oscillation.
SET touchdown_speed   TO 3.
// PID gains for powered descent vertical-speed control.
// Increase Kp for faster response, Ki to reduce steady-state bias, Kd for damping.
SET descent_kp        TO 0.035.
SET descent_ki        TO 0.004.
SET descent_kd        TO 0.02.
// Fastest commanded descent rate at high altitude (m/s, negative = downward).
SET descent_min_rate  TO -35.
SET descent_profile_high_alt TO 400.
SET descent_profile_mid_alt  TO 200.
SET descent_profile_low_alt  TO 50.
SET descent_profile_flare_alt TO 10.
SET descent_profile_mid_rate TO -12.
SET descent_profile_low_rate TO -6.
SET descent_pid_min_output TO -0.6.
SET descent_pid_max_output TO 0.6.
// Limit steering aggressiveness to reduce rapid self-spin during descent.
SET descent_max_stopping_time TO 3.5.
// PID error deadband (m/s) to reduce tiny throttle chatter.
SET descent_pid_epsilon TO 0.15.
// Target descent speed during launchpad-steering phase (m/s, magnitude).
SET p5_target_speed TO 120.
// Proportional gain for Phase 5 speed hold.
SET p5_speed_kp TO 0.03.
// How strongly Phase 5 leans horizontally toward the pad (0 = pure retrograde).
SET p5_steer_gain TO 0.3.
// Minimum horizontal distance to pad (m) before applying lateral steering correction.
SET p5_min_horiz_dist TO 10.
// ------------------------------------------------------------

FUNCTION clamp {
    PARAMETER value, min_value, max_value.
    RETURN MIN(max_value, MAX(min_value, value)).
}

FUNCTION lerp {
    PARAMETER a, b, t.
    RETURN a + (b - a) * t.
}

FUNCTION pad_steer_direction {
    PARAMETER geo_target, steer_gain, min_horiz_dist.
    LOCAL horiz IS VXCL(UP:FOREVECTOR, geo_target:POSITION).
    LOCAL srfret IS SHIP:SRFRETROGRADE:FOREVECTOR.
    IF horiz:MAG > min_horiz_dist {
        RETURN (srfret + steer_gain * horiz:NORMALIZED):NORMALIZED.
    }
    RETURN srfret.
}

FUNCTION target_descent_rate {
    PARAMETER alt_agl.
    // Altitude-rate profile:
    // >descent_profile_high_alt: descent_min_rate,
    // descent_profile_mid_alt: descent_profile_mid_rate,
    // descent_profile_low_alt: descent_profile_low_rate,
    // descent_profile_flare_alt+: blend to touchdown target.
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

LOCAL pad_geo IS SHIP:GEOPOSITION.

CLEARSCREEN.
PRINT "=== hop.ks ===".
PRINT "Hop altitude : " + ROUND(hop_altitude/1000, 1) + " km  |  max TWR: " + max_twr.
PRINT "Burn safety  : " + burn_safety + "  |  gear at: " + gear_deploy_alt + " m AGL".
PRINT " ".
PRINT "Press ENTER to begin launch sequence.".
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
TERMINAL:INPUT:GETCHAR().

SAS OFF.
RCS OFF.
GEAR OFF.
BRAKES OFF.
LOCK THROTTLE TO 0.
LOCK STEERING TO UP.

// Phase 1 — Countdown
PRINT "--- Phase 1: Countdown ---".
FROM {LOCAL i IS 5.} UNTIL i = 0 STEP {SET i TO i - 1.} DO {
    PRINT "T-" + i + "...".
    WAIT 1.
}
PRINT "Ignition!".
LOCK THROTTLE TO 1.0.
STAGE.

// Phase 2 — Vertical ascent
PRINT "--- Phase 2: Vertical ascent to " + ROUND(hop_altitude/1000, 1) + " km Ap ---".
LOCAL next_print IS TIME:SECONDS.
UNTIL SHIP:APOAPSIS >= hop_altitude {
    LOCAL max_thrust IS SHIP:AVAILABLETHRUST.
    LOCAL weight IS SHIP:MASS * SHIP:BODY:MU /
                   (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    LOCAL twr_throttle IS (max_twr * weight) / max_thrust.
    LOCAL actual_throttle IS MIN(1.0, twr_throttle).
    LOCK THROTTLE TO actual_throttle.
    IF TIME:SECONDS >= next_print {
        PRINT "  Alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  thr: " + ROUND(actual_throttle, 2).
        SET next_print TO TIME:SECONDS + 2.
    }
    WAIT 0.
}

// Phase 3 — Cutoff and coast
LOCK THROTTLE TO 0.
PRINT "--- Phase 3: Coasting ---".
PRINT "  Cutoff  |  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  Pe: " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km".
SET next_print TO TIME:SECONDS.
UNTIL SHIP:VERTICALSPEED < 0 {
    IF TIME:SECONDS >= next_print {
        PRINT "  Alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s".
        SET next_print TO TIME:SECONDS + 2.
    }
    WAIT 0.
}

// Phase 4 — Descending: wait for sub-5 km handoff to powered descent
LOCAL original_max_stopping_time IS STEERINGMANAGER:MAXSTOPPINGTIME.
SET STEERINGMANAGER:MAXSTOPPINGTIME TO descent_max_stopping_time.
LOCK STEERING TO SRFRETROGRADE.
PRINT "--- Phase 4: Descending ---".
WAIT 3.
RCS ON.
BRAKES ON.
LOCAL gear_deployed IS FALSE.
SET next_print TO TIME:SECONDS.
UNTIL ALT:RADAR < 5000 {
    LOCAL alt_agl IS ALT:RADAR.

    IF NOT gear_deployed AND alt_agl < gear_deploy_alt {
        GEAR ON.
        SET gear_deployed TO TRUE.
        PRINT "  Gear down  |  alt: " + ROUND(alt_agl) + " m AGL".
    }

    IF TIME:SECONDS >= next_print {
        PRINT "  Alt: " + ROUND(alt_agl) + " m AGL  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s".
        SET next_print TO TIME:SECONDS + 2.
    }
    WAIT 0.
}
PRINT "  5 km handoff  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s".

// Phase 5 — Powered descent and launchpad steering
PRINT "--- Phase 5: Powered descent / launchpad steering ---".
LOCK THROTTLE TO 0.
LOCK STEERING TO pad_steer_direction(pad_geo, p5_steer_gain, p5_min_horiz_dist).
LOCAL p5_target_vs IS -(p5_target_speed).
LOCAL p5_burn_ready IS FALSE.
SET next_print TO TIME:SECONDS.
UNTIL p5_burn_ready {
    LOCAL alt_agl IS ALT:RADAR.
    LOCAL vs IS SHIP:VERTICALSPEED.
    LOCAL g_p5 IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.

    IF NOT gear_deployed AND alt_agl < gear_deploy_alt {
        GEAR ON.
        SET gear_deployed TO TRUE.
        PRINT "  Gear down (p5)  |  alt: " + ROUND(alt_agl) + " m AGL".
    }

    IF SHIP:AVAILABLETHRUST <= 0 {
        PRINT "  FATAL: no thrust in Phase 5 — forcing Phase 6.".
        SET p5_burn_ready TO TRUE.
    }
    IF NOT p5_burn_ready {
        LOCAL a_avail IS SHIP:AVAILABLETHRUST / SHIP:MASS.
        LOCAL hover IS (SHIP:MASS * g_p5) / SHIP:AVAILABLETHRUST.
        LOCAL speed_err IS p5_target_vs - vs.
        LOCAL p5_throttle IS clamp(hover + p5_speed_kp * speed_err, 0, 1).
        LOCK THROTTLE TO p5_throttle.

        LOCAL a_net IS a_avail - g_p5.
        IF a_net <= 0 {
            PRINT "  WARNING: a_net " + ROUND(a_net, 2) + " m/s^2 — forcing Phase 6.".
            SET p5_burn_ready TO TRUE.
        }
        IF NOT p5_burn_ready {
            LOCAL burn_dist IS (ABS(vs)^2 / (2 * a_net)) * burn_safety.
            IF alt_agl <= burn_dist {
                PRINT "  Phase 6 trigger  |  alt: " + ROUND(alt_agl) + " m  |  vs: " + ROUND(vs, 1) + " m/s".
                SET p5_burn_ready TO TRUE.
            }
        }
        IF NOT p5_burn_ready AND TIME:SECONDS >= next_print {
            LOCAL to_pad_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
            LOCAL horiz_dist IS to_pad_h:MAG.
            LOCAL hclos IS VDOT(VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE), to_pad_h:NORMALIZED).
            LOCAL tilt IS VANG(SHIP:FACING:FOREVECTOR, SHIP:SRFRETROGRADE:FOREVECTOR).
            PRINT "  Alt: " + ROUND(alt_agl) + " m  |  vs: " + ROUND(vs, 1) + " m/s  |  tgt: " + p5_target_vs + " m/s  |  thr: " + ROUND(p5_throttle, 2).
            PRINT "    horiz: " + ROUND(horiz_dist) + " m  |  pad_dist: " + ROUND(pad_geo:DISTANCE) + " m  |  hclos: " + ROUND(hclos, 1) + " m/s  |  tilt: " + ROUND(tilt, 1) + " deg".
            SET next_print TO TIME:SECONDS + 2.
        }
    }
    WAIT 0.
}

// Phase 6 — Landing burn
PRINT "--- Phase 6: Landing burn ---".
BRAKES ON.
LOCK STEERING TO SRFRETROGRADE.
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
SET next_print TO TIME:SECONDS.
UNTIL SHIP:STATUS = "LANDED" {
    LOCAL g_land IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    LOCAL alt_agl IS ALT:RADAR.
    IF NOT gear_deployed AND alt_agl < gear_deploy_alt {
        GEAR ON.
        SET gear_deployed TO TRUE.
        PRINT "  Gear down (powered)  |  alt: " + ROUND(alt_agl) + " m AGL".
    }
    LOCAL thrust_available IS SHIP:AVAILABLETHRUST.
    IF thrust_available <= 0 {
        PRINT "  FATAL: no thrust during powered descent  |  status: " + SHIP:STATUS + "  |  alt: " + ROUND(alt_agl) + " m  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s".
        SET descent_aborted TO TRUE.
        SET thrott_cmd TO 0.
        BREAK.
    }
    LOCAL target_vs IS target_descent_rate(alt_agl).
    SET descent_pid:SETPOINT TO target_vs.
    LOCAL hover IS (SHIP:MASS * g_land) / thrust_available.
    LOCAL pid_correction IS descent_pid:UPDATE(TIME:SECONDS, SHIP:VERTICALSPEED).
    SET thrott_cmd TO clamp(hover + pid_correction, 0, 1).
    IF TIME:SECONDS >= next_print {
        LOCAL to_pad_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
        LOCAL horiz_dist IS to_pad_h:MAG.
        LOCAL hclos IS VDOT(VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE), to_pad_h:NORMALIZED).
        PRINT "  Alt: " + ROUND(alt_agl) + " m  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s  |  tgt: " + ROUND(target_vs, 1) + " m/s  |  thr: " + ROUND(thrott_cmd, 2).
        PRINT "    horiz: " + ROUND(horiz_dist) + " m  |  pad_dist: " + ROUND(pad_geo:DISTANCE) + " m  |  hclos: " + ROUND(hclos, 1) + " m/s".
        SET next_print TO TIME:SECONDS + 1.
    }
    WAIT 0.
}

SET thrott_cmd TO 0.
SET STEERINGMANAGER:MAXSTOPPINGTIME TO original_max_stopping_time.
UNLOCK THROTTLE.
UNLOCK STEERING.
RCS OFF.
SAS ON.
IF descent_aborted {
    PRINT "--- Descent aborted ---".
    PRINT "  Final vs: " + ROUND(SHIP:VERTICALSPEED, 2) + " m/s  |  status: " + SHIP:STATUS.
} ELSE {
    PRINT "--- Landed! ---".
    PRINT "  Final vs: " + ROUND(SHIP:VERTICALSPEED, 2) + " m/s  |  status: " + SHIP:STATUS.
}
