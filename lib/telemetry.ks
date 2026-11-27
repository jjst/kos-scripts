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
        "local_file", CREATE("1:/" + filename),
        "dropped", 0,
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
    LOCAL local_file IS telemetry_state["local_file"].
    IF local_file:WRITELN(entry) { RETURN. }
    IF transmit_log() {
        IF local_file:WRITELN(entry) { RETURN. }
        LOCAL archive_file IS OPEN(telemetry_state["archive_path"]).
        IF archive_file:WRITELN(entry) { RETURN. }
    }
    IF telemetry_state["dropped"] = 0 {
        PRINT "Telemetry could not be stored. Flight control continues.".
    }
    SET telemetry_state["dropped"] TO telemetry_state["dropped"] + 1.
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
    IF NOT telemetry_can_transmit() { RETURN FALSE. }
    LOCAL local_file IS telemetry_state["local_file"].
    LOCAL archive_path IS telemetry_state["archive_path"].
    IF local_file:SIZE > 0 {
        IF EXISTS(archive_path) {
            LOCAL archive_file IS OPEN(archive_path).
            IF NOT archive_file:WRITE(local_file:READALL()) { RETURN FALSE. }
        } ELSE {
            COPYPATH(telemetry_state["local_path"], archive_path).
            IF NOT EXISTS(archive_path) { RETURN FALSE. }
        }
        // Clear only the records that were successfully archived.
        local_file:CLEAR().
    }
    IF telemetry_state["dropped"] > 0 {
        LOCAL archive_file IS OPEN(archive_path).
        IF archive_file = FALSE { SET archive_file TO CREATE(archive_path). }
        IF NOT archive_file:WRITELN(ROUND(TIME:SECONDS, 2) + " [!] Telemetry storage - "
            + telemetry_state["dropped"] + " entries could not be stored") { RETURN FALSE. }
        SET telemetry_state["dropped"] TO 0.
    }
    RETURN EXISTS(archive_path).
}

// Finish an in-game test run started by scripts/kos-drive.js. The runner waits
// for the TEST-DONE line, then reads the archive copy of this log.
FUNCTION end_test {
    PARAMETER run_token.
    log_line("Test finished with " + log_failure_count() + " failed check(s).").
    LOCAL copied IS transmit_log().
    PRINT "TEST-DONE " + run_token + " " + telemetry_state["archive_path"]
        + " failures=" + log_failure_count() + " copied=" + copied.
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
