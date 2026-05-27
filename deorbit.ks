// ============================================================
//  deorbit.ks - Trajectories-guided deorbit to saved landing target
// ============================================================

// --- CONFIG (edit these) ------------------------------------
SET land_target_path TO "1:/land-target.json".
SET land_script_path TO "1:/land.ks".
SET fallback_target_body TO "Kerbin".
SET fallback_target_lat TO -0.0972.
SET fallback_target_lng TO -74.5577.
SET impact_tolerance_meters TO 10000.
SET aim_long_distance_meters TO 600000.
SET min_parking_alt_meters TO 70000.
SET max_parking_alt_meters TO 150000.
SET max_parking_eccentricity TO 0.1.
SET target_deorbit_phase_angle_deg TO 180.
SET deorbit_phase_start_tolerance_deg TO 5.
SET deorbit_phase_warp_rate TO 3.
SET slow_burn_miss_meters TO 10000.
SET min_deorbit_throttle TO 0.01.
SET max_deorbit_twr TO 0.5.
SET deorbit_miss_kp TO 0.00001.
SET burn_alignment_max_error_deg TO 1.
SET burn_alignment_timeout TO 45.
SET telemetry_interval TO 5.
SET burn_telemetry_interval TO 1.
SET log_path TO "deorbit.log".
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

FUNCTION next_telemetry_time {
    RETURN TIME:SECONDS + telemetry_interval.
}

FUNCTION next_burn_telemetry_time {
    RETURN TIME:SECONDS + burn_telemetry_interval.
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

FUNCTION abort_deorbit {
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

FUNCTION deorbit_burn_mps {
    PARAMETER initial_speed.
    RETURN MAX(0, initial_speed - SHIP:VELOCITY:ORBIT:MAG).
}

FUNCTION local_g {
    RETURN SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
}

FUNCTION twr_limited_throttle {
    PARAMETER target_twr.
    LOCAL max_thrust IS SHIP:AVAILABLETHRUST.
    IF max_thrust <= 0 {
        RETURN 0.
    }
    RETURN clamp((target_twr * SHIP:MASS * local_g()) / max_thrust, 0, 1).
}

FUNCTION orbit_retrograde_error {
    LOCAL retro_vec IS SHIP:VELOCITY:ORBIT:NORMALIZED * -1.
    RETURN VANG(SHIP:FACING:FOREVECTOR, retro_vec).
}

FUNCTION orbit_plane_projection {
    PARAMETER vec, plane_normal.
    RETURN vec - (plane_normal * VDOT(vec, plane_normal)).
}

FUNCTION target_phase_angle {
    PARAMETER target_geo.
    LOCAL ship_radial IS SHIP:POSITION - SHIP:BODY:POSITION.
    LOCAL target_radial IS target_geo:POSITION - SHIP:BODY:POSITION.
    LOCAL orbit_normal IS VCRS(ship_radial, SHIP:VELOCITY:ORBIT):NORMALIZED.
    LOCAL ship_plane IS orbit_plane_projection(ship_radial, orbit_normal).
    LOCAL target_plane IS orbit_plane_projection(target_radial, orbit_normal).

    IF ship_plane:MAG <= 0 OR target_plane:MAG <= 0 {
        RETURN -1.
    }

    SET ship_plane TO ship_plane:NORMALIZED.
    SET target_plane TO target_plane:NORMALIZED.
    LOCAL angle IS VANG(ship_plane, target_plane).
    IF VDOT(VCRS(ship_plane, target_plane), orbit_normal) < 0 {
        SET angle TO 360 - angle.
    }
    RETURN angle.
}

FUNCTION aim_long_target {
    PARAMETER target_geo, offset_meters.
    IF offset_meters <= 0 {
        RETURN target_geo.
    }

    LOCAL ship_radial IS SHIP:POSITION - SHIP:BODY:POSITION.
    LOCAL target_radial IS target_geo:POSITION - SHIP:BODY:POSITION.
    LOCAL orbit_normal IS VCRS(ship_radial, SHIP:VELOCITY:ORBIT):NORMALIZED.
    LOCAL offset_angle_deg IS offset_meters / SHIP:BODY:RADIUS * 180 / 3.14159265.
    LOCAL aim_radial IS ANGLEAXIS(offset_angle_deg, orbit_normal) * target_radial.
    RETURN SHIP:BODY:GEOPOSITIONOF(SHIP:BODY:POSITION + aim_radial).
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

FUNCTION warn_line {
    PARAMETER label, detail.
    log_line("[!] " + label + " - " + detail).
}

FUNCTION info_line {
    PARAMETER label, detail.
    log_line("[i] " + label + " - " + detail).
}

CLEARSCREEN.
log_line("=== deorbit.ks ===").
LOCAL preflight_failed IS FALSE.

LOCAL target_body IS fallback_target_body.
LOCAL target_lat IS fallback_target_lat.
LOCAL target_lng IS fallback_target_lng.
LOCAL target_source IS "fallback KSC launchpad".
IF EXISTS(land_target_path) {
    LOCAL target_data IS READJSON(land_target_path).
    SET target_body TO target_data["body"].
    SET target_lat TO target_data["lat"].
    SET target_lng TO target_data["lng"].
    SET target_source TO land_target_path.
} ELSE {
    warn_line("Landing target file", "missing " + land_target_path + "; using fallback KSC launchpad coordinates").
}

LOCAL pad_geo IS LATLNG(target_lat, target_lng).
LOCAL aim_geo IS aim_long_target(pad_geo, aim_long_distance_meters).
LOCAL deorbit_phase_angle IS target_phase_angle(aim_geo).
log_line("Landing target: " + ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5) + " on " + target_body).
log_line("Deorbit aim   : " + ROUND(aim_geo:LAT, 5) + ", " + ROUND(aim_geo:LNG, 5) + "  |  long by " + ROUND(aim_long_distance_meters/1000, 1) + " km").
log_line("Target source: " + target_source).

log_line("--- Preflight checks ---").
check_line(target_body = SHIP:BODY:NAME, "Target body", "target " + target_body + ", current " + SHIP:BODY:NAME).
check_line(SHIP:APOAPSIS >= min_parking_alt_meters AND SHIP:APOAPSIS <= max_parking_alt_meters, "Parking Ap", ROUND(SHIP:APOAPSIS/1000, 1) + " km within " + ROUND(min_parking_alt_meters/1000) + "-" + ROUND(max_parking_alt_meters/1000) + " km").
check_line(SHIP:PERIAPSIS >= min_parking_alt_meters AND SHIP:PERIAPSIS <= max_parking_alt_meters, "Parking Pe", ROUND(SHIP:PERIAPSIS/1000, 1) + " km within " + ROUND(min_parking_alt_meters/1000) + "-" + ROUND(max_parking_alt_meters/1000) + " km").
check_line(SHIP:OBT:ECCENTRICITY <= max_parking_eccentricity, "Parking eccentricity", ROUND(SHIP:OBT:ECCENTRICITY, 4) + " <= " + max_parking_eccentricity).
check_line(deorbit_phase_angle >= 0, "Deorbit phase angle", ROUND(deorbit_phase_angle, 1) + " deg; burn target " + ROUND(target_deorbit_phase_angle_deg) + " +/- " + ROUND(deorbit_phase_start_tolerance_deg) + " deg").
check_line(ADDONS:TR:AVAILABLE, "Trajectories addon", "AVAILABLE = " + ADDONS:TR:AVAILABLE).
check_line(SHIP:AVAILABLETHRUST > 0, "Available thrust", ROUND(SHIP:AVAILABLETHRUST, 1) + " kN").
check_line(min_deorbit_throttle >= 0 AND min_deorbit_throttle <= 1, "Minimum burn throttle", ROUND(min_deorbit_throttle, 2)).
check_line(max_deorbit_twr > 0, "Maximum burn TWR", max_deorbit_twr).
check_line(aim_long_distance_meters >= 0, "Aim-long offset", ROUND(aim_long_distance_meters/1000, 1) + " km").
check_line(deorbit_phase_start_tolerance_deg > 0, "Deorbit phase tolerance", ROUND(deorbit_phase_start_tolerance_deg, 1) + " deg").

IF preflight_failed {
    abort_deorbit("preflight checks failed.").
}

ADDONS:TR:SETTARGET(aim_geo).
IF ADDONS:TR:ISVERTWOTWO {
    SET ADDONS:TR:RETROGRADE TO TRUE.
}

SET deorbit_phase_angle TO target_phase_angle(aim_geo).
IF ABS(deorbit_phase_angle - target_deorbit_phase_angle_deg) > deorbit_phase_start_tolerance_deg {
    log_line("--- Warping to deorbit phase ---").
    log_line("  Current phase: " + ROUND(deorbit_phase_angle, 1) + " deg  |  target: " + ROUND(target_deorbit_phase_angle_deg, 1) + " +/- " + ROUND(deorbit_phase_start_tolerance_deg, 1) + " deg").
    UNTIL ABS(deorbit_phase_angle - target_deorbit_phase_angle_deg) <= deorbit_phase_start_tolerance_deg {
        SET WARP TO deorbit_phase_warp_rate.
        WAIT 1.
        SET deorbit_phase_angle TO target_phase_angle(aim_geo).
    }
    SET WARP TO 0.
    log_line("  Phase ready: " + ROUND(deorbit_phase_angle, 1) + " deg").
}

log_line("Orbit: Ap " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  Pe " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km  |  ecc " + ROUND(SHIP:OBT:ECCENTRICITY, 4)).
log_line("Limits: miss <= " + ROUND(impact_tolerance_meters) + " m  |  TWR <= " + max_deorbit_twr).

SAS OFF.
LOCK STEERING TO RETROGRADE.
LOCK THROTTLE TO 0.
log_line("--- Aligning for deorbit burn ---").
LOCAL align_start IS TIME:SECONDS.
LOCAL align_next_print IS TIME:SECONDS.
UNTIL orbit_retrograde_error() <= burn_alignment_max_error_deg {
    IF TIME:SECONDS - align_start > burn_alignment_timeout {
        abort_deorbit("could not align retrograde within " + burn_alignment_timeout + " s; error " + ROUND(orbit_retrograde_error(), 1) + " deg.").
    }
    IF TIME:SECONDS >= align_next_print {
        log_line("  retrograde error: " + ROUND(orbit_retrograde_error(), 1) + " deg  |  target <= " + burn_alignment_max_error_deg + " deg").
        SET align_next_print TO TIME:SECONDS + telemetry_interval.
    }
    WAIT 0.
}
log_line("  Aligned retrograde  |  error: " + ROUND(orbit_retrograde_error(), 1) + " deg").

LOCAL start_speed IS SHIP:VELOCITY:ORBIT:MAG.
LOCAL best_miss IS 999999999.
LOCAL had_impact IS FALSE.
LOCAL success IS FALSE.
LOCAL burn_used IS 0.
LOCAL deorbit_throttle IS 1.
LOCAL next_print IS TIME:SECONDS.
LOCAL worsening_logged IS FALSE.
LOCAL final_impact_lat IS 0.
LOCAL final_impact_lng IS 0.
LOCAL final_landing_miss IS 999999999.
LOCAL miss_pid IS PIDLOOP().
SET miss_pid:KP TO deorbit_miss_kp.
SET miss_pid:MINOUTPUT TO min_deorbit_throttle.
SET miss_pid:MAXOUTPUT TO 1.
SET miss_pid:SETPOINT TO 0.

log_line("--- Deorbit burn ---").
UNTIL success {
    IF SHIP:AVAILABLETHRUST <= 0 {
        abort_deorbit("no thrust available during deorbit burn.").
    }

    SET burn_used TO deorbit_burn_mps(start_speed).
    LOCAL max_twr_throttle IS twr_limited_throttle(max_deorbit_twr).

    IF ADDONS:TR:HASIMPACT {
        SET had_impact TO TRUE.
        LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
        LOCAL miss IS target_miss_distance(impact_geo, aim_geo).
        LOCAL landing_miss IS target_miss_distance(impact_geo, pad_geo).
        IF miss < best_miss {
            SET best_miss TO miss.
            SET final_impact_lat TO impact_geo:LAT.
            SET final_impact_lng TO impact_geo:LNG.
            SET final_landing_miss TO landing_miss.
            SET worsening_logged TO FALSE.
        } ELSE IF NOT worsening_logged AND best_miss < slow_burn_miss_meters AND miss > best_miss + impact_tolerance_meters {
            warn_line("Predicted miss worsening", "current " + ROUND(miss) + " m; best " + ROUND(best_miss) + " m; continuing burn").
            SET worsening_logged TO TRUE.
        }

        LOCAL miss_outside_tolerance IS MAX(0, miss - impact_tolerance_meters).
        LOCAL pid_throttle IS 0.

        IF miss <= impact_tolerance_meters {
            SET deorbit_throttle TO 0.
            SET success TO TRUE.
        } ELSE {
            SET pid_throttle TO miss_pid:UPDATE(TIME:SECONDS, -miss_outside_tolerance).
            SET deorbit_throttle TO clamp(pid_throttle, min_deorbit_throttle, max_twr_throttle).
        }

        IF TIME:SECONDS >= next_print {
            log_line("  burn: " + ROUND(burn_used, 1) + " m/s  |  aim miss: " + ROUND(miss) + " m  |  landing miss: " + ROUND(landing_miss/1000, 1) + " km  |  best: " + ROUND(best_miss) + " m").
            log_line("    pid: " + ROUND(pid_throttle, 3) + "  |  thr: " + ROUND(deorbit_throttle, 3) + "/" + ROUND(max_twr_throttle, 3) + "  |  impact: " + ROUND(impact_geo:LAT, 4) + ", " + ROUND(impact_geo:LNG, 4)).
            SET next_print TO next_burn_telemetry_time().
        }
    } ELSE {
        IF had_impact {
            abort_deorbit("Trajectories lost impact prediction after a usable prediction.").
        }
        SET deorbit_throttle TO max_twr_throttle.
        IF TIME:SECONDS >= next_print {
            log_line("  burn: " + ROUND(burn_used, 1) + " m/s  |  waiting for Trajectories impact prediction  |  thr cap: " + ROUND(max_twr_throttle, 2)).
            SET next_print TO next_burn_telemetry_time().
        }
    }

    LOCK THROTTLE TO deorbit_throttle.
    WAIT 0.
}

LOCK THROTTLE TO 0.
log_line("--- Deorbit achieved ---").
log_line("  burn: " + ROUND(burn_used, 1) + " m/s  |  predicted aim miss: " + ROUND(best_miss) + " m").
log_line("  final impact: " + ROUND(final_impact_lat, 5) + ", " + ROUND(final_impact_lng, 5) + "  |  predicted landing miss: " + ROUND(final_landing_miss/1000, 1) + " km").
transmit_log().

PRINT " ".
PRINT "Press any key to run land.ks, or ESC to abort.".
TERMINAL:INPUT:CLEAR().
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
LOCAL land_choice IS TERMINAL:INPUT:GETCHAR().
TERMINAL:INPUT:CLEAR().
IF UNCHAR(land_choice) = 27 {
    log_line("Land handoff aborted by user.").
    transmit_log().
    SHUTDOWN.
}

log_line("Running land script: " + land_script_path).
RUNPATH(land_script_path).
