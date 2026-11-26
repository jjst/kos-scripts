// Assign /boot/jeblink_carrier.ks to the carrier processor.
// To restart manually, RUNPATH("0:/boot/jeblink_carrier.ks", original_count).
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/launch.ks"
// #include "0:/lib/jeblink.ks"
DECLARE PARAMETER constellation_size IS 0.

LOCAL circularisation_ignition_delay IS 1.

FUNCTION launch_setting {
    PARAMETER label, default_value, lower, upper.
    UNTIL FALSE {
        PRINT label + " (" + lower + " to " + upper + ", Enter for " + default_value + ")".
        LOCAL buffer IS "".
        LOCAL input_row IS TERMINAL:HEIGHT - 2.
        PRINT ">                     " AT (0, input_row).
        UNTIL FALSE {
            IF TERMINAL:INPUT:HASCHAR {
                LOCAL key IS TERMINAL:INPUT:GETCHAR().
                IF key = TERMINAL:INPUT:RETURN { BREAK. }
                IF key = TERMINAL:INPUT:BACKSPACE AND buffer:LENGTH > 0 {
                    SET buffer TO buffer:SUBSTRING(0, buffer:LENGTH - 1).
                } ELSE IF key:MATCHESPATTERN("^[0-9.]$") AND buffer:LENGTH < 10 {
                    SET buffer TO buffer + key.
                }
                PRINT "> " + buffer + "              " AT (0, input_row).
            }
            checkpoint_log("Waiting for " + label).
            WAIT 0.
        }
        IF buffer = "" { RETURN default_value. }
        LOCAL entered IS buffer:TONUMBER(-1).
        IF entered >= lower AND entered <= upper { RETURN entered. }
        CLEARSCREEN.
        PRINT "Enter a number from " + lower + " to " + upper + ".".
    }
}

FUNCTION launch_carrier_from_pad {
    log_line("Select the Jeblink carrier and settle at 1x for pad preflight.").
    transmit_log().
    UNTIL SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:UNPACKED
        AND KUNIVERSE:TIMEWARP:ISSETTLED AND KUNIVERSE:TIMEWARP:RATE <= 1.01 {
        checkpoint_log("Waiting for pad flight controls").
        WAIT 0.
    }
    LOCAL engines IS jeblink_carrier_poodles().
    LOCAL poodle_ok IS check_line(engines:LENGTH = 1, "Carrier Poodle count",
        engines:LENGTH + ", required 1").
    LOCAL fairing_count IS 0.
    FOR fairing IN SHIP:MODULESNAMED("ModuleProceduralFairing") {
        IF fairing:HASEVENT("deploy") OR fairing:HASEVENT("deploy fairing") {
            SET fairing_count TO fairing_count + 1.
            info_line("Fairing placement", fairing:PART:NAME + ", configured stage " + fairing:PART:STAGE).
        } ELSE {
            warn_line("Fairing deploy event unavailable", fairing:PART:NAME + ", events " + fairing:ALLEVENTNAMES).
        }
    }
    LOCAL fairing_ok IS check_line(fairing_count > 0, "Deployable fairing count",
        fairing_count + ", required at least 1").
    IF NOT (poodle_ok AND fairing_ok) {
        log_line("Launch stopped before ignition. Check the carrier engine and payload fairing in the VAB.").
        RETURN FALSE.
    }

    LOCAL poodle_stage IS engines[0]:STAGE.
    LOCAL relays IS SHIP:PARTSNAMED("probeCoreCube").
    LOCAL relay_layout_ok IS check_line(relays:LENGTH >= 2, "Mounted relays",
        relays:LENGTH + ", required at least 2").
    LOCAL stages_ok IS check_line(poodle_stage >= 0 AND poodle_stage < STAGE:NUMBER, "Poodle stage",
        "Poodle stage " + poodle_stage + ", current stage " + STAGE:NUMBER + ", required 0 <= Poodle stage < current stage").
    FOR relay IN relays {
        LOCAL separation_stage IS relay:DECOUPLEDIN.
        LOCAL relay_ok IS check_line(separation_stage < poodle_stage, "Relay stages " + relay:UID,
            "separation stage " + separation_stage + ", must be below last ascent stage " + poodle_stage + " or -1").
        SET relay_layout_ok TO relay_layout_ok AND relay_ok.
    }
    IF NOT (relay_layout_ok AND stages_ok) {
        log_line("Launch stopped before ignition. Remove relay separators from ascent staging and rerun.").
        RETURN FALSE.
    }
    LOCAL site_ok IS check_line(SHIP:BODY:NAME = "Kerbin" AND SHIP = KUNIVERSE:ACTIVEVESSEL
        AND SHIP:UNPACKED AND KUNIVERSE:TIMEWARP:ISSETTLED AND KUNIVERSE:TIMEWARP:RATE <= 1.01,
        "Carrier launch site", SHIP:BODY:NAME + ", active=" + (SHIP = KUNIVERSE:ACTIVEVESSEL)
        + ", unpacked=" + SHIP:UNPACKED + ", settled=" + KUNIVERSE:TIMEWARP:ISSETTLED
        + ", warp " + KUNIVERSE:TIMEWARP:RATE + "x (limit 1.01x)").
    IF NOT site_ok {
        log_line("Launch stopped before ignition. Select the unpacked carrier on Kerbin at 1x and rerun.").
        RETURN FALSE.
    }
    transmit_log().
    CLEARSCREEN.
    TERMINAL:INPUT:CLEAR().
    LOCAL azimuth IS launch_setting("Launch heading in degrees", 90, 0, 359.999).
    CLEARSCREEN.
    LOCAL altitude_km IS launch_setting("Constellation altitude in km", 100, 80, 9999).
    CLEARSCREEN.
    log_line("Press Enter to launch Jeblink, heading " + azimuth + " deg, target " + altitude_km + " km.").
    transmit_log().
    jeblink_wait_for_enter("Waiting for launch confirmation").
    CLEARSCREEN.
    LOCAL result IS launch_to_orbit(LEXICON("heading", azimuth, "target_altitude", altitude_km * 1000,
        "minimum_pe", 75000, "fairing_policy", "atmosphere", "last_stage", poodle_stage,
        "half_dv_timing", TRUE, "ignition_delay", circularisation_ignition_delay)).
    IF NOT result["success"] {
        log_line("Phasing was skipped. Launch stopped: " + result["reason"]
            + ". Check the logged orbit and recover the carrier before restarting.").
        RETURN FALSE.
    }
    LOCAL mounted_count IS SHIP:PARTSNAMED("probeCoreCube"):LENGTH.
    IF NOT check_line(mounted_count = relays:LENGTH, "Relays after ascent",
        mounted_count + " mounted, expected " + relays:LENGTH) {
        log_line("Phasing was skipped. The mounted relay count changed during ascent.").
        RETURN FALSE.
    }
    LOCAL planned_count IS relays:LENGTH.
    IF constellation_size > planned_count { SET planned_count TO constellation_size. }
    LOCAL plan IS jeblink_carrier_phasing_plan(planned_count).
    IF plan:LENGTH = 0 {
        log_line("Phasing was skipped. No phasing orbit can keep Pe at least 75 km within 12 laps per release.").
        RETURN FALSE.
    }
    LOCAL poodle IS engines[0].
    LOCAL poodle_ready IS check_line(STAGE:NUMBER = poodle_stage AND poodle:IGNITION
        AND NOT poodle:FLAMEOUT AND poodle:AVAILABLETHRUST > 0
        AND SHIP:AVAILABLETHRUST <= poodle:AVAILABLETHRUST + 0.01,
        "Poodle insertion engine", "stage " + STAGE:NUMBER + " (expected " + poodle_stage + ")"
        + ", ignition=" + poodle:IGNITION + ", flameout=" + poodle:FLAMEOUT
        + ", engine " + ROUND(poodle:AVAILABLETHRUST, 2) + " kN, vessel "
        + ROUND(SHIP:AVAILABLETHRUST, 2) + " kN (extra thrust limit 0.01 kN)").
    LOCAL remaining_dv IS STAGE:DELTAV:VACUUM.
    LOCAL insertion_dv IS plan["insertion_dv"].
    LOCAL required_dv IS MAX(0, insertion_dv) + 10.
    LOCAL dv_ok IS check_line(remaining_dv >= required_dv, "Poodle insertion delta-v",
        ROUND(remaining_dv, 1) + " m/s available, " + ROUND(MAX(0, insertion_dv), 1)
        + " m/s burn plus 10 m/s margin").
    IF NOT (poodle_ready AND dv_ok) {
        log_line("Phasing was skipped. Confirm the Poodle is the sole active engine and has the logged fuel margin.").
        RETURN FALSE.
    }
    RETURN TRUE.
}

FUNCTION run_carrier {
    open_log("jeblink-carrier").
    log_line("Carrier message queues at startup: vessel " + SHIP:MESSAGES:LENGTH
        + ", processor " + CORE:MESSAGES:LENGTH + ".", FALSE).
    LOCAL launched_from_pad IS SHIP:STATUS = "PRELAUNCH" OR SHIP:STATUS = "LANDED".
    IF launched_from_pad {
        COPYPATH("0:/lib/launch.ks", "1:/lib/launch.ks").
        RUNONCEPATH(PATH("1:/lib/launch.ks")).
        IF NOT launch_carrier_from_pad() {
            transmit_log().
            RETURN.
        }
    }
    jeblink_deploy_constellation(constellation_size, launched_from_pad).
    transmit_log().
}

COPYPATH("0:/lib/telemetry.ks", "1:/lib/telemetry.ks").
RUNONCEPATH(PATH("1:/lib/telemetry.ks")).
COPYPATH("0:/lib/jeblink.ks", "1:/lib/jeblink.ks").
RUNONCEPATH(PATH("1:/lib/jeblink.ks")).
run_carrier().
