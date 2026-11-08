// ============================================================
//  deorbit.ks - Trajectories-guided deorbit to landing target
// ============================================================

// Current operational defaults. Historical proxy/Trajectories-miss runs remain
// available by passing their modes explicitly, but are not the safe default.
PARAMETER reentry_airbrake_control_mode IS "fixed60".
PARAMETER trajectories_profile_id IS "matched10".
PARAMETER custom_fixed_airbrake_angle_deg IS -1.
PARAMETER deorbit_guidance_mode IS "entry_fpa29".

// --- CONFIG (edit these) ------------------------------------
SET reentry_script_path TO "1:/reentry.ks".
SET pad_geo TO LATLNG(-0.0972, -74.5577).
SET min_parking_alt_meters TO 70000.
SET max_parking_alt_meters TO 150000.
SET max_parking_eccentricity TO 0.1.
SET reentry_handoff_alt_meters TO 70000.
SET entry_interface_alt_meters TO 70000.
SET target_entry_fpa_down_deg TO 2.9.
SET entry_fpa_tolerance_deg TO 0.03.
SET entry_fpa_throttle_kp TO 0.5.
// The 100 km reference orbit needs about 52.6 m/s and the configured 150 km
// parking ceiling needs about 73.2 m/s. These independent guards stop a bad or
// stale future-orbit prediction from ever turning into a runaway burn.
SET max_entry_fpa_burn_mps TO 90.
SET max_entry_fpa_burn_seconds TO 45.
SET minimum_entry_fpa_periapsis_meters TO 25000.
SET entry_fpa_prediction_regression_tolerance_deg TO 0.05.
// Calibration test: corrected-corridor fixed-60/fixed-90 runs at 180 deg landed
// 47.7/62.0 km short. Their midpoint is about 5.2 Kerbin degrees, so delaying
// the burn to 175 deg should put the pad near the middle of their authority.
// Replace this empirical constant with the general phase solver tracked on GitHub.
SET target_deorbit_phase_angle_deg TO 175.
SET deorbit_phase_start_tolerance_deg TO 1.
SET deorbit_phase_warp_rate TO 4.
SET slow_burn_miss_meters TO 10000.
SET min_deorbit_throttle TO 0.01.
SET max_deorbit_twr TO 0.5.
SET deorbit_miss_kp TO 0.00001.
SET burn_alignment_max_error_deg TO 1.
SET burn_alignment_timeout TO 90.
SET telemetry_interval TO 5.
SET warp_telemetry_interval TO 60.
SET burn_telemetry_interval TO 1.
SET reentry_handoff_telemetry_interval TO 30.
SET reentry_coast_warp_rate TO 3.
// Trajectories does not include deployed airbrake drag in its prediction.
// These are therefore a calibrated prediction profile, not the AoA commands
// flown by reentry.ks. The higher low/final values act as a drag proxy for the
// variable airbrake deployment used during the real descent.
SET tr_descent_entry_aoa_deg TO 10.
SET tr_descent_high_aoa_deg TO 10.
SET tr_descent_low_aoa_deg TO 15.
SET tr_descent_final_aoa_deg TO 15.
IF trajectories_profile_id = "matched10" {
    // Trajectories' positive retrograde offset is on the opposite side from
    // reentry.ks's positive, belly-first AoA. A -10 deg retrograde profile
    // produces the same planned facing vector as the script's +10 deg command.
    SET tr_descent_entry_aoa_deg TO -10.
    SET tr_descent_high_aoa_deg TO -10.
    SET tr_descent_low_aoa_deg TO -10.
    SET tr_descent_final_aoa_deg TO -10.
}
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
    RETURN SHIP:BODY:RADIUS * VANG(impact_radial, target_radial) * CONSTANT:PI / 180.
}

// Predict the descending surface-relative flight-path angle at atmospheric
// interface from the current osculating orbit. Derive the crossing state from
// specific orbital energy and angular momentum instead of POSITIONAT/
// VELOCITYAT: the latter returned a zero downward component during a live
// finite burn even after periapsis had crossed the interface. The surface
// correction projects body rotation along the orbit direction. This is exact
// for the near-equatorial Kerbin test orbit used by the airbrake experiment.
FUNCTION predict_entry_fpa_down_deg_at {
    PARAMETER interface_altitude_m.
    LOCAL interface_radius IS SHIP:BODY:RADIUS + interface_altitude_m.
    IF SHIP:ALTITUDE <= interface_altitude_m {
        RETURN -1.
    }
    IF SHIP:OBT:PERIAPSIS >= interface_altitude_m {
        RETURN 0.
    }

    LOCAL position_vec IS SHIP:POSITION - SHIP:BODY:POSITION.
    LOCAL current_radius IS position_vec:MAG.
    LOCAL orbit_velocity IS SHIP:VELOCITY:ORBIT.
    IF current_radius <= 0 OR orbit_velocity:MAG <= 0 {
        RETURN -1.
    }

    LOCAL speed_squared IS orbit_velocity:MAG * orbit_velocity:MAG.
    LOCAL specific_energy IS speed_squared / 2 - SHIP:BODY:MU / current_radius.
    LOCAL interface_speed_squared IS 2 * (specific_energy + SHIP:BODY:MU / interface_radius).
    LOCAL angular_momentum_vec IS VCRS(position_vec, orbit_velocity).
    LOCAL angular_momentum IS angular_momentum_vec:MAG.
    IF interface_speed_squared <= 0 OR angular_momentum <= 0 {
        RETURN -1.
    }

    LOCAL interface_tangential_speed IS angular_momentum / interface_radius.
    LOCAL interface_radial_speed_squared IS interface_speed_squared - interface_tangential_speed^2.
    IF interface_radial_speed_squared <= 0 {
        RETURN 0.
    }

    LOCAL rotation_along_orbit IS 0.
    IF SHIP:BODY:ANGULARVEL:MAG > 0 {
        SET rotation_along_orbit TO VDOT(SHIP:BODY:ANGULARVEL, angular_momentum_vec:NORMALIZED) * interface_radius.
    }
    LOCAL surface_tangential_speed IS interface_tangential_speed - rotation_along_orbit.
    LOCAL interface_radial_speed_down IS SQRT(interface_radial_speed_squared).
    RETURN ARCTAN2(interface_radial_speed_down, MAX(ABS(surface_tangential_speed), 0.001)).
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

LOCAL deorbit_phase_angle IS target_phase_angle(pad_geo).
log_line("Landing target: " + ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5) + " on " + pad_geo:BODY:NAME).

log_line("--- Preflight checks ---").
check_line(pad_geo:BODY:NAME = SHIP:BODY:NAME, "Target body", "target " + pad_geo:BODY:NAME + ", current " + SHIP:BODY:NAME).
check_line(reentry_airbrake_control_mode = "off" OR reentry_airbrake_control_mode = "fixed" OR reentry_airbrake_control_mode = "fixed30" OR reentry_airbrake_control_mode = "fixed45" OR reentry_airbrake_control_mode = "fixed50" OR reentry_airbrake_control_mode = "fixed60" OR reentry_airbrake_control_mode = "fixed90" OR reentry_airbrake_control_mode = "pid", "Reentry airbrake mode", reentry_airbrake_control_mode).
check_line(reentry_airbrake_control_mode <> "fixed" OR (custom_fixed_airbrake_angle_deg >= 0 AND custom_fixed_airbrake_angle_deg <= 90), "Custom fixed airbrake angle", ROUND(custom_fixed_airbrake_angle_deg, 2) + " deg within 0-90").
check_line(trajectories_profile_id = "proxy" OR trajectories_profile_id = "matched10", "Trajectories profile", trajectories_profile_id).
check_line(deorbit_guidance_mode = "trajectories_miss" OR deorbit_guidance_mode = "entry_fpa29", "Deorbit guidance mode", deorbit_guidance_mode).
check_line(SHIP:APOAPSIS >= min_parking_alt_meters AND SHIP:APOAPSIS <= max_parking_alt_meters, "Parking Ap", ROUND(SHIP:APOAPSIS/1000, 1) + " km within " + ROUND(min_parking_alt_meters/1000) + "-" + ROUND(max_parking_alt_meters/1000) + " km").
check_line(SHIP:PERIAPSIS >= min_parking_alt_meters AND SHIP:PERIAPSIS <= max_parking_alt_meters, "Parking Pe", ROUND(SHIP:PERIAPSIS/1000, 1) + " km within " + ROUND(min_parking_alt_meters/1000) + "-" + ROUND(max_parking_alt_meters/1000) + " km").
check_line(SHIP:OBT:ECCENTRICITY <= max_parking_eccentricity, "Parking eccentricity", ROUND(SHIP:OBT:ECCENTRICITY, 4) + " <= " + max_parking_eccentricity).
check_line(deorbit_phase_angle >= 0, "Deorbit phase angle", ROUND(deorbit_phase_angle, 1) + " deg; burn target " + ROUND(target_deorbit_phase_angle_deg) + " +/- " + ROUND(deorbit_phase_start_tolerance_deg) + " deg").
check_line(ADDONS:TR:AVAILABLE AND ADDONS:TR:ISVERTWOFOUR, "Trajectories 2.4.0+", "AVAILABLE = " + ADDONS:TR:AVAILABLE).
check_line(SHIP:AVAILABLETHRUST > 0, "Available thrust", ROUND(SHIP:AVAILABLETHRUST, 1) + " kN").
check_line(min_deorbit_throttle >= 0 AND min_deorbit_throttle <= 1, "Minimum burn throttle", ROUND(min_deorbit_throttle, 2)).
check_line(max_deorbit_twr > 0, "Maximum burn TWR", max_deorbit_twr).
check_line(reentry_handoff_alt_meters > 0, "Reentry handoff altitude", ROUND(reentry_handoff_alt_meters/1000, 1) + " km").
check_line(deorbit_phase_start_tolerance_deg > 0, "Deorbit phase tolerance", ROUND(deorbit_phase_start_tolerance_deg, 1) + " deg").
check_line(entry_interface_alt_meters > 0, "Entry interface altitude", ROUND(entry_interface_alt_meters/1000, 1) + " km").
check_line(target_entry_fpa_down_deg > 0 AND target_entry_fpa_down_deg < 10, "Entry flight-path target", ROUND(target_entry_fpa_down_deg, 2) + " deg downward").
check_line(entry_fpa_tolerance_deg > 0, "Entry flight-path tolerance", ROUND(entry_fpa_tolerance_deg, 3) + " deg").
check_line(max_entry_fpa_burn_mps > 0, "Entry-FPA burn delta-v guard", ROUND(max_entry_fpa_burn_mps, 1) + " m/s").
check_line(max_entry_fpa_burn_seconds > 0, "Entry-FPA burn time guard", ROUND(max_entry_fpa_burn_seconds, 1) + " s").
check_line(minimum_entry_fpa_periapsis_meters > 0 AND minimum_entry_fpa_periapsis_meters < entry_interface_alt_meters, "Entry-FPA periapsis guard", ROUND(minimum_entry_fpa_periapsis_meters/1000, 1) + " km").
info_line("Descent profile AoA", "entry " + tr_descent_entry_aoa_deg + " / high " + tr_descent_high_aoa_deg + " / low " + tr_descent_low_aoa_deg + " / final " + tr_descent_final_aoa_deg + " deg").
IF deorbit_guidance_mode = "entry_fpa29" {
    info_line("Corridor target", ROUND(target_entry_fpa_down_deg, 2) + " deg downward at " + ROUND(entry_interface_alt_meters/1000, 1) + " km; phase controls downrange").
}

IF preflight_failed {
    abort_deorbit("preflight checks failed.").
}

ADDONS:TR:SETTARGET(pad_geo).
ADDONS:TR:RESETDESCENTPROFILE(0).
SET ADDONS:TR:DESCENTANGLES TO LIST(tr_descent_entry_aoa_deg, tr_descent_high_aoa_deg, tr_descent_low_aoa_deg, tr_descent_final_aoa_deg).
SET ADDONS:TR:DESCENTGRADES TO LIST(TRUE, TRUE, TRUE, TRUE).
SET ADDONS:TR:DESCENTMODES TO LIST(TRUE, TRUE, TRUE, TRUE).

SET deorbit_phase_angle TO target_phase_angle(pad_geo).
IF ABS(deorbit_phase_angle - target_deorbit_phase_angle_deg) > deorbit_phase_start_tolerance_deg {
    log_line("--- Warping to deorbit phase ---").
    log_line("  Current phase: " + ROUND(deorbit_phase_angle, 1) + " deg  |  target: " + ROUND(target_deorbit_phase_angle_deg, 1) + " +/- " + ROUND(deorbit_phase_start_tolerance_deg, 1) + " deg").
    LOCAL phase_next_print IS TIME:SECONDS.
    UNTIL ABS(deorbit_phase_angle - target_deorbit_phase_angle_deg) <= deorbit_phase_start_tolerance_deg {
        SET WARP TO deorbit_phase_warp_rate.
        IF TIME:SECONDS >= phase_next_print {
            log_line("  Phase: " + ROUND(deorbit_phase_angle, 1) + " deg  |  target: " + ROUND(target_deorbit_phase_angle_deg, 1) + " +/- " + ROUND(deorbit_phase_start_tolerance_deg, 1) + " deg").
            SET phase_next_print TO TIME:SECONDS + warp_telemetry_interval.
        }
        WAIT 1.
        SET deorbit_phase_angle TO target_phase_angle(pad_geo).
    }
    SET WARP TO 0.
    log_line("  Phase ready: " + ROUND(deorbit_phase_angle, 1) + " deg").
}

log_line("Orbit: Ap " + ROUND(SHIP:APOAPSIS/1000, 1) + " km  |  Pe " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km  |  ecc " + ROUND(SHIP:OBT:ECCENTRICITY, 4)).
IF deorbit_guidance_mode = "entry_fpa29" {
    log_line("Limits: entry FPA " + ROUND(target_entry_fpa_down_deg, 2) + " +/- " + ROUND(entry_fpa_tolerance_deg, 3) + " deg at " + ROUND(entry_interface_alt_meters/1000, 1) + " km  |  TWR <= " + max_deorbit_twr).
} ELSE {
    log_line("Limits: miss <= " + ROUND(slow_burn_miss_meters) + " m  |  TWR <= " + max_deorbit_twr).
}

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

// Alignment takes real time after the warp gate. Capture the phase at actual
// ignition so telemetry can distinguish phase calibration runs precisely.
LOCAL actual_deorbit_burn_phase_angle_deg IS target_phase_angle(pad_geo).
log_line("  Burn phase: " + ROUND(actual_deorbit_burn_phase_angle_deg, 3) + " deg  |  gate target: " + ROUND(target_deorbit_phase_angle_deg, 3) + " deg").

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
LOCAL achieved_entry_fpa_down_deg IS 0.
LOCAL raw_entry_fpa_down_deg IS 0.
LOCAL next_entry_fpa_prediction IS TIME:SECONDS.
LOCAL entry_fpa_prediction_regression_logged IS FALSE.
LOCAL burn_start_time IS TIME:SECONDS.
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

    IF deorbit_guidance_mode = "entry_fpa29" {
        IF burn_used >= max_entry_fpa_burn_mps {
            abort_deorbit("entry-FPA delta-v guard reached at " + ROUND(burn_used, 1) + " m/s; latched/raw FPA " + ROUND(achieved_entry_fpa_down_deg, 3) + "/" + ROUND(raw_entry_fpa_down_deg, 3) + " deg, Pe " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km.").
        }
        IF TIME:SECONDS - burn_start_time >= max_entry_fpa_burn_seconds {
            abort_deorbit("entry-FPA time guard reached after " + ROUND(TIME:SECONDS - burn_start_time, 1) + " s; burn " + ROUND(burn_used, 1) + " m/s, latched/raw FPA " + ROUND(achieved_entry_fpa_down_deg, 3) + "/" + ROUND(raw_entry_fpa_down_deg, 3) + " deg.").
        }
        IF SHIP:PERIAPSIS <= minimum_entry_fpa_periapsis_meters {
            abort_deorbit("entry-FPA periapsis guard reached at " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km; burn " + ROUND(burn_used, 1) + " m/s, latched/raw FPA " + ROUND(achieved_entry_fpa_down_deg, 3) + "/" + ROUND(raw_entry_fpa_down_deg, 3) + " deg.").
        }
        IF TIME:SECONDS >= next_entry_fpa_prediction {
            SET raw_entry_fpa_down_deg TO predict_entry_fpa_down_deg_at(entry_interface_alt_meters).
            SET next_entry_fpa_prediction TO TIME:SECONDS + 0.1.
            IF raw_entry_fpa_down_deg < 0 {
                abort_deorbit("cannot target atmospheric interface after descending below it.").
            }
            // Retrograde progress toward this interface is monotonic. Keep the
            // highest valid prediction so a transient KSP orbit-patch regression
            // cannot reopen throttle after the stop threshold was nearly reached.
            IF raw_entry_fpa_down_deg > achieved_entry_fpa_down_deg {
                SET achieved_entry_fpa_down_deg TO raw_entry_fpa_down_deg.
            } ELSE IF NOT entry_fpa_prediction_regression_logged AND raw_entry_fpa_down_deg + entry_fpa_prediction_regression_tolerance_deg < achieved_entry_fpa_down_deg {
                warn_line("Entry-FPA prediction regressed", "raw " + ROUND(raw_entry_fpa_down_deg, 3) + " deg below latched " + ROUND(achieved_entry_fpa_down_deg, 3) + " deg; retaining monotonic latch").
                SET entry_fpa_prediction_regression_logged TO TRUE.
            }
        }
        LOCAL fpa_error IS target_entry_fpa_down_deg - achieved_entry_fpa_down_deg.
        IF fpa_error <= entry_fpa_tolerance_deg {
            SET deorbit_throttle TO 0.
            SET success TO TRUE.
        } ELSE {
            SET deorbit_throttle TO clamp(fpa_error * entry_fpa_throttle_kp, min_deorbit_throttle, max_twr_throttle).
        }

        LOCAL fpa_miss_detail IS "TR impact unavailable".
        IF ADDONS:TR:HASIMPACT {
            SET had_impact TO TRUE.
            LOCAL fpa_impact_geo IS ADDONS:TR:IMPACTPOS.
            LOCAL fpa_miss IS target_miss_distance(fpa_impact_geo, pad_geo).
            SET best_miss TO fpa_miss.
            SET final_impact_lat TO fpa_impact_geo:LAT.
            SET final_impact_lng TO fpa_impact_geo:LNG.
            SET fpa_miss_detail TO "TR miss " + ROUND(fpa_miss/1000, 1) + " km".
        }
        IF TIME:SECONDS >= next_print {
            log_line("  burn: " + ROUND(burn_used, 1) + " m/s  |  entry FPA latched/raw/target: " + ROUND(achieved_entry_fpa_down_deg, 3) + "/" + ROUND(raw_entry_fpa_down_deg, 3) + "/" + ROUND(target_entry_fpa_down_deg, 3) + " deg down  |  " + fpa_miss_detail).
            log_line("    error: " + ROUND(MAX(0, fpa_error), 3) + " deg  |  thr: " + ROUND(deorbit_throttle, 3) + "/" + ROUND(max_twr_throttle, 3)).
            SET next_print TO next_burn_telemetry_time().
        }
    } ELSE IF ADDONS:TR:HASIMPACT {
        SET had_impact TO TRUE.
        LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
        LOCAL miss IS target_miss_distance(impact_geo, pad_geo).
        IF miss < best_miss {
            SET best_miss TO miss.
            SET final_impact_lat TO impact_geo:LAT.
            SET final_impact_lng TO impact_geo:LNG.
            SET worsening_logged TO FALSE.
        } ELSE IF NOT worsening_logged AND best_miss < slow_burn_miss_meters AND miss > best_miss + slow_burn_miss_meters {
            warn_line("Predicted miss worsening", "current " + ROUND(miss) + " m; best " + ROUND(best_miss) + " m; continuing burn").
            SET worsening_logged TO TRUE.
        }

        LOCAL miss_outside_tolerance IS MAX(0, miss - slow_burn_miss_meters).
        LOCAL pid_throttle IS 0.

        IF miss <= slow_burn_miss_meters {
            SET deorbit_throttle TO 0.
            SET success TO TRUE.
        } ELSE {
            SET pid_throttle TO miss_pid:UPDATE(TIME:SECONDS, -miss_outside_tolerance).
            SET deorbit_throttle TO clamp(pid_throttle, min_deorbit_throttle, max_twr_throttle).
        }

        IF TIME:SECONDS >= next_print {
            log_line("  burn: " + ROUND(burn_used, 1) + " m/s  |  miss: " + ROUND(miss) + " m  |  best: " + ROUND(best_miss) + " m").
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
UNLOCK THROTTLE.
UNLOCK STEERING.
log_line("--- Deorbit achieved ---").
log_line("  burn: " + ROUND(burn_used, 1) + " m/s  |  predicted miss: " + ROUND(best_miss) + " m").
log_line("  final impact: " + ROUND(final_impact_lat, 5) + ", " + ROUND(final_impact_lng, 5)).
IF deorbit_guidance_mode = "entry_fpa29" {
    log_line("  entry corridor: " + ROUND(achieved_entry_fpa_down_deg, 3) + " deg downward at " + ROUND(entry_interface_alt_meters/1000, 1) + " km  |  target " + ROUND(target_entry_fpa_down_deg, 3) + " deg").
}
transmit_log().

PRINT " ".
PRINT "Auto-running reentry.ks below " + ROUND(reentry_handoff_alt_meters/1000, 1) + " km. Press any key to abort.".
WAIT 1.
SET WARP TO reentry_coast_warp_rate.
LOCAL handoff_next_print IS TIME:SECONDS.
UNTIL SHIP:ALTITUDE <= reentry_handoff_alt_meters {
    IF TERMINAL:INPUT:HASCHAR {
        log_line("Reentry handoff aborted by user.").
        transmit_log().
        SHUTDOWN.
    }
    IF TIME:SECONDS >= handoff_next_print {
        log_line("  Waiting for reentry handoff  |  alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  target <= " + ROUND(reentry_handoff_alt_meters/1000, 1) + " km  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s").
        SET handoff_next_print TO TIME:SECONDS + reentry_handoff_telemetry_interval.
    }
    WAIT 1.
}
SET WARP TO 0.

log_line("Running reentry script: " + reentry_script_path + "  |  airbrakes: " + reentry_airbrake_control_mode + "  |  fixed angle: " + ROUND(custom_fixed_airbrake_angle_deg, 2) + "  |  Trajectories profile: " + trajectories_profile_id + "  |  corridor: " + deorbit_guidance_mode).
RUNPATH(reentry_script_path, reentry_airbrake_control_mode, trajectories_profile_id, custom_fixed_airbrake_angle_deg, deorbit_guidance_mode, target_entry_fpa_down_deg, achieved_entry_fpa_down_deg, target_deorbit_phase_angle_deg, actual_deorbit_burn_phase_angle_deg).
