// Assign this boot file to each Jeblink satellite processor.
// Release one satellite per apoapsis: 313 x 500 km for eight satellites,
// or 376 x 500 km for twelve.

FUNCTION deploy_satellite {
    LOCAL apoapsis_margin IS 1000.
    LOCAL periapsis_tolerance IS 150.
    LOCAL angular_tolerance IS 2.
    LOCAL log_path IS "1:/jeblink_control.log".

    FUNCTION log_line {
        PARAMETER msg.
        LOCAL entry IS ROUND(TIME:SECONDS, 2) + " " + msg.
        PRINT entry.
        LOG entry TO log_path.
    }

    log_line("Jeblink: waiting for separation.").
    // The carrier and each satellite have their own command core and engine.
    // Check both so the last satellite also waits until it is off the carrier.
    UNTIL SHIP:UNPACKED AND SHIP:MODULESNAMED("ModuleCommand"):LENGTH = 1
        AND SHIP:ENGINES:LENGTH = 1 {
        WAIT 1.
    }
    WAIT 3.
    WAIT UNTIL SHIP:UNPACKED.
    LOCAL archive_path IS "0:/jeblink-" + ROUND(TIME:SECONDS * 1000) + ".log".

    FUNCTION transmit_log {
        IF HOMECONNECTION:ISCONNECTED {
            COPYPATH(log_path, archive_path).
            PRINT "Jeblink: copied log to " + archive_path.
        }
    }

    log_line("Jeblink: separated as " + SHIP:NAME + ".").

    FOR panel IN SHIP:MODULESNAMED("ModuleDeployableSolarPanel") {
        IF panel:HASEVENT("Extend Panels") {
            panel:DOEVENT("Extend Panels").
        }
    }

    FUNCTION log_control_reference {
        PARAMETER phase.
        log_line(phase
            + ": root=" + SHIP:ROOTPART:NAME + ", control=" + SHIP:CONTROLPART:NAME
            + ", forward=" + SHIP:FACING:FOREVECTOR:TOSTRING).
    }

    LOCAL probe_cores IS SHIP:PARTSNAMED("probeCoreCube").
    IF probe_cores:LENGTH <> 1 {
        log_line("Jeblink: expected one QBE. No burn.").
        transmit_log().
        RETURN.
    }
    log_control_reference("before CONTROLFROM").
    probe_cores[0]:CONTROLFROM().
    WAIT 0.
    log_control_reference("after CONTROLFROM").
    IF SHIP:CONTROLPART:NAME <> probe_cores[0]:NAME {
        log_line("Jeblink: QBE control reference did not take. No burn.").
        transmit_log().
        RETURN.
    }

    FUNCTION pointing_error {
        RETURN VANG(SHIP:FACING:FOREVECTOR, SHIP:VELOCITY:ORBIT).
    }

    LOCAL release_apoapsis IS SHIP:APOAPSIS.
    LOCAL target_periapsis IS release_apoapsis - periapsis_tolerance.
    LOCAL apoapsis_limit IS release_apoapsis + apoapsis_margin.
    LOCAL sat_engine IS SHIP:ENGINES[0].
    LOCAL throttle_cmd IS 0.

    FUNCTION log_burn_state {
        PARAMETER phase.
        log_line(phase + ": Ap " + ROUND(SHIP:APOAPSIS / 1000, 2)
            + " km, Pe " + ROUND(SHIP:PERIAPSIS / 1000, 2)
            + " km, ETA Ap " + ROUND(ETA:APOAPSIS, 1)
            + " s, error " + ROUND(pointing_error(), 1)
            + " deg, throttle " + ROUND(throttle_cmd, 2)
            + ", thrust " + ROUND(sat_engine:THRUST, 3)
            + " kN, flameout " + sat_engine:FLAMEOUT).
    }

    log_line("Jeblink: target Pe " + ROUND(target_periapsis / 1000, 2)
        + " km, Ap cutoff " + ROUND(apoapsis_limit / 1000, 2) + " km.").
    log_burn_state("Before alignment").
    LOCK THROTTLE TO throttle_cmd.
    SAS OFF.
    LOCK STEERING TO PROGRADE.

    LOCAL alignment_deadline IS TIME:SECONDS + 20.
    WAIT UNTIL pointing_error() <= angular_tolerance
        OR TIME:SECONDS >= alignment_deadline OR NOT SHIP:UNPACKED.
    LOCAL cutoff_reason IS "periapsis target reached".
    IF NOT SHIP:UNPACKED {
        SET cutoff_reason TO "vessel left full physics before ignition".
    } ELSE IF pointing_error() > angular_tolerance {
        SET cutoff_reason TO "alignment timed out".
    } ELSE IF SHIP:PERIAPSIS < target_periapsis {
        sat_engine:ACTIVATE().
        LOCAL burn_deadline IS TIME:SECONDS + 30.
        // Let the engine and throttle command reach a physics tick before
        // interpreting flameout as an ignition or fuel failure.
        LOCAL check_flameout_after IS TIME:SECONDS + 0.5.
        LOCAL next_sample IS check_flameout_after.
        UNTIL SHIP:PERIAPSIS >= target_periapsis {
            IF NOT SHIP:UNPACKED {
                SET cutoff_reason TO "vessel left full physics during burn".
                BREAK.
            } ELSE IF SHIP:APOAPSIS > apoapsis_limit {
                SET cutoff_reason TO "apoapsis rose more than 1 km above release apoapsis".
                BREAK.
            } ELSE IF TIME:SECONDS >= burn_deadline {
                SET cutoff_reason TO "30-second burn limit".
                BREAK.
            } ELSE IF pointing_error() > 5 {
                SET cutoff_reason TO "prograde error exceeded 5 degrees".
                BREAK.
            } ELSE IF TIME:SECONDS >= check_flameout_after AND sat_engine:FLAMEOUT {
                SET cutoff_reason TO "engine reported flameout after ignition".
                BREAK.
            }
            IF TIME:SECONDS >= next_sample {
                log_burn_state("Burn").
                SET next_sample TO TIME:SECONDS + 1.
            }
            SET throttle_cmd TO MAX(0.08, MIN(1, (target_periapsis - SHIP:PERIAPSIS) / 3000)).
            WAIT 0.
        }
        log_burn_state("Before shutdown").
        SET throttle_cmd TO 0.
        sat_engine:SHUTDOWN().
    }
    WAIT 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.

    LOCAL cutoff_entry IS "Jeblink: " + cutoff_reason
        + " (error " + ROUND(pointing_error(), 1) + " deg, Ap "
        + ROUND(SHIP:APOAPSIS / 1000, 2) + " km, limit "
        + ROUND(apoapsis_limit / 1000, 2) + " km).".
    log_line(cutoff_entry).

    IF SHIP:PERIAPSIS >= target_periapsis
        AND SHIP:APOAPSIS <= apoapsis_limit {
        log_line("Jeblink: circularization complete.").
    } ELSE {
        log_line("Jeblink: circularization incomplete.").
    }
    log_burn_state("Final").
    transmit_log().
}

deploy_satellite().
