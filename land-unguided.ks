// ============================================================
//  land-unguided.ks — airbrake descent + suicide burn fallback
// ============================================================
//  Used when reentry handoff conditions aren't met. Deploys
//  airbrakes and holds retrograde, then suicide-burns below
//  suicide_burn_alt_meters.

// --- CONFIG (edit these) ------------------------------------
SET suicide_burn_alt_meters TO 1000.
SET telemetry_interval TO 10.
SET log_path TO "land-unguided.log".
// ------------------------------------------------------------

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

CLEARSCREEN.
log_line("=== land-unguided.ks ===").
log_line("Unguided descent: airbrakes + suicide burn below " + ROUND(suicide_burn_alt_meters) + " m").

SAS OFF.
LOCK THROTTLE TO 0.
BRAKES ON.
LOCK STEERING TO SRFRETROGRADE.

log_line("--- Airbrake descent ---").
LOCAL next_print IS TIME:SECONDS.
UNTIL SHIP:ALTITUDE < suicide_burn_alt_meters {
    IF TIME:SECONDS >= next_print {
        log_line("  Alt: " + ROUND(SHIP:ALTITUDE/1000, 2) + " km  |  spd: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s").
        transmit_log().
        SET next_print TO TIME:SECONDS + telemetry_interval.
    }
    WAIT 0.
}

BRAKES OFF.
log_line("--- Suicide burn ---  |  alt: " + ROUND(SHIP:ALTITUDE) + " m  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s").
LOCK THROTTLE TO 1.
UNTIL SHIP:VERTICALSPEED > -5 OR SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
    IF TIME:SECONDS >= next_print {
        log_line("  Alt: " + ROUND(SHIP:ALTITUDE) + " m  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s  |  spd: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s").
        transmit_log().
        SET next_print TO TIME:SECONDS + 2.
    }
    WAIT 0.
}

LOCK THROTTLE TO 0.
UNLOCK THROTTLE.
UNLOCK STEERING.
log_line("Burn complete  |  alt: " + ROUND(SHIP:ALTITUDE) + " m  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s").
transmit_log().
