// ============================================================
//  deorbit.ks - Trajectories-guided deorbit to saved landing target
// ============================================================

// --- CONFIG (edit these) ------------------------------------
SET land_target_path TO "1:/land-target.json".
SET land_script_path TO "1:/land.ks".
SET fallback_target_body TO "Kerbin".
SET fallback_target_lat TO -0.0972.
SET fallback_target_lng TO -74.5577.
SET impact_tolerance_meters TO 2000.
SET max_deorbit_burn_mps TO 200.
SET min_parking_alt_meters TO 70000.
SET max_parking_alt_meters TO 150000.
SET max_parking_eccentricity TO 0.1.
SET slow_burn_miss_meters TO 10000.
SET min_deorbit_throttle TO 0.1.
SET burn_alignment_max_error_deg TO 5.
SET burn_alignment_timeout TO 45.
SET telemetry_interval TO 5.
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

FUNCTION mark_telemetry_logged {
    SET next_print TO TIME:SECONDS + telemetry_interval.
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
    RETURN (impact_geo:POSITION - target_geo:POSITION):MAG.
}

FUNCTION deorbit_burn_mps {
    PARAMETER initial_speed.
    RETURN MAX(0, initial_speed - SHIP:VELOCITY:ORBIT:MAG).
}

FUNCTION orbit_retrograde_error {
    LOCAL retro_vec IS SHIP:VELOCITY:ORBIT:NORMALIZED * -1.
    RETURN VANG(SHIP:FACING:FOREVECTOR, retro_vec).
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
log_line("Target: " + ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5) + " on " + target_body).
log_line("Target source: " + target_source).

log_line("--- Preflight checks ---").
check_line(target_body = SHIP:BODY:NAME, "Target body", "target " + target_body + ", current " + SHIP:BODY:NAME).
check_line(SHIP:APOAPSIS >= min_parking_alt_meters AND SHIP:APOAPSIS <= max_parking_alt_meters, "Parking Ap", ROUND(SHIP:APOAPSIS/1000, 1) + " km within " + ROUND(min_parking_alt_meters/1000) + "-" + ROUND(max_parking_alt_meters/1000) + " km").
check_line(SHIP:PERIAPSIS >= min_parking_alt_meters AND SHIP:PERIAPSIS <= max_parking_alt_meters, "Parking Pe", ROUND(SHIP:PERIAPSIS/1000, 1) + " km within " + ROUND(min_parking_alt_meters/1000) + "-" + ROUND(max_parking_alt_meters/1000) + " km").
check_line(SHIP:OBT:ECCENTRICITY <= max_parking_eccentricity, "Parking eccentricity", ROUND(SHIP:OBT:ECCENTRICITY, 4) + " <= " + max_parking_eccentricity).
check_line(ADDONS:TR:AVAILABLE, "Trajectories addon", "AVAILABLE = " + ADDONS:TR:AVAILABLE).
check_line(SHIP:AVAILABLETHRUST > 0, "Available thrust", ROUND(SHIP:AVAILABLETHRUST, 1) + " kN").
check_line(max_deorbit_burn_mps > 0, "Burn cap", ROUND(max_deorbit_burn_mps) + " m/s").

IF preflight_failed {
    abort_deorbit("preflight checks failed.").
}

ADDONS:TR:SETTARGET(pad_geo).
IF ADDONS:TR:ISVERTWOTWO {
    SET ADDONS:TR:RETROGRADE TO TRUE.
}

log_line("Orbit: Ap " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  Pe " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km  |  ecc " + ROUND(SHIP:OBT:ECCENTRICITY, 4)).
log_line("Limits: miss <= " + ROUND(impact_tolerance_meters) + " m  |  burn <= " + ROUND(max_deorbit_burn_mps) + " m/s").

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

log_line("--- Deorbit burn ---").
UNTIL success {
    IF SHIP:AVAILABLETHRUST <= 0 {
        abort_deorbit("no thrust available during deorbit burn.").
    }

    SET burn_used TO deorbit_burn_mps(start_speed).
    IF burn_used > max_deorbit_burn_mps {
        abort_deorbit("deorbit burn exceeded " + ROUND(max_deorbit_burn_mps) + " m/s; best miss was " + ROUND(best_miss) + " m.").
    }

    IF ADDONS:TR:HASIMPACT {
        SET had_impact TO TRUE.
        LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
        LOCAL miss IS target_miss_distance(impact_geo, pad_geo).
        IF miss < best_miss {
            SET best_miss TO miss.
        } ELSE IF best_miss < slow_burn_miss_meters AND miss > best_miss + impact_tolerance_meters {
            abort_deorbit("predicted impact is worsening; best miss was " + ROUND(best_miss) + " m.").
        }

        IF miss <= impact_tolerance_meters {
            SET success TO TRUE.
        } ELSE {
            SET deorbit_throttle TO clamp(miss / slow_burn_miss_meters, min_deorbit_throttle, 1).
        }

        IF TIME:SECONDS >= next_print {
            log_line("  burn: " + ROUND(burn_used, 1) + " m/s  |  miss: " + ROUND(miss) + " m  |  best: " + ROUND(best_miss) + " m  |  thr: " + ROUND(deorbit_throttle, 2) + "  |  impact: " + ROUND(impact_geo:LAT, 4) + ", " + ROUND(impact_geo:LNG, 4)).
            mark_telemetry_logged().
        }
    } ELSE {
        IF had_impact {
            abort_deorbit("Trajectories lost impact prediction after a usable prediction.").
        }
        SET deorbit_throttle TO 1.
        IF TIME:SECONDS >= next_print {
            log_line("  burn: " + ROUND(burn_used, 1) + " m/s  |  waiting for Trajectories impact prediction.").
            mark_telemetry_logged().
        }
    }

    LOCK THROTTLE TO deorbit_throttle.
    WAIT 0.
}

LOCK THROTTLE TO 0.
log_line("--- Deorbit achieved ---").
log_line("  burn: " + ROUND(burn_used, 1) + " m/s  |  predicted miss: " + ROUND(best_miss) + " m").
transmit_log().

IF EXISTS(land_script_path) {
    log_line("Arming land script: " + land_script_path).
    RUNPATH(land_script_path).
} ELSE {
    abort_deorbit("land script not found: " + land_script_path).
}
