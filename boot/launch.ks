// ============================================================
//  launch.ks — Gravity-turn ascent to circular orbit
//  Target: 100 km circular orbit, 90° azimuth (equatorial)
// ============================================================

// --- CONFIG (edit these) ------------------------------------
SET target_apoapsis  TO 100000.
SET turn_start_alt   TO 100.
SET turn_end_alt     TO 50000.
SET launch_azimuth   TO 90.
SET max_twr          TO 2.5.
SET stage_fuel_min   TO 0.1.
SET circularize_ecc_tol           TO 0.002.
SET circularize_ecc_throttle_scale TO 0.05.
SET ascent_report_interval_ap      TO 10000.
SET circularize_report_ecc_step    TO 0.02.
// ------------------------------------------------------------

CLEARSCREEN.
PRINT "Boot script loaded. Press ENTER to begin launch sequence.".
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
TERMINAL:INPUT:GETCHAR().

SAS OFF.
RCS OFF.
GEAR OFF.
LOCK THROTTLE TO 0.

FUNCTION print_phase_banner {
    PARAMETER title.
    PARAMETER detail IS "".
    PRINT "".
    PRINT "============================================================".
    PRINT ">> " + title.
    IF detail <> "" {
        PRINT "   " + detail.
    }
    PRINT "============================================================".
}

FUNCTION print_flight_snapshot {
    LOCAL pe_text IS "".
    IF SHIP:PERIAPSIS < 0 {
        SET pe_text TO "suborbital".
    } ELSE {
        SET pe_text TO ROUND(SHIP:PERIAPSIS / 1000, 1) + " km".
    }
    PRINT "   Alt: " + ROUND(SHIP:ALTITUDE / 1000, 1) + " km | Ap: " + ROUND(SHIP:APOAPSIS / 1000, 1) + " km | Pe: " + pe_text.
}

// Steering helper: pitch = gravity turn interpolation
FUNCTION ascent_pitch {
    LOCAL frac IS (SHIP:ALTITUDE - turn_start_alt) /
                  (turn_end_alt  - turn_start_alt).
    SET frac TO MAX(0, MIN(1, frac)).
    RETURN 90 - (90 * frac).
}

// Phase 1 — Countdown
LOCK STEERING TO HEADING(launch_azimuth, 90).
print_phase_banner("PHASE 1 — COUNTDOWN", "Azimuth " + launch_azimuth + " deg | Target Ap " + ROUND(target_apoapsis / 1000, 0) + " km").
PRINT "Launch sequence initiated. Vehicle configured for ascent.".
PRINT "Gravity turn window: " + ROUND(turn_start_alt, 0) + " m -> " + ROUND(turn_end_alt, 0) + " m.".
FROM {LOCAL i IS 5.} UNTIL i = 0 STEP {SET i TO i - 1.} DO {
    PRINT "T-" + i + "s".
    WAIT 1.
}
PRINT "Ignition!".
LOCK THROTTLE TO 1.0.
STAGE.

// Phase 2 — Hold vertical until turn_start_alt
print_phase_banner("PHASE 2 — INITIAL ASCENT", "Holding vertical until " + ROUND(turn_start_alt, 0) + " m.").
WAIT UNTIL SHIP:ALTITUDE > turn_start_alt.
PRINT "Vertical climb complete; beginning pitch program.".

// Phase 3 — Gravity turn loop
print_phase_banner("PHASE 3 — GRAVITY TURN", "Ramping pitch while building apoapsis to " + ROUND(target_apoapsis / 1000, 0) + " km.").
SET stage_armed TO TRUE.
LOCAL next_ascent_report_ap IS ascent_report_interval_ap.
UNTIL SHIP:APOAPSIS >= target_apoapsis {

    IF stage_armed AND STAGE:LIQUIDFUEL < stage_fuel_min {
        PRINT "Stage fuel below threshold (" + ROUND(STAGE:LIQUIDFUEL, 1) + " < " + ROUND(stage_fuel_min, 1) + " units). Staging now.".
        STAGE.
        SET stage_armed TO FALSE.
        WAIT 1.
    }

    IF STAGE:LIQUIDFUEL >= stage_fuel_min {
        SET stage_armed TO TRUE.
    }

    LOCK STEERING TO HEADING(launch_azimuth, ascent_pitch()).

    // TWR-limited throttle, halved when closing in on target Ap
    LOCAL max_thrust        IS SHIP:AVAILABLETHRUST.
    LOCAL weight            IS SHIP:MASS * SHIP:BODY:MU /
                              (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    LOCAL effective_max_twr IS max_twr.
    IF SHIP:APOAPSIS > (target_apoapsis * 0.9) {
        SET effective_max_twr TO max_twr * 0.5.
    }
    LOCAL twr_throttle IS (effective_max_twr * weight) / max_thrust.
    LOCAL ascent_throttle IS MIN(1.0, twr_throttle).

    LOCK THROTTLE TO ascent_throttle.

    IF SHIP:APOAPSIS >= next_ascent_report_ap {
        LOCAL current_pitch IS ascent_pitch().
        PRINT "Ascent update: pitch " + ROUND(current_pitch, 1) + " deg | throttle " + ROUND(ascent_throttle * 100, 0) + "%".
        print_flight_snapshot().
        SET next_ascent_report_ap TO next_ascent_report_ap + ascent_report_interval_ap.
    }

    WAIT 0.
}

// Phase 4 — Cut engines, coast to apoapsis
LOCK THROTTLE TO 0.
print_phase_banner("PHASE 4 — COAST TO APOAPSIS", "Target apoapsis reached; preparing circularisation burn.").
PRINT "Estimated time to apoapsis: " + ROUND(ETA:APOAPSIS, 1) + " s.".
LOCK STEERING TO PROGRADE.

// Estimate circularisation burn duration so we can ignite half a burn-time before Ap.
LOCAL mu_body  IS SHIP:BODY:MU.
LOCAL r_ap     IS SHIP:BODY:RADIUS + SHIP:APOAPSIS.
LOCAL a_cur    IS SHIP:OBT:SEMIMAJORAXIS.
LOCAL v_at_ap  IS SQRT(mu_body * (2 / r_ap - 1 / a_cur)).
LOCAL v_circ   IS SQRT(mu_body / r_ap).
LOCAL circ_dv  IS MAX(0, v_circ - v_at_ap).
LOCAL burn_duration IS 0.
IF SHIP:AVAILABLETHRUST > 0 {
    SET burn_duration TO (circ_dv * SHIP:MASS) / SHIP:AVAILABLETHRUST.
}
PRINT "Estimated circularisation burn: " + ROUND(burn_duration, 1) + " s  (dv=" + ROUND(circ_dv, 1) + " m/s)".

LOCAL burn_start_eta IS burn_duration / 2.
UNTIL ETA:APOAPSIS < burn_start_eta + 60 {
    SET WARP TO 3.
    WAIT 1.
}
SET WARP TO 0.
PRINT "Warp complete. Burn start in ~" + ROUND(MAX(0, ETA:APOAPSIS - burn_start_eta), 1) + " s.".
WAIT UNTIL ETA:APOAPSIS < burn_start_eta.

// Phase 5 — Circularisation burn at apoapsis
print_phase_banner("PHASE 5 — CIRCULARISATION", "Executing prograde burn to reduce eccentricity.").
LOCK STEERING TO PROGRADE.

IF SHIP:AVAILABLETHRUST <= 0 {
    PRINT "Circularisation ended early: no thrust available.".
} ELSE {
    LOCAL next_circularize_report_ecc IS MAX(0, SHIP:OBT:ECCENTRICITY - circularize_report_ecc_step).
    UNLOCK THROTTLE.
    UNTIL SHIP:OBT:ECCENTRICITY < circularize_ecc_tol {
        IF SHIP:AVAILABLETHRUST <= 0 {
            PRINT "Circularisation ended early: no thrust available.".
            BREAK.
        }

        LOCAL max_thrust IS SHIP:AVAILABLETHRUST.
        LOCAL weight IS SHIP:MASS * SHIP:BODY:MU /
                        (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
        LOCAL twr_throttle IS (max_twr * weight) / max_thrust.
        LOCAL ecc_throttle IS MIN(1.0, SHIP:OBT:ECCENTRICITY / circularize_ecc_throttle_scale).
        LOCAL circ_throttle IS MIN(twr_throttle, ecc_throttle).
        LOCK THROTTLE TO circ_throttle.

        IF SHIP:OBT:ECCENTRICITY <= next_circularize_report_ecc {
            PRINT "Circularisation update: ecc " + ROUND(SHIP:OBT:ECCENTRICITY, 4) + " | throttle " + ROUND(circ_throttle * 100, 0) + "%".
            print_flight_snapshot().
            SET next_circularize_report_ecc TO MAX(0, next_circularize_report_ecc - circularize_report_ecc_step).
        }
        WAIT 0.
    }
}

LOCK THROTTLE TO 0.

// Done
UNLOCK STEERING.
SAS ON.
print_phase_banner("LAUNCH COMPLETE", "Orbit achieved and guidance handed back to SAS.").
PRINT "  Ap: " + ROUND(SHIP:APOAPSIS/1000, 1) + " km".
PRINT "  Pe: " + ROUND(SHIP:PERIAPSIS/1000, 1) + " km".
PRINT "  Eccentricity: " + ROUND(SHIP:OBT:ECCENTRICITY, 4).
