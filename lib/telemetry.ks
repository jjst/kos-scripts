@LAZYGLOBAL OFF.

FUNCTION telemetry_can_transmit {
    RETURN HOMECONNECTION:ISCONNECTED OR (SHIP:BODY:NAME = "Kerbin"
        AND (SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED")).
}

FUNCTION open_log {
    PARAMETER name.
    IF telemetry_has_log() { transmit_log(). }

    LOCAL stem IS name + "-" + ROUND(TIME:SECONDS * 1000) + "-"
        + SHIP:ROOTPART:UID + "-" + FLOOR(RANDOM() * 1000000000).
    LOCAL filename IS stem + ".log".
    LOCAL sequence IS 1.
    LOCAL archive_available IS telemetry_can_transmit().
    UNTIL NOT EXISTS("1:/" + filename) AND NOT (archive_available AND EXISTS("0:/" + filename)) {
        SET filename TO stem + "-" + sequence + ".log".
        SET sequence TO sequence + 1.
    }

    GLOBAL telemetry_state IS LEXICON(
        "local_path", "1:/" + filename,
        "archive_path", "0:/" + filename,
        "failures", 0,
        "last_checkpoint", TIME:SECONDS,
        "last_checkpoint_realtime", KUNIVERSE:REALTIME
    ).
    log_line("Opened " + name + " log.", FALSE).
}

FUNCTION log_line {
    PARAMETER msg, show_in_terminal IS TRUE.
    LOCAL entry IS ROUND(TIME:SECONDS, 2) + " " + msg.
    IF show_in_terminal { PRINT entry. }
    LOG entry TO telemetry_state["local_path"].
}

FUNCTION telemetry_has_log {
    RETURN DEFINED telemetry_state.
}

FUNCTION check_line {
    PARAMETER ok, label, detail.
    LOCAL mark IS "[PASS]".
    IF NOT ok {
        SET mark TO "[FAIL]".
        SET telemetry_state["failures"] TO telemetry_state["failures"] + 1.
    }
    log_line(mark + " " + label + " - " + detail).
    RETURN ok.
}

FUNCTION log_failure_count {
    RETURN telemetry_state["failures"].
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
    IF telemetry_can_transmit() {
        COPYPATH(telemetry_state["local_path"], telemetry_state["archive_path"]).
        RETURN TRUE.
    }
    RETURN FALSE.
}

FUNCTION checkpoint_log {
    PARAMETER phase.
    // At higher warp, limit archive copies and samples by elapsed real time.
    LOCAL warp_rate IS KUNIVERSE:TIMEWARP:RATE.
    IF TIME:SECONDS - telemetry_state["last_checkpoint"] < 20 { RETURN. }
    IF warp_rate > 1.01 AND KUNIVERSE:REALTIME - telemetry_state["last_checkpoint_realtime"] < 20 { RETURN. }
    IF phase <> "" {
        LOCAL detail IS phase + ": " + SHIP:STATUS + ", active "
            + (SHIP = KUNIVERSE:ACTIVEVESSEL) + ", unpacked " + SHIP:UNPACKED
            + ", warp " + warp_rate + "x".
        IF SHIP:STATUS = "ORBITING" {
            SET detail TO detail + ", Ap " + ROUND(SHIP:APOAPSIS / 1000, 2)
                + " km, Pe " + ROUND(SHIP:PERIAPSIS / 1000, 2)
                + " km, ETA Ap " + ROUND(ETA:APOAPSIS, 1) + " s".
        }
        log_line(detail + ".", FALSE).
    }
    transmit_log().
    SET telemetry_state["last_checkpoint"] TO TIME:SECONDS.
    SET telemetry_state["last_checkpoint_realtime"] TO KUNIVERSE:REALTIME.
}
