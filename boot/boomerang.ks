// ============================================================
//  boomerang.ks - bootstrap loader for the boomerang vessel.
// ============================================================

LOCAL scripts IS LIST(
    "launch.ks",
    "deorbit.ks",
    "reentry.ks",
    "land_guided.ks",
    "land_unguided.ks"
).

FUNCTION read_line {
    LOCAL buffer IS "".
    LOCAL done IS FALSE.
    LOCAL input_row IS TERMINAL:HEIGHT - 2.
    PRINT "> " + buffer + "                    " AT (0, input_row).
    UNTIL done {
        // GETCHAR blocks until the next character. Echo the buffer ourselves;
        // TerminalInput deliberately does not provide cooked line editing.
        LOCAL ch IS TERMINAL:INPUT:GETCHAR().
        IF ch = TERMINAL:INPUT:RETURN {
            SET done TO TRUE.
        } ELSE IF ch = TERMINAL:INPUT:BACKSPACE {
            IF buffer:LENGTH > 0 {
                SET buffer TO buffer:SUBSTRING(0, buffer:LENGTH - 1).
            }
        } ELSE IF ch:MATCHESPATTERN("^[0-9.]$") {
            SET buffer TO buffer + ch.
        }
        PRINT "> " + buffer + "                    " AT (0, input_row).
    }
    PRINT "> " + buffer + " accepted             " AT (0, input_row).
    RETURN buffer.
}

FUNCTION prompt_fixed_airbrake_angle {
    UNTIL FALSE {
        PRINT "Fixed airbrake angle in degrees (0-90), then RETURN:".
        LOCAL raw_value IS read_line():TRIM.
        LOCAL angle_value IS raw_value:TONUMBER(-1).
        IF raw_value:LENGTH > 0 AND angle_value >= 0 AND angle_value <= 90 {
            RETURN angle_value.
        }
        PRINT "Invalid angle. Enter a number from 0 through 90.".
    }
}

PRINT "=== boomerang.ks ===".
PRINT "Syncing scripts to local volume...".
FOR script IN scripts {
    LOCAL local_path IS "1:/" + script.
    IF EXISTS(local_path) { DELETEPATH(local_path). }
    COPYPATH("0:/" + script, local_path).
}

PRINT " ".
PRINT "Initial script:".
LOCAL idx IS 1.
FOR script IN scripts {
    IF script = "deorbit.ks" {
        PRINT "  " + idx + ") deorbit.ks [current 2.9 deg corridor: custom angle; 0 = brakes off]".
    } ELSE {
        PRINT "  " + idx + ") " + script.
    }
    SET idx TO idx + 1.
}
LOCAL deorbit_script_choice IS 2.
LOCAL corridor60_survival_choice IS scripts:LENGTH + 1.
LOCAL corridor75_survival_choice IS scripts:LENGTH + 2.
LOCAL corridor90_survival_choice IS scripts:LENGTH + 3.
LOCAL corridor75_targeting_choice IS scripts:LENGTH + 4.
// Repeat the measured burn-start phase from run 1795036279.
LOCAL corridor75_ignition_phase_deg IS 162.816.
LOCAL experiment_deorbit_path IS "1:/" + scripts[1].
PRINT "  " + corridor60_survival_choice + ") deorbit.ks [SURVIVAL TEST: 0 deg AoA, airbrakes 60 + 10/1 q duty]".
PRINT "  " + corridor75_survival_choice + ") deorbit.ks [SURVIVAL TEST: 0 deg AoA, airbrakes 75 + 10/1 q duty]".
PRINT "  " + corridor90_survival_choice + ") deorbit.ks [SURVIVAL TEST: 0 deg AoA, airbrakes 90 + 10/1 q duty]".
PRINT "  " + corridor75_targeting_choice + ") deorbit.ks [TARGETING TEST: fixed 75 deg, ignition " + corridor75_ignition_phase_deg + " deg]".
PRINT "Press RETURN to load nothing.".
TERMINAL:INPUT:CLEAR().
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
LOCAL choice IS TERMINAL:INPUT:GETCHAR().
WAIT 0.
TERMINAL:INPUT:CLEAR().

LOCAL choice_num IS choice:TONUMBER(-1).
IF choice_num = deorbit_script_choice {
    LOCAL corridor_custom_angle IS prompt_fixed_airbrake_angle().
    IF corridor_custom_angle <= 0 {
        PRINT "Launching current 2.9 deg entry corridor with airbrakes off...".
        RUNPATH(experiment_deorbit_path, "off", "matched10", -1, "entry_fpa29").
    } ELSE {
        PRINT "Launching current 2.9 deg entry corridor with airbrakes fixed at " + ROUND(corridor_custom_angle, 2) + " deg...".
        RUNPATH(experiment_deorbit_path, "fixed", "matched10", corridor_custom_angle, "entry_fpa29").
    }
} ELSE IF choice_num >= 1 AND choice_num <= scripts:LENGTH {
    LOCAL script IS scripts[choice_num - 1].
    PRINT "Launching local " + script + "...".
    RUNPATH("1:/" + script).
} ELSE IF choice_num = corridor60_survival_choice {
    PRINT "Launching isolated reentry-survival test: 0 deg AoA, fixed 60 deg, 10/1 q duty...".
    RUNPATH(experiment_deorbit_path, "fixed60", "matched0", -1, "entry_fpa29", TRUE, FALSE).
} ELSE IF choice_num = corridor75_survival_choice {
    PRINT "Launching isolated reentry-survival test: 0 deg AoA, fixed 75 deg, 10/1 q duty...".
    RUNPATH(experiment_deorbit_path, "fixed", "matched0", 75, "entry_fpa29", TRUE, FALSE).
} ELSE IF choice_num = corridor90_survival_choice {
    PRINT "Launching isolated reentry-survival test: 0 deg AoA, fixed 90 deg, 10/1 q duty...".
    RUNPATH(experiment_deorbit_path, "fixed90", "matched0", -1, "entry_fpa29", TRUE, FALSE).
} ELSE IF choice_num = corridor75_targeting_choice {
    PRINT "Launching fixed-75 targeting test with ignition at " + corridor75_ignition_phase_deg + " deg...".
    RUNPATH(experiment_deorbit_path, "fixed", "matched0", 75, "entry_fpa29", TRUE, TRUE, -1, corridor75_ignition_phase_deg).
} ELSE {
    PRINT "No initial script launched.".
}
