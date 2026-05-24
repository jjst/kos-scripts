// ============================================================
//  hop.ks — Suborbital vertical hop with propulsive landing
// ============================================================

// --- CONFIG (edit these) ------------------------------------
SET hop_altitude      TO 5000.
SET max_twr           TO 2.5.
SET burn_safety       TO 1.3.
SET brakes_deploy_alt TO 3000.
SET gear_deploy_alt   TO 200.
SET touchdown_speed   TO 2.
// ------------------------------------------------------------

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
RCS ON.
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

// Phase 4 — Descending: wait for suicide burn trigger
LOCK STEERING TO SRFRETROGRADE.
PRINT "--- Phase 4: Descending ---".
LOCAL brakes_deployed IS FALSE.
LOCAL gear_deployed IS FALSE.
LOCAL burn_ready IS FALSE.
SET next_print TO TIME:SECONDS.
UNTIL burn_ready {
    LOCAL alt_agl IS ALT:RADAR.
    LOCAL vs IS ABS(SHIP:VERTICALSPEED).
    LOCAL g IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.

    IF NOT brakes_deployed AND alt_agl < brakes_deploy_alt {
        BRAKES ON.
        SET brakes_deployed TO TRUE.
        PRINT "  Airbrakes  |  alt: " + ROUND(alt_agl) + " m AGL".
    }
    IF NOT gear_deployed AND alt_agl < gear_deploy_alt {
        GEAR ON.
        SET gear_deployed TO TRUE.
        PRINT "  Gear down  |  alt: " + ROUND(alt_agl) + " m AGL".
    }

    IF SHIP:AVAILABLETHRUST <= 0 {
        PRINT "  FATAL: no thrust — forcing burn trigger.".
        SET burn_ready TO TRUE.
    }
    IF NOT burn_ready {
        LOCAL a_net IS (SHIP:AVAILABLETHRUST / SHIP:MASS) - g.
        IF a_net <= 0 {
            PRINT "  WARNING: a_net " + ROUND(a_net, 2) + " m/s^2 — forcing burn trigger.".
            SET burn_ready TO TRUE.
        }
        IF NOT burn_ready {
            LOCAL burn_dist IS (vs^2 / (2 * a_net)) * burn_safety.
            IF alt_agl <= burn_dist {
                PRINT "  Burn trigger  |  alt: " + ROUND(alt_agl) + " m  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s".
                SET burn_ready TO TRUE.
            }
            IF NOT burn_ready AND TIME:SECONDS >= next_print {
                PRINT "  Alt: " + ROUND(alt_agl) + " m AGL  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s  |  burn in: " + ROUND(alt_agl - burn_dist) + " m".
                SET next_print TO TIME:SECONDS + 2.
            }
        }
    }
    WAIT 0.
}

// Phase 5 — Powered descent and landing
PRINT "--- Phase 5: Powered descent ---".
BRAKES OFF.
SET next_print TO TIME:SECONDS.
UNTIL SHIP:STATUS = "LANDED" {
    LOCAL g_land IS SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    LOCAL hover IS (SHIP:MASS * g_land) / SHIP:AVAILABLETHRUST.
    LOCAL error IS SHIP:VERTICALSPEED + touchdown_speed.
    LOCAL thr IS MAX(0, MIN(1, hover - error * 0.05)).
    LOCK THROTTLE TO thr.
    IF TIME:SECONDS >= next_print {
        PRINT "  Alt: " + ROUND(ALT:RADAR) + " m  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s  |  thr: " + ROUND(thr, 2).
        SET next_print TO TIME:SECONDS + 1.
    }
    WAIT 0.
}

LOCK THROTTLE TO 0.
UNLOCK THROTTLE.
UNLOCK STEERING.
RCS OFF.
SAS ON.
PRINT "--- Landed! ---".
PRINT "  Final vs: " + ROUND(SHIP:VERTICALSPEED, 2) + " m/s  |  status: " + SHIP:STATUS.
