// test_airbrake.ks — probe airbrake module fields and test angle control
SET log_path TO "test_airbrake.log".

FUNCTION log_line {
    PARAMETER msg.
    PRINT msg.
    LOG msg TO log_path.
}

FUNCTION transmit_log {
    IF HOMECONNECTION:ISCONNECTED {
        COPYPATH(log_path, "0:").
        RETURN TRUE.
    }
    RETURN FALSE.
}

CLEARSCREEN.
log_line("=== test_airbrake.ks ===").

LOCAL ab_parts IS SHIP:PARTSTAGGED("airbrake").
log_line("Parts tagged 'airbrake': " + ab_parts:LENGTH).

FOR p IN ab_parts {
    log_line("--- " + p:NAME + " (tag: " + p:TAG + ") ---").
    transmit_log().
    FOR modname IN p:MODULES {
        LOCAL pmod IS p:GETMODULE(modname).
        log_line("  Module: " + modname).
        transmit_log().
        IF pmod:ALLFIELDS:LENGTH > 0 {
            log_line("    Fields:").
            FOR fname IN pmod:ALLFIELDS {
                log_line("      " + fname).
                transmit_log().
            }
        } ELSE {
            log_line("    Fields: (none)").
            transmit_log().
        }
        IF pmod:ALLEVENTS:LENGTH > 0 {
            log_line("    Events:").
            FOR ename IN pmod:ALLEVENTS {
                log_line("      " + ename).
                transmit_log().
            }
        } ELSE {
            log_line("    Events: (none)").
            transmit_log().
        }
        IF pmod:ALLACTIONS:LENGTH > 0 {
            log_line("    Actions:").
            FOR aname IN pmod:ALLACTIONS {
                log_line("      " + aname).
                transmit_log().
            }
        } ELSE {
            log_line("    Actions: (none)").
            transmit_log().
        }
    }
}

log_line(" ").
log_line("Interactive: 1=auth25  2=auth50  3=auth75  4=auth100  0=auth0  Q=quit").
BRAKES ON.
TERMINAL:INPUT:CLEAR().
UNTIL FALSE {
    IF TERMINAL:INPUT:HASCHAR {
        LOCAL c IS TERMINAL:INPUT:GETCHAR().
        LOCAL auth IS -1.
        IF c = "0" { SET auth TO 0. }
        ELSE IF c = "1" { SET auth TO 25. }
        ELSE IF c = "2" { SET auth TO 50. }
        ELSE IF c = "3" { SET auth TO 75. }
        ELSE IF c = "4" { SET auth TO 100. }
        ELSE IF c = "q" OR c = "Q" { BREAK. }

        IF auth >= 0 {
            FOR p IN ab_parts {
                p:GETMODULE("ModuleAeroSurface"):SETFIELD("authority limiter", auth).
            }
            log_line("Authority -> " + auth).
            transmit_log().
        }
    }
    WAIT 0.
}

BRAKES OFF.
log_line("Done.").
transmit_log().
