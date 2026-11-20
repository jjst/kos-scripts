// Assign this boot file to each Jeblink satellite processor.
// Release one satellite per apoapsis: 313 x 500 km for eight satellites,
// or 376 x 500 km for twelve.

FUNCTION deploy_satellite {
    LOCAL apoapsis_margin IS 1000.
    LOCAL periapsis_tolerance IS 150.
    LOCAL angular_tolerance IS 2.
    LOCAL turn_rate_tolerance IS 2.
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

    // Deploy after the separation delay so the panels clear the carrier.
    IF SHIP:MODULESNAMED("ModuleDeployableSolarPanel"):LENGTH > 0 {
        PANELS ON.
        log_line("Jeblink: solar panel extension commanded.").
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
    LOCAL relay_name IS probe_cores[0]:TAG.
    IF relay_name:MATCHESPATTERN("^(JR|JL)-[0-9]+-[0-9]+$") {
        SET SHIP:NAME TO relay_name.
    }
    SET SHIP:TYPE TO "Relay".
    log_line("Relay identity: " + SHIP:NAME + ", QBE UID " + probe_cores[0]:UID + ".").
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

    FUNCTION turn_rate {
        RETURN SHIP:ANGULARVEL:MAG * 180 / CONSTANT:PI.
    }

    FUNCTION aligned {
        RETURN pointing_error() <= angular_tolerance AND turn_rate() <= turn_rate_tolerance.
    }

    FUNCTION release_controls {
        UNLOCK THROTTLE.
        UNLOCK STEERING.
    }

    FUNCTION log_alignment {
        PARAMETER phase.
        LOCAL facing_vector IS SHIP:FACING:FOREVECTOR.
        LOCAL orbit_velocity IS SHIP:VELOCITY:ORBIT.
        LOCAL prograde_vector IS SHIP:PROGRADE:FOREVECTOR.
        log_line("Alignment " + phase
            + ": active=" + KUNIVERSE:ACTIVEVESSEL:NAME
            + ", probe_active=" + (SHIP = KUNIVERSE:ACTIVEVESSEL)
            + ", control=" + SHIP:CONTROLPART:NAME
            + ", unpacked=" + SHIP:UNPACKED
            + ", SAS=" + SAS + ", turn rate=" + ROUND(turn_rate(), 2) + " deg/s").
        log_line("  facing=" + facing_vector + ", orbit velocity=" + orbit_velocity
            + ", prograde=" + prograde_vector + ", angular velocity=" + SHIP:ANGULARVEL).
        log_line("  facing to orbit velocity=" + ROUND(VANG(facing_vector, orbit_velocity), 3)
            + " deg, facing to prograde=" + ROUND(VANG(facing_vector, prograde_vector), 3)
            + " deg, prograde to orbit velocity=" + ROUND(VANG(prograde_vector, orbit_velocity), 3)
            + " deg").
    }

    LOCAL release_apoapsis IS SHIP:APOAPSIS.
    LOCAL target_periapsis IS release_apoapsis - periapsis_tolerance.
    LOCAL apoapsis_limit IS release_apoapsis + apoapsis_margin.
    LOCAL sat_engine IS SHIP:ENGINES[0].
    LOCAL throttle_cmd IS 0.
    LOCAL original_pack_distance IS -1.

    FUNCTION log_burn_state {
        PARAMETER phase.
        LOCAL active_vessel IS KUNIVERSE:ACTIVEVESSEL.
        LOCAL active_range IS (active_vessel:POSITION - SHIP:POSITION):MAG.
        LOCAL relative_speed IS (active_vessel:VELOCITY:ORBIT - SHIP:VELOCITY:ORBIT):MAG.
        log_line(phase + ": Ap " + ROUND(SHIP:APOAPSIS / 1000, 2)
            + " km, Pe " + ROUND(SHIP:PERIAPSIS / 1000, 2)
            + " km, ETA Ap " + ROUND(ETA:APOAPSIS, 1)
            + " s, error " + ROUND(pointing_error(), 1)
            + " deg, throttle " + ROUND(throttle_cmd, 2)
            + ", thrust " + ROUND(sat_engine:THRUST, 3)
            + " kN, flameout " + sat_engine:FLAMEOUT
            + ", turn rate " + ROUND(turn_rate(), 2) + " deg/s"
            + ", active " + active_vessel:NAME
            + ", probe_active " + (SHIP = active_vessel)
            + ", active range " + ROUND(active_range, 1) + " m"
            + ", relative speed " + ROUND(relative_speed, 1) + " m/s").
    }

    FUNCTION log_orbit_distances {
        PARAMETER label, vessel_ref.
        LOCAL distances IS vessel_ref:LOADDISTANCE:ORBIT.
        log_line(label + " orbital thresholds: pack=" + distances:PACK
            + " m, unpack=" + distances:UNPACK + " m, load=" + distances:LOAD
            + " m, unload=" + distances:UNLOAD + " m.").
    }

    log_line("Jeblink: target Pe " + ROUND(target_periapsis / 1000, 2)
        + " km, Ap cutoff " + ROUND(apoapsis_limit / 1000, 2) + " km.").
    log_orbit_distances("Probe", SHIP).
    IF SHIP <> KUNIVERSE:ACTIVEVESSEL {
        log_orbit_distances("Active vessel", KUNIVERSE:ACTIVEVESSEL).
    }
    log_burn_state("Before alignment").
    LOCK THROTTLE TO throttle_cmd.
    SAS OFF.
    WAIT 0.
    LOCK STEERING TO SHIP:PROGRADE.
    log_alignment("kOS prograde steering started").
    transmit_log().

    LOCAL alignment_deadline IS TIME:SECONDS + 20.
    LOCAL next_alignment_sample IS TIME:SECONDS + 0.5.
    UNTIL aligned()
        OR TIME:SECONDS >= alignment_deadline OR NOT SHIP:UNPACKED {
        IF TIME:SECONDS >= next_alignment_sample {
            log_alignment("waiting").
            SET next_alignment_sample TO TIME:SECONDS + 0.5.
        }
        WAIT 0.
    }
    log_alignment("wait ended").
    LOCAL cutoff_reason IS "periapsis target reached".
    IF NOT SHIP:UNPACKED {
        SET cutoff_reason TO "vessel left full physics before ignition".
    } ELSE IF NOT aligned() {
        SET cutoff_reason TO "alignment timed out (limits 2 deg and 2 deg/s)".
    } ELSE IF SHIP:PERIAPSIS < target_periapsis {
        sat_engine:ACTIVATE().
        WAIT 0.
        LOCAL apo_radius IS SHIP:BODY:RADIUS + release_apoapsis.
        LOCAL semi_major IS (apo_radius + SHIP:BODY:RADIUS + SHIP:PERIAPSIS) / 2.
        LOCAL mu IS SHIP:BODY:MU.
        LOCAL burn_delta_v IS SQRT(mu / apo_radius)
            - SQRT(mu * (2 / apo_radius - 1 / semi_major)).
        LOCAL available_thrust IS sat_engine:AVAILABLETHRUST.
        IF available_thrust <= 0 {
            sat_engine:SHUTDOWN().
            release_controls().
            log_line("Jeblink: no available thrust for burn timing.").
            transmit_log().
            RETURN.
        }
        LOCAL burn_lead IS burn_delta_v * SHIP:MASS / available_thrust / 2.
        log_line("Jeblink: estimated dV " + ROUND(burn_delta_v, 1)
            + " m/s, ignition lead " + ROUND(burn_lead, 1)
            + " s, ETA Ap " + ROUND(ETA:APOAPSIS, 1) + " s.").
        LOCAL coast_deadline IS TIME:SECONDS + 180.
        LOCAL next_coast_sample IS TIME:SECONDS.
        UNTIL ETA:APOAPSIS <= burn_lead
            OR NOT SHIP:UNPACKED OR TIME:SECONDS >= coast_deadline {
            IF TIME:SECONDS >= next_coast_sample {
                log_burn_state("Coasting to ignition").
                transmit_log().
                SET next_coast_sample TO TIME:SECONDS + 20.
            }
            WAIT 0.
        }
        IF NOT SHIP:UNPACKED OR ETA:APOAPSIS > burn_lead OR NOT aligned() {
            log_burn_state("Timed ignition skipped: unpacked " + SHIP:UNPACKED
                + ", ignition lead " + ROUND(burn_lead, 1) + " s, alignment limits 2 deg and 2 deg/s").
            sat_engine:SHUTDOWN().
            release_controls().
            transmit_log().
            RETURN.
        }
        IF SHIP <> KUNIVERSE:ACTIVEVESSEL {
            LOCAL probe_distances IS SHIP:LOADDISTANCE:ORBIT.
            IF probe_distances:PACK < 1000 AND probe_distances:LOAD >= 1000 {
                SET original_pack_distance TO probe_distances:PACK.
                SET probe_distances:PACK TO 1000.
                log_line("Jeblink: probe orbital PACK " + original_pack_distance
                    + " -> " + probe_distances:PACK + " m for this burn.").
            } ELSE {
                log_line("Jeblink: orbital PACK kept at " + probe_distances:PACK
                    + " m (LOAD " + probe_distances:LOAD + " m).").
            }
        }
        log_burn_state("Timed ignition").
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
    release_controls().

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
    log_line("Jeblink: solar panels extended=" + PANELS + ".").
    LOCAL target_radius IS SHIP:BODY:RADIUS + release_apoapsis.
    LOCAL target_period IS 2 * CONSTANT:PI * SQRT(target_radius^3 / SHIP:BODY:MU).
    log_line("Jeblink: period error " + ROUND(SHIP:OBT:PERIOD - target_period, 2)
        + " s relative to a circular orbit at release apoapsis.").
    IF original_pack_distance >= 0 {
        SET SHIP:LOADDISTANCE:ORBIT:PACK TO original_pack_distance.
        log_line("Jeblink: restored probe orbital PACK to " + SHIP:LOADDISTANCE:ORBIT:PACK + " m.").
    }
    transmit_log().
}

deploy_satellite().
