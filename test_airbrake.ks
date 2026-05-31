// test_airbrake.ks — probe airbrake pmodule fields and test angle control
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

LOCAL surfaces IS SHIP:CONTROLSURFACES.
log_line("Control surfaces: " + surfaces:LENGTH).
FOR s IN surfaces {
    log_line("  " + s:PART:NAME + "  |  auth: " + ROUND(s:AUTHORITY, 1) + "  |  deployed: " + s:DEPLOYED).
}

log_line(" ").
FOR s IN surfaces {
    log_line("--- " + s:PART:NAME + " ---").
    FOR pmodname IN s:PART:MODULES {
        LOCAL pmod IS s:PART:GETMODULE(pmodname).
        IF pmod:ALLFIELDNAMES:LENGTH > 0 {
            log_line("  Module: " + pmodname).
            FOR fname IN pmod:ALLFIELDNAMES {
                log_line("    " + fname + " = " + pmod:GETFIELD(fname)).
            }
        }
    }
}
transmit_log().

log_line(" ").
log_line("Interactive: 1=auth25  2=auth50  3=auth75  4=auth100  0=auth0  Q=quit").
BRAKES ON.
TERMINAL:INPUT:CLEAR().
UNTIL FALSE {
    IF TERMINAL:INPUT:HASCHAR {
        LOCAL c IS TERMINAL:INPUT:GETCHAR().
        IF c = "0" {
            FOR s IN surfaces { SET s:AUTHORITY TO 0. }
            log_line("Authority -> 0").
        } ELSE IF c = "1" {
            FOR s IN surfaces { SET s:AUTHORITY TO 25. }
            log_line("Authority -> 25").
        } ELSE IF c = "2" {
            FOR s IN surfaces { SET s:AUTHORITY TO 50. }
            log_line("Authority -> 50").
        } ELSE IF c = "3" {
            FOR s IN surfaces { SET s:AUTHORITY TO 75. }
            log_line("Authority -> 75").
        } ELSE IF c = "4" {
            FOR s IN surfaces { SET s:AUTHORITY TO 100. }
            log_line("Authority -> 100").
        } ELSE IF c = "q" OR c = "Q" {
            BREAK.
        }
        transmit_log().
    }
    WAIT 0.
}

BRAKES OFF.
log_line("Done.").
transmit_log().
