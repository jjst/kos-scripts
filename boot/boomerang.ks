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
LOCAL corridor60_reference_choice IS scripts:LENGTH + 1.
LOCAL corridor90_reference_choice IS scripts:LENGTH + 2.
LOCAL corridor0_aoa_choice IS scripts:LENGTH + 3.
LOCAL corridor_pid_choice IS scripts:LENGTH + 4.
LOCAL experiment_deorbit_path IS "1:/" + scripts[1].
PRINT "  " + corridor60_reference_choice + ") deorbit.ks [175 deg phase test: airbrakes 60 reference]".
PRINT "  " + corridor90_reference_choice + ") deorbit.ks [175 deg phase test: airbrakes 90]".
PRINT "  " + corridor0_aoa_choice + ") deorbit.ks [0 deg AoA trial: airbrakes 90 + thermal safeguard]".
PRINT "  " + corridor_pid_choice + ") deorbit.ks [closed-loop airbrakes 60-90; after endpoint validation]".
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
} ELSE IF choice_num = corridor60_reference_choice {
    PRINT "Launching current 2.9 deg entry corridor with airbrakes fixed at 60 deg...".
    RUNPATH(experiment_deorbit_path, "fixed60", "matched10", -1, "entry_fpa29").
} ELSE IF choice_num = corridor90_reference_choice {
    PRINT "Launching current 2.9 deg entry corridor with airbrakes fixed at 90 deg...".
    RUNPATH(experiment_deorbit_path, "fixed90", "matched10", -1, "entry_fpa29").
} ELSE IF choice_num = corridor0_aoa_choice {
    PRINT "Launching 0 deg surface-retrograde trial with airbrakes fixed at 90 deg...".
    RUNPATH(experiment_deorbit_path, "fixed90", "matched0", -1, "entry_fpa29").
} ELSE IF choice_num = corridor_pid_choice {
    PRINT "Launching 2.9 deg corridor with closed-loop airbrakes clamped to 60-90 deg...".
    RUNPATH(experiment_deorbit_path, "pid", "matched10", -1, "entry_fpa29").
} ELSE {
    PRINT "No initial script launched.".
}
