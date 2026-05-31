// ============================================================
//  reentry.ks — atmospheric guidance and land handoff
// ============================================================
//  Manages the high-energy reentry profile, then hands off to
//  land.ks only after the vessel reaches the descent envelope.

// --- CONFIG (edit these) ------------------------------------
SET entry_telemetry_interval TO 20.
SET entry_brakes_enabled TO TRUE.
SET entry_brakes_deploy_alt_meters TO 70000.
SET entry_brakes_retract_speed_mps TO 1200.
SET entry_aoa_deg TO 10.
SET entry_aoa_retract_speed_mps TO 1200.
SET entry_orbit_retro_alt_meters TO 70000.
SET reentry_handoff_alt_meters TO 25000.
SET reentry_handoff_speed_mps TO 1200.
SET reentry_handoff_range_meters TO 10000.
SET reentry_handoff_tolerance_meters TO 2500.
SET land_script_path TO "1:/land.ks".
SET land_target_path TO "1:/land-target.json".
SET fallback_target_body TO "Kerbin".
SET fallback_target_lat TO -0.0972.
SET fallback_target_lng TO -74.5577.
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

FUNCTION target_miss_distance {
    PARAMETER impact_geo, target_geo.
    LOCAL impact_radial IS impact_geo:POSITION - SHIP:BODY:POSITION.
    LOCAL target_radial IS target_geo:POSITION - SHIP:BODY:POSITION.
    IF impact_radial:MAG <= 0 OR target_radial:MAG <= 0 {
        RETURN 999999999.
    }
    RETURN SHIP:BODY:RADIUS * VANG(impact_radial, target_radial) * 3.14159265 / 180.
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
            RETURN ANGLEAXIS(entry_aoa_command(), axis:NORMALIZED) * srfret.
        }
    }
    RETURN SHIP:SRFRETROGRADE.
}

FUNCTION handoff_along_distance {
    PARAMETER to_pad_h, horiz_vel.
    IF horiz_vel:MAG <= 1 {
        RETURN to_pad_h:MAG.
    }
    RETURN VDOT(to_pad_h, horiz_vel:NORMALIZED).
}

FUNCTION handoff_cross_distance {
    PARAMETER to_pad_h, horiz_vel.
    IF horiz_vel:MAG <= 1 {
        RETURN 0.
    }
    RETURN VXCL(horiz_vel:NORMALIZED, to_pad_h):MAG.
}

CLEARSCREEN.
log_line("=== reentry.ks ===").
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

LOCAL pad_geo IS LATLNG(target_lat, target_lng).
log_line("Target       : " + ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5) + " on " + target_body).
log_line("Target source: " + target_source).
log_line("Entry attitude: orbit retro above " + ROUND(entry_orbit_retro_alt_meters/1000, 1) + " km, surface retro below.").
log_line("Entry AoA    : " + entry_aoa_deg + " deg fixed, retract below " + ROUND(entry_aoa_retract_speed_mps) + " m/s.").
log_line("Handoff gate : " + ROUND(reentry_handoff_alt_meters/1000, 1) + " km alt  |  <= " + ROUND(reentry_handoff_speed_mps) + " m/s  |  " + ROUND(reentry_handoff_range_meters/1000, 1) + " km ahead of KSC +/- " + ROUND(reentry_handoff_tolerance_meters/1000, 1) + " km").

log_line("--- Preflight checks ---").
IF target_file_found {
    info_line("Landing target file", target_source).
} ELSE {
    warn_line("Landing target file", "missing; using " + target_source).
}
check_line(target_body = SHIP:BODY:NAME, "Target body", "target " + target_body + ", current " + SHIP:BODY:NAME).
check_line(entry_brakes_retract_speed_mps > 0, "Entry brake retract speed", ROUND(entry_brakes_retract_speed_mps) + " m/s").
check_line(entry_aoa_deg >= 0 AND entry_aoa_deg <= 90, "Entry AoA", ROUND(entry_aoa_deg, 1) + " deg").
check_line(entry_aoa_retract_speed_mps > 0, "Entry AoA retract speed", ROUND(entry_aoa_retract_speed_mps) + " m/s").
check_line(reentry_handoff_alt_meters > 0, "Reentry handoff altitude", ROUND(reentry_handoff_alt_meters/1000, 1) + " km").
check_line(reentry_handoff_speed_mps > 0, "Reentry handoff speed", ROUND(reentry_handoff_speed_mps) + " m/s").
check_line(reentry_handoff_range_meters > 0, "Reentry handoff range", ROUND(reentry_handoff_range_meters/1000, 1) + " km").
check_line(reentry_handoff_tolerance_meters >= 0, "Reentry handoff tolerance", ROUND(reentry_handoff_tolerance_meters/1000, 1) + " km").
info_line("Landing target coordinates", ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5)).
IF preflight_failed {
    abort_reentry("preflight checks failed.").
}
transmit_log().

SAS OFF.
LOCK THROTTLE TO 0.
LOCAL next_print IS TIME:SECONDS.

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
        } ELSE IF entry_brakes_deployed AND surface_speed <= entry_brakes_retract_speed_mps {
            BRAKES OFF.
            SET entry_brakes_deployed TO FALSE.
            log_line("  Entry brakes retracted  |  alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  speed: " + ROUND(surface_speed, 1) + " m/s").
        }
    }

    IF TIME:SECONDS >= next_print {
        LOCAL retro_mode IS "surface".
        LOCAL brake_mode IS "off".
        IF entry_brakes_deployed { SET brake_mode TO "on". }
        IF SHIP:ALTITUDE > entry_orbit_retro_alt_meters { SET retro_mode TO "orbit". }
        log_line("  Alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  spd: " + ROUND(surface_speed, 1) + " m/s  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s  |  brakes: " + brake_mode + "  |  retro: " + retro_mode + "  |  cmd: " + ROUND(entry_aoa_command(), 1) + " deg  |  actual: " + ROUND(actual_entry_aoa(), 1) + " deg").
        IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
            LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
            LOCAL tr_miss IS target_miss_distance(impact_geo, pad_geo).
            log_line("    TR impact: " + ROUND(impact_geo:LAT, 4) + ", " + ROUND(impact_geo:LNG, 4) + "  |  miss: " + ROUND(tr_miss/1000, 2) + " km").
        } ELSE {
            log_line("    TR impact: no prediction").
        }
        transmit_log().
        SET next_print TO TIME:SECONDS + entry_telemetry_interval.
    }
    WAIT 0.
}

LOCAL handoff_to_pad_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION).
LOCAL handoff_horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
LOCAL handoff_speed_mps_current IS SHIP:VELOCITY:SURFACE:MAG.
LOCAL handoff_along_meters IS handoff_along_distance(handoff_to_pad_h, handoff_horiz_vel).
LOCAL handoff_cross_meters IS handoff_cross_distance(handoff_to_pad_h, handoff_horiz_vel).
LOCAL handoff_range_error_meters IS ABS(handoff_along_meters - reentry_handoff_range_meters).
LOCAL handoff_ok IS SHIP:ALTITUDE <= reentry_handoff_alt_meters AND
                   handoff_speed_mps_current <= reentry_handoff_speed_mps AND
                   handoff_along_meters >= 0 AND
                   handoff_range_error_meters <= reentry_handoff_tolerance_meters AND
                   handoff_cross_meters <= reentry_handoff_tolerance_meters.
log_line("--- Reentry handoff ---").
log_line("  alt: " + ROUND(SHIP:ALTITUDE) + " m  |  spd: " + ROUND(handoff_speed_mps_current, 1) + " m/s  |  ahead: " + ROUND(handoff_along_meters) + " m  |  ahead_err: " + ROUND(handoff_range_error_meters) + " m  |  cross: " + ROUND(handoff_cross_meters) + " m").
transmit_log().

IF handoff_ok {
    IF entry_brakes_deployed {
        BRAKES OFF.
    }
    log_line("Running land script: " + land_script_path).
    RUNPATH(land_script_path).
}

abort_reentry("handoff outside envelope at " + ROUND(SHIP:ALTITUDE) + " m  |  spd " + ROUND(handoff_speed_mps_current, 1) + " m/s  |  ahead " + ROUND(handoff_along_meters) + " m  |  cross " + ROUND(handoff_cross_meters) + " m.").
