// ============================================================
//  reentry.ks — atmospheric guidance and land handoff
// ============================================================
//  Manages the high-energy reentry profile, then hands off to
//  land_guided.ks only after the vessel reaches the descent envelope.

// --- CONFIG (edit these) ------------------------------------
SET entry_telemetry_interval TO 20.
SET entry_brakes_enabled TO TRUE.
SET entry_brakes_deploy_alt_meters TO 70000.
SET entry_brakes_retract_speed_mps TO 1200.
SET entry_aoa_deg TO 13.
SET entry_aoa_retract_speed_mps TO 1200.
SET airbrake_pid_kp TO 0.001.
SET airbrake_pid_ki TO 0.000001.
SET airbrake_pid_epsilon TO 500.
SET airbrake_pid_gain_ref_alt_meters TO 100000.
SET airbrake_base_angle TO 90.
SET airbrake_min_angle TO 0.
SET entry_orbit_retro_alt_meters TO 70000.
SET reentry_handoff_alt_meters TO 20000.
SET reentry_guided_land_alt_meters TO 5000.
SET reentry_handoff_speed_mps TO 1400.
SET reentry_handoff_tr_miss_meters TO 2500.
SET monitor_telemetry_interval TO 5.
SET monitor_throttle_pid_kp TO 0.0005.
SET monitor_throttle_pid_ki TO 0.00000005.
SET monitor_throttle_pid_max_throttle TO 1.0.
SET land_script_path TO "1:/land_guided.ks".
SET land_unguided_script_path TO "1:/land_unguided.ks".
SET pad_geo TO LATLNG(-0.0972, -74.5577).
SET log_path TO "reentry.log".
// ------------------------------------------------------------

FUNCTION clamp {
    PARAMETER value, min_value, max_value.
    RETURN MIN(max_value, MAX(min_value, value)).
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

FUNCTION abort_reentry {
    PARAMETER msg.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    log_line("ABORT: " + msg).
    transmit_log().
    WAIT 5.
    SHUTDOWN.
}

FUNCTION set_airbrake_angle {
    PARAMETER angle.
    FOR p IN SHIP:PARTSTAGGED("airbrake") {
        p:GETMODULE("ModuleAeroSurface"):SETFIELD("deploy angle", ROUND(angle)).
    }
}

FUNCTION target_miss_distance {
    PARAMETER impact_geo, target_geo.
    LOCAL impact_radial IS impact_geo:POSITION - SHIP:BODY:POSITION.
    LOCAL target_radial IS target_geo:POSITION - SHIP:BODY:POSITION.
    IF impact_radial:MAG <= 0 OR target_radial:MAG <= 0 {
        RETURN 999999999.
    }
    RETURN SHIP:BODY:RADIUS * VANG(impact_radial, target_radial) * CONSTANT:PI / 180.
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

FUNCTION entry_aoa_active {
    RETURN SHIP:ALTITUDE < entry_orbit_retro_alt_meters AND
           SHIP:VELOCITY:SURFACE:MAG > entry_aoa_retract_speed_mps.
}

FUNCTION entry_aoa_command {
    IF NOT entry_aoa_active() {
        RETURN 0.
    }
    RETURN entry_aoa_deg.
}

FUNCTION entry_retrograde_steering {
    IF SHIP:ALTITUDE > entry_orbit_retro_alt_meters {
        RETURN RETROGRADE.
    }
    IF entry_aoa_active() {
        LOCAL srfret IS SHIP:SRFRETROGRADE:FOREVECTOR.
        LOCAL axis IS VCRS(UP:FOREVECTOR, srfret).
        IF axis:MAG > 0.01 {
            LOCAL to_pad_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
            LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
            IF horiz_vel:MAG > 1 AND to_pad_h:MAG > 100 {
                LOCAL cross_to_pad IS VXCL(horiz_vel:NORMALIZED, to_pad_h).
                LOCAL blended IS axis:NORMALIZED + cross_to_pad / to_pad_h:MAG.
                LOCAL corrected IS VXCL(srfret, blended).
                IF corrected:MAG > 0.01 { SET axis TO corrected. }
            }
            RETURN ANGLEAXIS(entry_aoa_command(), axis:NORMALIZED) * srfret.
        }
    }
    RETURN SHIP:SRFRETROGRADE.
}


CLEARSCREEN.
log_line("=== reentry.ks ===").
LOCAL preflight_failed IS FALSE.
log_line("Target       : " + ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5) + " on " + pad_geo:BODY:NAME).
log_line("Entry attitude: orbit retro above " + ROUND(entry_orbit_retro_alt_meters/1000, 1) + " km, surface retro below.").
log_line("Entry AoA    : " + entry_aoa_deg + " deg fixed, retract below " + ROUND(entry_aoa_retract_speed_mps) + " m/s.").
log_line("Handoff gate : " + ROUND(reentry_handoff_alt_meters/1000, 1) + " km alt  |  spd <= " + ROUND(reentry_handoff_speed_mps) + " m/s  |  TR miss <= " + ROUND(reentry_handoff_tr_miss_meters) + " m  |  guided land at " + ROUND(reentry_guided_land_alt_meters/1000, 1) + " km").

log_line("--- Preflight checks ---").
check_line(pad_geo:BODY:NAME = SHIP:BODY:NAME, "Target body", "target " + pad_geo:BODY:NAME + ", current " + SHIP:BODY:NAME).
check_line(entry_brakes_retract_speed_mps > 0, "Entry brake retract speed", ROUND(entry_brakes_retract_speed_mps) + " m/s").
check_line(entry_aoa_deg >= 0 AND entry_aoa_deg <= 90, "Entry AoA", ROUND(entry_aoa_deg, 1) + " deg").
check_line(entry_aoa_retract_speed_mps > 0, "Entry AoA retract speed", ROUND(entry_aoa_retract_speed_mps) + " m/s").
check_line(reentry_handoff_alt_meters > 0, "Reentry handoff altitude", ROUND(reentry_handoff_alt_meters/1000, 1) + " km").
check_line(reentry_handoff_tr_miss_meters > 0, "Reentry handoff TR miss", ROUND(reentry_handoff_tr_miss_meters) + " m").
info_line("Landing target coordinates", ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5)).
IF preflight_failed {
    abort_reentry("preflight checks failed.").
}
transmit_log().

SAS OFF.
LOCAL monitor_throttle IS 0.
LOCK THROTTLE TO monitor_throttle.
LOCAL next_print IS TIME:SECONDS.
LOCAL airbrake_pid IS PIDLOOP(airbrake_pid_kp, airbrake_pid_ki, 0, -airbrake_base_angle, 0, airbrake_pid_epsilon).
SET airbrake_pid:SETPOINT TO 0.

LOCK STEERING TO entry_retrograde_steering().
log_line("--- ENTRY GUIDANCE ---").
LOCAL entry_brakes_deployed IS entry_brakes_enabled AND SHIP:VELOCITY:SURFACE:MAG > entry_brakes_retract_speed_mps.
IF entry_brakes_deployed {
    BRAKES ON.
    log_line("  Entry brakes armed  |  speed: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s").
}
UNTIL SHIP:ALTITUDE <= reentry_handoff_alt_meters {
    LOCAL surface_speed IS SHIP:VELOCITY:SURFACE:MAG.

    IF entry_brakes_enabled {
        IF NOT entry_brakes_deployed AND SHIP:ALTITUDE < entry_brakes_deploy_alt_meters AND surface_speed > entry_brakes_retract_speed_mps {
            BRAKES ON.
            SET entry_brakes_deployed TO TRUE.
            log_line("  Entry brakes deployed  |  alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  speed: " + ROUND(surface_speed, 1) + " m/s").
        }
    }

    LOCAL ab_angle IS airbrake_base_angle.
    IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
        LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
        LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
        LOCAL to_pad_from_impact_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION) - VXCL(UP:FOREVECTOR, impact_geo:POSITION).
        LOCAL along_miss IS 0.
        IF horiz_vel:MAG > 1 {
            SET along_miss TO VDOT(to_pad_from_impact_h, horiz_vel:NORMALIZED).
        }
        SET airbrake_pid:KP TO airbrake_pid_kp * (airbrake_pid_gain_ref_alt_meters / MAX(SHIP:ALTITUDE, reentry_handoff_alt_meters)).
        LOCAL ab_correction IS airbrake_pid:UPDATE(TIME:SECONDS, along_miss).
        SET ab_angle TO clamp(airbrake_base_angle + ab_correction, airbrake_min_angle, airbrake_base_angle).
    }
    set_airbrake_angle(ab_angle).

    IF TIME:SECONDS >= next_print {
        log_line("  Alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  spd: " + ROUND(surface_speed, 1) + " m/s  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s  |  cmd: " + ROUND(entry_aoa_command(), 1) + " deg  |  actual: " + ROUND(actual_entry_aoa(), 1) + " deg").
        IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
            LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
            LOCAL tr_miss IS target_miss_distance(impact_geo, pad_geo).
            LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
            LOCAL to_pad_from_impact_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION) - VXCL(UP:FOREVECTOR, impact_geo:POSITION).
            LOCAL along_miss IS 0.
            IF horiz_vel:MAG > 1 {
                SET along_miss TO VDOT(to_pad_from_impact_h, horiz_vel:NORMALIZED).
            }
            log_line("    TR impact: " + ROUND(impact_geo:LAT, 4) + ", " + ROUND(impact_geo:LNG, 4) + "  |  miss: " + ROUND(tr_miss/1000, 2) + " km  |  along: " + ROUND(along_miss/1000, 2) + " km  |  ab: " + ROUND(ab_angle, 1) + " deg").
        } ELSE {
            log_line("    TR impact: no prediction").
        }
        transmit_log().
        SET next_print TO TIME:SECONDS + entry_telemetry_interval.
    }
    WAIT 0.
}

LOCAL handoff_speed IS SHIP:VELOCITY:SURFACE:MAG.
LOCAL handoff_tr_miss IS 999999.
IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
    SET handoff_tr_miss TO target_miss_distance(ADDONS:TR:IMPACTPOS, pad_geo).
}
LOCAL guide_ok IS handoff_speed <= reentry_handoff_speed_mps AND handoff_tr_miss <= reentry_handoff_tr_miss_meters.
log_line("--- Reentry handoff gate ---").
log_line("  alt: " + ROUND(SHIP:ALTITUDE) + " m  |  spd: " + ROUND(handoff_speed, 1) + " m/s  |  TR miss: " + ROUND(handoff_tr_miss) + " m").
transmit_log().

IF NOT guide_ok {
    set_airbrake_angle(90).
    log_line("Outside guided envelope at gate — falling back to unguided landing.").
    log_line("  spd: " + ROUND(handoff_speed, 1) + " m/s (limit " + ROUND(reentry_handoff_speed_mps) + ")  |  TR miss: " + ROUND(handoff_tr_miss) + " m (limit " + ROUND(reentry_handoff_tr_miss_meters) + " m)").
    transmit_log().
    RUNPATH(land_unguided_script_path).
}

log_line("Guide condition met at gate — monitoring to " + ROUND(reentry_guided_land_alt_meters/1000, 1) + " km.").
LOCAL monitor_thr_pid IS PIDLOOP(monitor_throttle_pid_kp, monitor_throttle_pid_ki, 0, 0, monitor_throttle_pid_max_throttle).
SET monitor_thr_pid:SETPOINT TO 0.
SET next_print TO TIME:SECONDS.

UNTIL SHIP:ALTITUDE <= reentry_guided_land_alt_meters {
    LOCAL surface_speed IS SHIP:VELOCITY:SURFACE:MAG.

    LOCAL monitor_tr_miss IS 999999.
    LOCAL along_miss IS 0.
    IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
        LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
        SET monitor_tr_miss TO target_miss_distance(impact_geo, pad_geo).
        LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
        LOCAL to_pad_from_impact_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION) - VXCL(UP:FOREVECTOR, impact_geo:POSITION).
        IF horiz_vel:MAG > 1 {
            SET along_miss TO VDOT(to_pad_from_impact_h, horiz_vel:NORMALIZED).
        }
        IF entry_brakes_deployed {
            SET airbrake_pid:KP TO airbrake_pid_kp * (airbrake_pid_gain_ref_alt_meters / MAX(SHIP:ALTITUDE, reentry_handoff_alt_meters)).
            LOCAL ab_correction IS airbrake_pid:UPDATE(TIME:SECONDS, along_miss).
            set_airbrake_angle(clamp(airbrake_base_angle + ab_correction, airbrake_min_angle, airbrake_base_angle)).
        }
    }

    SET monitor_throttle TO monitor_thr_pid:UPDATE(TIME:SECONDS, along_miss).

    IF monitor_tr_miss > reentry_handoff_tr_miss_meters {
        SET monitor_throttle TO 0.
        set_airbrake_angle(90).
        log_line("Guide condition lost (TR miss) — falling back to unguided landing.").
        log_line("  alt: " + ROUND(SHIP:ALTITUDE) + " m  |  TR miss: " + ROUND(monitor_tr_miss) + " m (limit " + ROUND(reentry_handoff_tr_miss_meters) + " m)").
        transmit_log().
        RUNPATH(land_unguided_script_path).
    }

    IF TIME:SECONDS >= next_print {
        log_line("  [monitor] alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  spd: " + ROUND(surface_speed, 1) + " m/s  |  TR miss: " + ROUND(monitor_tr_miss) + " m  |  along: " + ROUND(along_miss) + " m  |  thr: " + ROUND(monitor_throttle, 3)).
        transmit_log().
        SET next_print TO TIME:SECONDS + monitor_telemetry_interval.
    }

    WAIT 0.
}

SET monitor_throttle TO 0.
set_airbrake_angle(90).
log_line("Handing off to guided landing at " + ROUND(SHIP:ALTITUDE) + " m: " + land_script_path).
transmit_log().
RUNPATH(land_script_path).
