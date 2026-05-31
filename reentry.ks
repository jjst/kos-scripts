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
SET airbrake_pid_kp TO 0.003.
SET airbrake_base_angle TO 90.
SET airbrake_min_angle TO 0.
SET entry_orbit_retro_alt_meters TO 70000.
SET reentry_handoff_alt_meters TO 20000.
SET reentry_handoff_tr_miss_meters TO 2000.
SET land_script_path TO "1:/land_guided.ks".
SET land_unguided_script_path TO "1:/land_unguided.ks".
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

FUNCTION set_airbrake_angle {
    PARAMETER angle.
    FOR p IN SHIP:PARTSTAGGED("airbrake") {
        p:GETMODULE("ModuleAeroSurface"):SETFIELD("deploy angle", angle).
    }
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
log_line("Handoff gate : " + ROUND(reentry_handoff_alt_meters/1000, 1) + " km alt  |  TR miss <= " + ROUND(reentry_handoff_tr_miss_meters) + " m").

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
check_line(reentry_handoff_tr_miss_meters > 0, "Reentry handoff TR miss", ROUND(reentry_handoff_tr_miss_meters) + " m").
info_line("Landing target coordinates", ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5)).
IF preflight_failed {
    abort_reentry("preflight checks failed.").
}
transmit_log().

SAS OFF.
LOCK THROTTLE TO 0.
LOCAL next_print IS TIME:SECONDS.
LOCAL airbrake_pid IS PIDLOOP(airbrake_pid_kp).
SET airbrake_pid:MINOUTPUT TO -airbrake_base_angle.
SET airbrake_pid:MAXOUTPUT TO 0.
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
        } ELSE IF entry_brakes_deployed AND surface_speed <= entry_brakes_retract_speed_mps {
            BRAKES OFF.
            set_airbrake_angle(0).
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
            LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
            LOCAL to_pad_from_impact_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION) - VXCL(UP:FOREVECTOR, impact_geo:POSITION).
            LOCAL along_miss IS 0.
            IF horiz_vel:MAG > 1 {
                SET along_miss TO VDOT(to_pad_from_impact_h, horiz_vel:NORMALIZED).
            }
            LOCAL ab_correction IS airbrake_pid:UPDATE(TIME:SECONDS, along_miss).
            LOCAL ab_angle IS clamp(airbrake_base_angle + ab_correction, airbrake_min_angle, airbrake_base_angle).
            set_airbrake_angle(ab_angle).
            log_line("    TR impact: " + ROUND(impact_geo:LAT, 4) + ", " + ROUND(impact_geo:LNG, 4) + "  |  miss: " + ROUND(tr_miss/1000, 2) + " km  |  along: " + ROUND(along_miss/1000, 2) + " km  |  ab: " + ROUND(ab_angle, 1) + " deg").
        } ELSE {
            set_airbrake_angle(airbrake_base_angle).
            log_line("    TR impact: no prediction").
        }
        transmit_log().
        SET next_print TO TIME:SECONDS + entry_telemetry_interval.
    }
    WAIT 0.
}

LOCAL handoff_tr_miss IS 999999.
IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
    SET handoff_tr_miss TO target_miss_distance(ADDONS:TR:IMPACTPOS, pad_geo).
}
LOCAL handoff_ok IS handoff_tr_miss <= reentry_handoff_tr_miss_meters.
log_line("--- Reentry handoff ---").
log_line("  alt: " + ROUND(SHIP:ALTITUDE) + " m  |  spd: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s  |  TR miss: " + ROUND(handoff_tr_miss) + " m").
transmit_log().

IF handoff_ok {
    IF entry_brakes_deployed { BRAKES OFF. }
    set_airbrake_angle(0).
    log_line("Running land script: " + land_script_path).
    RUNPATH(land_script_path).
}

set_airbrake_angle(0).
log_line("Handoff outside envelope — falling back to unguided landing.").
log_line("  alt: " + ROUND(SHIP:ALTITUDE) + " m  |  spd: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s  |  TR miss: " + ROUND(handoff_tr_miss) + " m").
transmit_log().
RUNPATH(land_unguided_script_path).
