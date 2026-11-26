@LAZYGLOBAL OFF.
// Jeblink carrier phasing and relay deployment. Load the telemetry library first.
// Call jeblink_deploy_constellation after opening the caller-owned log.
// #include "0:/lib/telemetry.ks"

LOCAL next_display IS 0.
LOCAL warp_buffer IS 20.
LOCAL abort_countdown_seconds IS 10.

LOCAL FUNCTION coast_display {
    PARAMETER event_name, seconds_left, aligning IS FALSE, can_abort IS FALSE.
    IF TIME:SECONDS < next_display { RETURN. }
    SET next_display TO TIME:SECONDS + 2.
    LOCAL seconds_remaining IS MAX(0, CEILING(seconds_left)).
    CLEARSCREEN.
    PRINT event_name + " in " + FLOOR(seconds_remaining / 60) + "m "
        + MOD(seconds_remaining, 60) + "s".
    IF aligning {
        PRINT "Aligning for insertion. Stay on the carrier at 1x.".
    } ELSE IF KUNIVERSE:TIMEWARP:RATE > 1.01 {
        PRINT "Auto-warping. Stay on the carrier.".
    } ELSE {
        PRINT "Stay on the carrier. No input needed.".
    }
    IF can_abort {
        PRINT "Press any key to abort this release.".
    } ELSE {
        PRINT "The carrier acts automatically.".
    }
}

LOCAL FUNCTION time_to_release {
    PARAMETER earliest_release, release_lead.
    LOCAL next_pass IS TIME:SECONDS + ETA:APOAPSIS - release_lead.
    LOCAL period IS SHIP:OBT:PERIOD.
    LOCAL first_eligible_time IS MAX(TIME:SECONDS, earliest_release).
    LOCAL extra_laps IS MAX(0, CEILING((first_eligible_time - next_pass) / period)).
    RETURN next_pass + extra_laps * period - TIME:SECONDS.
}

LOCAL FUNCTION warp_to_coast_end {
    PARAMETER event_name, seconds_until_event.
    IF seconds_until_event > warp_buffer {
        log_line("Auto-warping to " + warp_buffer + " s before " + event_name
            + ". Planned " + event_name + " in " + ROUND(seconds_until_event, 1) + " s.").
        transmit_log().
        KUNIVERSE:TIMEWARP:WARPTO(TIME:SECONDS + seconds_until_event - warp_buffer).
    }
}

FUNCTION jeblink_wait_for_enter {
    PARAMETER phase.
    TERMINAL:INPUT:CLEAR().
    UNTIL FALSE {
        IF TERMINAL:INPUT:HASCHAR {
            IF TERMINAL:INPUT:GETCHAR() = TERMINAL:INPUT:RETURN { RETURN. }
        }
        checkpoint_log(phase).
        WAIT 0.
    }
}

LOCAL FUNCTION proceed_unless_aborted {
    PARAMETER action_label, summary IS "".
    LOCAL deadline IS TIME:SECONDS + abort_countdown_seconds.
    LOCAL next_status IS 0.
    log_line(action_label + " scheduled after a " + abort_countdown_seconds + " s abort countdown.", FALSE).
    transmit_log().
    TERMINAL:INPUT:CLEAR().
    UNTIL FALSE {
        IF TERMINAL:INPUT:HASCHAR {
            TERMINAL:INPUT:GETCHAR().
            CLEARSCREEN.
            log_line(action_label + " cancelled by operator before auto-warp. Restart the carrier script from orbit to replan.").
            transmit_log().
            RETURN FALSE.
        }
        IF TIME:SECONDS >= deadline { BREAK. }
        IF TIME:SECONDS >= next_status {
            SET next_status TO TIME:SECONDS + 1.
            CLEARSCREEN.
            PRINT "Press any key to abort.".
            PRINT action_label + " starts in " + CEILING(deadline - TIME:SECONDS) + " s.".
            IF summary <> "" { PRINT summary. }
            PRINT "Stay on the carrier at 1x.".
        }
        checkpoint_log("Waiting for " + action_label + " abort countdown").
        WAIT 0.
    }
    CLEARSCREEN.
    RETURN TRUE.
}

LOCAL FUNCTION release_abort_requested {
    PARAMETER release_label.
    IF NOT TERMINAL:INPUT:HASCHAR { RETURN FALSE. }
    TERMINAL:INPUT:GETCHAR().
    log_line("Operator cancelled " + release_label + " before separation at warp "
        + ROUND(KUNIVERSE:TIMEWARP:RATE, 2) + "x.", FALSE).
    KUNIVERSE:TIMEWARP:CANCELWARP().
    CLEARSCREEN.
    log_line("No relay released. Restart the carrier script from orbit to replan.").
    transmit_log().
    RETURN TRUE.
}

LOCAL FUNCTION report_rejection_reason {
    PARAMETER received, relay_name, relay_uid, vessel_name, released_at.
    IF NOT received:HASSENDER { RETURN "sender vessel unavailable". }
    IF received:SENDER:NAME <> vessel_name { RETURN "expected sender " + vessel_name. }
    IF received:SENTAT:SECONDS < released_at { RETURN "sent before the current release". }

    LOCAL report IS received:CONTENT.
    IF NOT report:ISTYPE("Lexicon") { RETURN "payload is not a lexicon". }
    FOR field_name IN LIST("type", "relay", "uid", "success", "reason",
        "ap", "pe", "period_error", "dv", "ec") {
        IF NOT report:HASKEY(field_name) { RETURN "missing field " + field_name. }
    }
    IF report["type"] <> "jeblink-relay-result"
        OR report["relay"] <> relay_name OR report["uid"] <> relay_uid {
        RETURN "report type, tag or QBE UID does not match the current release".
    }
    IF NOT report["success"]:ISTYPE("Boolean") OR NOT report["reason"]:ISTYPE("String") {
        RETURN "invalid success or reason field".
    }
    FOR field_name IN LIST("ap", "pe", "period_error", "dv", "ec") {
        IF NOT report[field_name]:ISTYPE("Scalar") { RETURN "invalid field " + field_name. }
    }
    IF received:SENDER:UNPACKED {
        LOCAL sender_cores IS received:SENDER:PARTSNAMED("probeCoreCube").
        IF sender_cores:LENGTH <> 1 OR sender_cores[0]:UID <> relay_uid
            OR sender_cores[0]:TAG <> relay_name {
            RETURN "sender's QBE does not match the released relay".
        }
    }
    RETURN "".
}

LOCAL FUNCTION wait_for_relay_report {
    PARAMETER relay_name, relay_uid, vessel_name, released_at.
    LOCAL report_deadline IS released_at + 90.
    LOCAL next_status IS 0.
    UNTIL TIME:SECONDS >= report_deadline {
        IF NOT SHIP:MESSAGES:EMPTY {
            LOCAL received IS SHIP:MESSAGES:POP().
            LOCAL sender_label IS "unavailable".
            IF received:HASSENDER { SET sender_label TO received:SENDER:NAME. }
            log_line("Carrier received message from " + sender_label + ", sent UT "
                + ROUND(received:SENTAT:SECONDS, 2) + " s, received UT "
                + ROUND(received:RECEIVEDAT:SECONDS, 2) + " s: " + received:CONTENT, FALSE).
            LOCAL rejection IS report_rejection_reason(received, relay_name, relay_uid, vessel_name, released_at).
            IF rejection = "" {
                LOCAL report IS received:CONTENT.
                LOCAL outcome IS "circularisation failed".
                IF report["success"] { SET outcome TO "circularisation complete". }
                CLEARSCREEN.
                log_line(relay_name + " reports " + outcome + ". " + report["reason"] + ".").
                log_line("Ap " + ROUND(report["ap"] / 1000, 2) + " km, Pe "
                    + ROUND(report["pe"] / 1000, 2) + " km, period error "
                    + ROUND(report["period_error"], 2) + " s, " + ROUND(report["dv"], 1)
                    + " m/s remaining, " + ROUND(report["ec"], 1) + " EC.").
                IF NOT report["success"] {
                    log_line("Check " + vessel_name + " manually, then return to the carrier.").
                }
                transmit_log().
                IF report["success"] {
                    RETURN relay_name + " circularised at " + ROUND(report["ap"] / 1000, 2)
                        + " x " + ROUND(report["pe"] / 1000, 2) + " km.".
                }
                RETURN "".
            }
            log_line("Carrier rejected relay report: " + rejection + ".", FALSE).
        }
        IF TIME:SECONDS >= next_status {
            SET next_status TO TIME:SECONDS + 2.
            CLEARSCREEN.
            PRINT "Stay on the carrier at 1x while " + relay_name + " circularises.".
            PRINT "Waiting up to " + MAX(0, CEILING(report_deadline - TIME:SECONDS)) + " s for its report.".
        }
        checkpoint_log("Waiting for " + relay_name + " report").
        WAIT 0.
    }
    CLEARSCREEN.
    log_line("No report from " + relay_name + " within 90 s of release.").
    log_line("Check " + vessel_name + " manually, then return to the carrier.").
    transmit_log().
    RETURN "".
}

FUNCTION jeblink_parking_orbit_ready {
    RETURN SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:UNPACKED
        AND SHIP:BODY:NAME = "Kerbin" AND SHIP:STATUS = "ORBITING"
        AND SHIP:PERIAPSIS >= 75000.
}

FUNCTION jeblink_carrier_poodles {
    LOCAL poodles IS LIST().
    FOR eng IN SHIP:ENGINES {
        IF eng:NAME = "liquidEngine2-2.v2" OR eng:NAME = "liquidEngine2-2_v2" {
            poodles:ADD(eng).
        }
    }
    RETURN poodles.
}

FUNCTION jeblink_carrier_phasing_plan {
    PARAMETER relay_count.
    LOCAL mu IS SHIP:BODY:MU.
    LOCAL radius IS SHIP:BODY:RADIUS.
    LOCAL apo_radius IS radius + SHIP:APOAPSIS.
    LOCAL circular_period IS 2 * CONSTANT:PI * SQRT(apo_radius^3 / mu).
    FROM { LOCAL laps IS 1. } UNTIL laps > 12 STEP { SET laps TO laps + 1. } DO {
        LOCAL target_period IS circular_period * (1 - 1 / (relay_count * laps)).
        LOCAL target_axis IS apo_radius * (target_period / circular_period)^(2 / 3).
        LOCAL target_pe IS 2 * target_axis - apo_radius - radius.
        IF target_pe >= 75000 {
            LOCAL insertion_dv IS SQRT(mu * (2 / apo_radius - 1 / SHIP:OBT:SEMIMAJORAXIS))
                - SQRT(mu * (2 / apo_radius - 1 / target_axis)).
            RETURN LEXICON("laps", laps, "period", target_period, "pe", target_pe,
                "tolerance", circular_period / (360 * laps), "insertion_dv", insertion_dv).
        }
    }
    RETURN LEXICON().
}

LOCAL FUNCTION padded_number {
    PARAMETER number.
    IF number < 10 { RETURN "0" + number. }
    RETURN "" + number.
}

LOCAL FUNCTION random_train_code {
    LOCAL alphabet IS "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".
    LOCAL train_code IS "".
    UNTIL train_code:LENGTH = 4 {
        LOCAL index IS FLOOR(RANDOM() * alphabet:LENGTH).
        SET train_code TO train_code + alphabet:SUBSTRING(index, 1).
    }
    RETURN train_code.
}

FUNCTION jeblink_deploy_constellation {
    PARAMETER constellation_size IS 0, launched_from_pad IS FALSE, unattended_releases IS 0.
    SET next_display TO 0.
    LOCAL unattended IS unattended_releases > 0.
    IF unattended {
        LOCAL warp_rate_now IS KUNIVERSE:TIMEWARP:RATE.
        LOCAL warp_settled IS KUNIVERSE:TIMEWARP:ISSETTLED.
        IF NOT check_line(jeblink_parking_orbit_ready() AND warp_settled AND warp_rate_now <= 1.01,
            "Relay parking orbit",
            SHIP:BODY:NAME + " / " + SHIP:STATUS + ", active=" + (SHIP = KUNIVERSE:ACTIVEVESSEL)
            + ", unpacked=" + SHIP:UNPACKED + ", Pe " + ROUND(SHIP:PERIAPSIS, 1)
            + " m (minimum 75000 m), warp " + warp_rate_now + "x (limit 1.01x), settled=" + warp_settled) {
            RETURN FALSE.
        }
    } ELSE {
        log_line("Jeblink carrier booted. Waiting for an active Kerbin parking orbit with Pe at least 75 km.").
        transmit_log().
        UNTIL jeblink_parking_orbit_ready() {
            checkpoint_log("Waiting for parking orbit").
            WAIT 0.
        }
    }
    LOCAL armed IS unattended.
    UNTIL armed {
        IF launched_from_pad {
            IF NOT proceed_unless_aborted("Carrier phasing", "Carrier circularisation complete.") { RETURN FALSE. }
            SET launched_from_pad TO FALSE.
        } ELSE {
            log_line("Press Enter to begin phasing once the parking orbit is final and any ascent script has finished.").
            transmit_log().
            jeblink_wait_for_enter("Waiting for phasing confirmation").
        }
        LOCAL active_carrier IS SHIP = KUNIVERSE:ACTIVEVESSEL.
        LOCAL warp_rate IS KUNIVERSE:TIMEWARP:RATE.
        SET armed TO jeblink_parking_orbit_ready() AND warp_rate <= 1.01.
        IF NOT armed {
            IF NOT active_carrier { log_line("Cannot arm: carrier is not the active vessel."). }
            IF NOT SHIP:UNPACKED { log_line("Cannot arm: carrier is outside full physics."). }
            IF SHIP:BODY:NAME <> "Kerbin" OR SHIP:STATUS <> "ORBITING" {
                log_line("Cannot arm: expected Kerbin orbit, got " + SHIP:BODY:NAME + " / " + SHIP:STATUS + ".").
            }
            IF SHIP:PERIAPSIS < 75000 {
                log_line("Cannot arm: Pe is " + ROUND(SHIP:PERIAPSIS / 1000, 3) + " km. Minimum is 75 km.").
            }
            IF warp_rate > 1.01 {
                log_line("Cannot arm: time warp is " + ROUND(warp_rate, 2) + "x. Return to 1x.").
            }
            transmit_log().
        }
    }

    LOCAL satellites IS SHIP:PARTSNAMED("probeCoreCube").
    LOCAL remaining IS satellites:LENGTH.
    IF unattended AND NOT check_line(unattended_releases <= remaining AND unattended_releases = FLOOR(unattended_releases),
        "Requested relay releases", unattended_releases + " requested, " + remaining + " mounted") {
        RETURN FALSE.
    }
    LOCAL train_name IS "".
    // Keep the original constellation size with the code across processor reboots.
    IF SHIP:ROOTPART:TAG:MATCHESPATTERN("^[A-Z0-9]{4}/[0-9]+$") {
        LOCAL train_fields IS SHIP:ROOTPART:TAG:SPLIT("/").
        SET train_name TO train_fields[0].
        LOCAL original_count IS train_fields[1]:TONUMBER().
        IF constellation_size <> 0 AND constellation_size <> original_count {
            log_line("This train already has " + original_count + " relay slots. Rerun with that count.").
            RETURN FALSE.
        }
        SET constellation_size TO original_count.
    }
    IF constellation_size = 0 { SET constellation_size TO remaining. }
    IF remaining = 0 OR constellation_size < remaining OR constellation_size < 2
        OR constellation_size <> FLOOR(constellation_size) {
        log_line("No valid Jeblink constellation count.").
        RETURN FALSE.
    }
    IF train_name = "" {
        SET train_name TO random_train_code().
        SET SHIP:ROOTPART:TAG TO train_name + "/" + constellation_size.
    }
    LOCAL carrier_name IS "Jeblink JL-" + train_name + "-CARRIER".
    SET SHIP:NAME TO carrier_name.
    SET SHIP:TYPE TO "Probe".
    log_line("Carrier identity: " + SHIP:NAME + ", core UID " + SHIP:ROOTPART:UID + ".").
    LOCAL relay_slot IS constellation_size - remaining + 1.
    FOR probe_core IN satellites {
        IF NOT probe_core:TAG:MATCHESPATTERN("^" + train_name + "-[0-9]{2,}$") {
            SET probe_core:TAG TO train_name + "-" + padded_number(relay_slot).
        }
        log_line("Mounted relay " + probe_core:TAG + ", QBE UID " + probe_core:UID + ".", FALSE).
        SET relay_slot TO relay_slot + 1.
    }

    LOCAL target_apoapsis IS SHIP:APOAPSIS.
    LOCAL plan IS jeblink_carrier_phasing_plan(constellation_size).
    IF plan:LENGTH = 0 {
        log_line("No phasing orbit above 75 km found within 12 carrier laps per release.").
        RETURN FALSE.
    }
    LOCAL coast_laps IS plan["laps"].
    LOCAL target_period IS plan["period"].
    LOCAL target_pe IS plan["pe"].
    LOCAL period_tolerance IS plan["tolerance"].
    log_line("Starting orbit: Ap " + ROUND(SHIP:APOAPSIS / 1000, 2) + " km, Pe "
        + ROUND(SHIP:PERIAPSIS / 1000, 2) + " km, period " + ROUND(SHIP:OBT:PERIOD, 2) + " s.").
    log_line(remaining + " mounted, " + constellation_size + " planned, "
        + ROUND(360 / constellation_size, 2) + " deg spacing.").
    log_line("Carrier target Pe " + ROUND(target_pe / 1000, 2) + " km, Ap "
        + ROUND(target_apoapsis / 1000, 2) + " km, " + coast_laps + " lap(s) per release.").

    FUNCTION orbit_ready {
        RETURN SHIP:PERIAPSIS >= 75000
            AND ABS(SHIP:APOAPSIS - target_apoapsis) <= 1000
            AND ABS(SHIP:OBT:PERIOD - target_period) <= period_tolerance.
    }

    IF NOT orbit_ready() {
        IF SHIP:PERIAPSIS <= target_pe {
            log_line("Carrier orbit is already below the target periapsis. Raise Pe and rerun.").
            RETURN FALSE.
        }
        LOCAL carrier_engines IS jeblink_carrier_poodles().
        IF carrier_engines:LENGTH <> 1 {
            log_line("Expected one Jeblink carrier Poodle. No insertion burn.").
            RETURN FALSE.
        }
        LOCAL carrier_engine IS carrier_engines[0].
        LOCAL throttle_cmd IS 0.
        FUNCTION log_insertion_state {
            PARAMETER phase.
            log_line(phase + ": Ap " + ROUND(SHIP:APOAPSIS / 1000, 2)
                + " km, Pe " + ROUND(SHIP:PERIAPSIS / 1000, 2)
                + " km, ETA Ap " + ROUND(ETA:APOAPSIS, 1)
                + " s, period error " + ROUND(SHIP:OBT:PERIOD - target_period, 2)
                + " s, retrograde error " + ROUND(VANG(SHIP:FACING:FOREVECTOR, -SHIP:VELOCITY:ORBIT), 2)
                + " deg, throttle " + ROUND(throttle_cmd, 2) + ", thrust "
                + ROUND(carrier_engine:THRUST, 2) + " kN, flameout " + carrier_engine:FLAMEOUT
                + ", SAS " + SAS + "/" + SASMODE, FALSE).
        }
        LOCK THROTTLE TO throttle_cmd.
        carrier_engine:ACTIVATE().
        WAIT 0.
        LOCAL thrust_available IS carrier_engine:AVAILABLETHRUST.
        IF thrust_available <= 0 OR SHIP:AVAILABLETHRUST > thrust_available + 0.01 {
            carrier_engine:SHUTDOWN().
            UNLOCK THROTTLE.
            log_line("Expected thrust from the carrier Poodle only. No insertion burn.").
            RETURN FALSE.
        }
        LOCAL delta_v IS plan["insertion_dv"].
        LOCAL burn_lead IS MAX(0.5, delta_v * SHIP:MASS / thrust_available / 2).
        log_line("Insertion burn: " + ROUND(delta_v, 1) + " m/s, ignition "
            + ROUND(burn_lead, 1) + " s before apoapsis.").
        LOCAL seconds_until_insertion IS ETA:APOAPSIS - burn_lead.
        IF seconds_until_insertion <= 0 {
            SET seconds_until_insertion TO seconds_until_insertion + SHIP:OBT:PERIOD.
        }
        LOCAL ignition_time IS TIME:SECONDS + seconds_until_insertion.
        LOCAL latest_ignition IS ignition_time + 2.
        log_line("Planned insertion ignition UT " + ROUND(ignition_time, 2) + " s.", FALSE).
        warp_to_coast_end("insertion ignition", seconds_until_insertion).
        SET next_display TO 0.
        UNTIL TIME:SECONDS >= ignition_time - warp_buffer OR SHIP <> KUNIVERSE:ACTIVEVESSEL {
            coast_display("Insertion burn", ignition_time - TIME:SECONDS).
            checkpoint_log("Coasting to insertion").
            WAIT 0.
        }
        UNTIL (KUNIVERSE:TIMEWARP:ISSETTLED AND KUNIVERSE:TIMEWARP:RATE <= 1.01 AND SHIP:UNPACKED)
            OR TIME:SECONDS >= latest_ignition OR SHIP <> KUNIVERSE:ACTIVEVESSEL {
            checkpoint_log("Waiting for full physics after insertion warp").
            WAIT 0.
        }
        CLEARSCREEN.
        log_insertion_state("After insertion coast").
        IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR KUNIVERSE:TIMEWARP:RATE > 1.01
            OR NOT KUNIVERSE:TIMEWARP:ISSETTLED OR NOT SHIP:UNPACKED OR TIME:SECONDS >= latest_ignition {
            log_line("Insertion skipped: carrier did not reach the ignition window ready. Active="
                + (SHIP = KUNIVERSE:ACTIVEVESSEL) + ", rate "
                + KUNIVERSE:TIMEWARP:RATE + "x, settled=" + KUNIVERSE:TIMEWARP:ISSETTLED
                + ", unpacked=" + SHIP:UNPACKED + ", seconds past planned ignition="
                + ROUND(TIME:SECONDS - ignition_time, 2) + " (limit 2).").
            carrier_engine:SHUTDOWN().
            UNLOCK THROTTLE.
            RETURN FALSE.
        }
        SET next_display TO 0.
        coast_display("Planned ignition", ignition_time - TIME:SECONDS, TRUE).
        SET NAVMODE TO "ORBIT".
        SAS OFF.
        WAIT 0.
        SAS ON.
        WAIT 0.5.
        SET SASMODE TO "STABILITYASSIST".
        WAIT 0.
        log_insertion_state("Stability Assist selected after coast").
        LOCAL next_sas_request IS TIME:SECONDS.
        UNTIL (TIME:SECONDS >= ignition_time
            AND SAS AND SASMODE = "RETROGRADE"
            AND VANG(SHIP:FACING:FOREVECTOR, -SHIP:VELOCITY:ORBIT) <= 5)
            OR TIME:SECONDS >= latest_ignition OR SHIP <> KUNIVERSE:ACTIVEVESSEL
            OR NOT SHIP:UNPACKED OR KUNIVERSE:TIMEWARP:RATE > 1.01 {
            coast_display("Planned ignition", ignition_time - TIME:SECONDS, TRUE).
            IF TIME:SECONDS >= next_sas_request AND SAS AND SASMODE <> "RETROGRADE" {
                SET SASMODE TO "RETROGRADE".
                WAIT 0.
                log_insertion_state("Retrograde requested after coast").
                SET next_sas_request TO TIME:SECONDS + 0.5.
            }
            checkpoint_log("Aligning and waiting for timed insertion").
            WAIT 0.
        }
        LOCAL ignition_error IS VANG(SHIP:FACING:FOREVECTOR, -SHIP:VELOCITY:ORBIT).
        log_insertion_state("Insertion ignition check").
        IF TIME:SECONDS >= latest_ignition OR SHIP <> KUNIVERSE:ACTIVEVESSEL
            OR NOT SHIP:UNPACKED OR KUNIVERSE:TIMEWARP:RATE > 1.01
            OR NOT SAS OR SASMODE <> "RETROGRADE" OR ignition_error > 5 {
            log_line("Insertion skipped: error " + ROUND(ignition_error, 2)
                + " deg (limit 5), SAS " + SAS + "/" + SASMODE + ", active="
                + (SHIP = KUNIVERSE:ACTIVEVESSEL) + ", unpacked=" + SHIP:UNPACKED
                + ", warp " + KUNIVERSE:TIMEWARP:RATE + "x, seconds past planned ignition="
                + ROUND(TIME:SECONDS - ignition_time, 2) + " (limit 2).").
            carrier_engine:SHUTDOWN().
            UNLOCK THROTTLE.
            RETURN FALSE.
        }
        log_line("Insertion burn started. Stay on the carrier at 1x.").
        LOCAL arrival_deadline IS TIME:SECONDS + 2 * burn_lead + 10.
        LOCAL next_sample IS TIME:SECONDS + 0.5.
        UNTIL orbit_ready() OR SHIP:PERIAPSIS <= target_pe
            OR SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED
            OR KUNIVERSE:TIMEWARP:RATE > 1.01 OR TIME:SECONDS >= arrival_deadline
            OR VANG(SHIP:FACING:FOREVECTOR, -SHIP:VELOCITY:ORBIT) > 5 {
            SET throttle_cmd TO MAX(0.02, MIN(1, (SHIP:PERIAPSIS - target_pe) / 5000)).
            IF TIME:SECONDS >= next_sample {
                log_insertion_state("Insertion burn").
                SET next_sample TO TIME:SECONDS + 0.5.
            }
            checkpoint_log("").
            WAIT 0.
        }
        LOCAL cutoff_reason IS "target orbit reached".
        IF NOT orbit_ready() {
            IF SHIP:PERIAPSIS <= target_pe {
                SET cutoff_reason TO "periapsis reached the target, but the orbit is outside tolerance".
            } ELSE IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED {
                SET cutoff_reason TO "carrier lost focus or full physics".
            } ELSE IF KUNIVERSE:TIMEWARP:RATE > 1.01 {
                SET cutoff_reason TO "warp exceeded 1x".
            } ELSE IF TIME:SECONDS >= arrival_deadline {
                SET cutoff_reason TO "burn time limit reached".
            } ELSE {
                SET cutoff_reason TO "retrograde error exceeded 5 deg".
            }
        }
        log_insertion_state("Insertion cutoff: " + cutoff_reason).
        SET throttle_cmd TO 0.
        WAIT 0.
        carrier_engine:SHUTDOWN().
        UNLOCK THROTTLE.
        log_line("Insertion ended: " + cutoff_reason + ". Pe " + ROUND(SHIP:PERIAPSIS / 1000, 2)
            + " km, period error " + ROUND(SHIP:OBT:PERIOD - target_period, 2) + " s.").
        transmit_log().
    }

    LOCAL release_lead IS 30.
    LOCAL earliest_release IS 0.
    LOCAL release_deadline IS 0.
    LOCAL manual_check_required IS FALSE.
    LOCAL relay_summary IS "".
    LOCAL verified_releases IS 0.
    UNTIL remaining = 0 {
        IF NOT check_line(orbit_ready(), "Carrier phasing orbit", "Pe "
            + ROUND(SHIP:PERIAPSIS, 1) + " m (minimum 75000 m), Ap error "
            + ROUND(ABS(SHIP:APOAPSIS - target_apoapsis), 1) + " m (limit 1000 m), period error "
            + ROUND(ABS(SHIP:OBT:PERIOD - target_period), 2) + " s (limit "
            + ROUND(period_tolerance, 2) + " s)") {
            log_line("Carrier is outside the phasing orbit tolerance. Releases stopped.").
            RETURN FALSE.
        }
        LOCAL satellite_number IS constellation_size - remaining + 1.
        LOCAL relay_name IS satellites[0]:TAG.
        LOCAL relay_uid IS satellites[0]:UID.
        LOCAL release_label IS relay_name + " (" + satellite_number + " of " + constellation_size + ")".
        IF manual_check_required {
            log_line("After checking the previous relay, press Enter to arm "
                + release_label + " and auto-warp.").
            transmit_log().
            jeblink_wait_for_enter("Waiting for release arming").
        } ELSE {
            IF NOT proceed_unless_aborted("Auto-warp for " + release_label, relay_summary) {
                log_line("No relay released.").
                RETURN FALSE.
            }
        }
        IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT orbit_ready() {
            log_line("Cannot arm auto-warp: active="
                + (SHIP = KUNIVERSE:ACTIVEVESSEL) + ", period error "
                + ROUND(SHIP:OBT:PERIOD - target_period, 2) + " s (limit "
                + ROUND(period_tolerance, 2) + " s). Select the carrier in its phasing orbit and rerun.").
            RETURN FALSE.
        }
        LOCAL seconds_until_release IS time_to_release(earliest_release, release_lead).
        IF (release_deadline > 0 AND TIME:SECONDS + seconds_until_release >= release_deadline) {
            log_line("Scheduled release pass already missed. No warp started.").
            RETURN FALSE.
        }
        IF earliest_release > 0 AND NOT manual_check_required {
            log_line("Verified relay orbit. Automatically armed " + release_label + " for release. Stay on the carrier.").
            transmit_log().
        }
        warp_to_coast_end("release", seconds_until_release).
        SET next_display TO 0.
        IF earliest_release = 0 {
            UNTIL ETA:APOAPSIS > release_lead {
                IF release_abort_requested(release_label) { RETURN FALSE. }
                coast_display(release_label + " release", ETA:APOAPSIS + SHIP:OBT:PERIOD - release_lead, FALSE, TRUE).
                checkpoint_log("Waiting for current release window to pass").
                WAIT 0.
            }
        }
        UNTIL (TIME:SECONDS >= earliest_release AND ETA:APOAPSIS <= release_lead)
            OR (release_deadline > 0 AND TIME:SECONDS >= release_deadline) {
            IF release_abort_requested(release_label) { RETURN FALSE. }
            coast_display(release_label + " release", time_to_release(earliest_release, release_lead), FALSE, TRUE).
            checkpoint_log("Coasting to release").
            WAIT 0.
        }
        IF release_abort_requested(release_label) { RETURN FALSE. }
        CLEARSCREEN.
        FOR fairing IN SHIP:MODULESNAMED("ModuleProceduralFairing") {
            IF fairing:HASEVENT("deploy") OR fairing:HASEVENT("deploy fairing") {
                log_line("No relay released. A deployable fairing remains. Jettison it and restart the carrier.").
                RETURN FALSE.
            }
        }
        IF (release_deadline > 0 AND TIME:SECONDS >= release_deadline)
            OR ETA:APOAPSIS < release_lead - 5 OR NOT orbit_ready()
            OR SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED
            OR KUNIVERSE:TIMEWARP:RATE > 1.01 OR NOT KUNIVERSE:TIMEWARP:ISSETTLED OR SHIP:THRUST > 0 {
            IF ETA:APOAPSIS < release_lead - 5 OR (release_deadline > 0 AND TIME:SECONDS >= release_deadline) {
                log_line("Release window missed. ETA to apoapsis: " + ROUND(ETA:APOAPSIS, 1) + " s.").
            }
            IF NOT orbit_ready() {
                log_line("Carrier outside phasing orbit tolerance. Period error "
                    + ROUND(SHIP:OBT:PERIOD - target_period, 2) + " s, limit " + ROUND(period_tolerance, 2) + " s.").
            }
            IF SHIP <> KUNIVERSE:ACTIVEVESSEL OR NOT SHIP:UNPACKED {
                log_line("Select the carrier and return to full physics.").
            }
            IF KUNIVERSE:TIMEWARP:RATE > 1.01 OR NOT KUNIVERSE:TIMEWARP:ISSETTLED {
                log_line("Warp had not settled at 1x. Actual rate: " + KUNIVERSE:TIMEWARP:RATE + "x.").
            }
            IF SHIP:THRUST > 0 { log_line("Release blocked by thrust: " + ROUND(SHIP:THRUST, 2) + " kN."). }
            log_line("No satellite released. Restart the carrier script with the original count to replan.").
            RETURN FALSE.
        }

        SET satellites TO SHIP:PARTSNAMED("probeCoreCube").
        IF satellites:LENGTH <> remaining OR satellites[0]:UID <> relay_uid {
            log_line("Mounted satellite count or release order changed. Releases stopped.").
            RETURN FALSE.
        }
        LOCAL separator IS satellites[0]:DECOUPLER.
        IF NOT separator:ISTYPE("Separator") {
            log_line("No separator found for the next QBE. Releases stopped.").
            RETURN FALSE.
        }
        IF NOT separator:HASMODULE("ModuleAnchoredDecoupler") {
            log_line("Expected the Jeblink radial decoupler. Releases stopped.").
            RETURN FALSE.
        }
        LOCAL release_module IS separator:GETMODULE("ModuleAnchoredDecoupler").
        LOCAL use_event IS release_module:HASEVENT("Decouple").
        IF NOT use_event AND NOT release_module:HASACTION("Decouple") {
            log_line("Decouple unavailable. Events: " + release_module:ALLEVENTNAMES
                + ", actions: " + release_module:ALLACTIONNAMES).
            RETURN FALSE.
        }
        LOCAL probe_batteries IS LIST().
        FOR resource IN satellites[0]:RESOURCES {
            IF resource:NAME = "ElectricCharge" { probe_batteries:ADD(resource). }
        }
        IF probe_batteries:LENGTH <> 1 {
            log_line("Release blocked: expected one QBE battery, found " + probe_batteries:LENGTH + ".").
            RETURN FALSE.
        }
        LOCAL probe_battery IS probe_batteries[0].
        LOCAL battery_was_enabled IS probe_battery:ENABLED.
        // Enable the reserve while the carrier can still power the probe processor.
        IF NOT battery_was_enabled AND probe_battery:TOGGLEABLE {
            SET probe_battery:ENABLED TO TRUE.
        }
        log_line("Probe battery at release: " + ROUND(probe_battery:AMOUNT, 2) + "/"
            + probe_battery:CAPACITY + " EC, flow=" + probe_battery:ENABLED + ".").
        IF NOT probe_battery:ENABLED OR probe_battery:AMOUNT <= 0 {
            IF NOT battery_was_enabled AND probe_battery:ENABLED {
                SET probe_battery:ENABLED TO FALSE.
            }
            log_line("Release blocked: probe battery needs charge and enabled flow.").
            RETURN FALSE.
        }
        log_line("Releasing satellite at ETA Ap " + ROUND(ETA:APOAPSIS, 2)
            + " s, carrier period error " + ROUND(SHIP:OBT:PERIOD - target_period, 2) + " s.").
        log_line("Releasing relay " + relay_name + ", QBE UID " + relay_uid + ".").
        log_line("Carrier message queues before release: vessel " + SHIP:MESSAGES:LENGTH
            + ", processor " + CORE:MESSAGES:LENGTH + ".", FALSE).
        IF use_event {
            release_module:DOEVENT("Decouple").
        } ELSE {
            release_module:DOACTION("Decouple", TRUE).
        }
        LOCAL release_time IS TIME:SECONDS.
        LOCAL verify_deadline IS release_time + 2.
        WAIT UNTIL SHIP:PARTSNAMED("probeCoreCube"):LENGTH <> remaining
            OR TIME:SECONDS >= verify_deadline.
        IF SHIP:PARTSNAMED("probeCoreCube"):LENGTH = remaining AND NOT battery_was_enabled {
            SET probe_battery:ENABLED TO FALSE.
        }
        LOCAL mounted_after_release IS SHIP:PARTSNAMED("probeCoreCube"):LENGTH.
        IF NOT check_line(mounted_after_release = remaining - 1, "Relay separation",
            (remaining - mounted_after_release) + " detached, required 1, within 2 s") {
            log_line("Expected exactly one QBE to detach. Releases stopped.").
            RETURN FALSE.
        }
        SET remaining TO mounted_after_release.
        SET satellites TO SHIP:PARTSNAMED("probeCoreCube").
        SET SHIP:NAME TO carrier_name.
        SET SHIP:TYPE TO "Probe".
        log_line(release_label + " released. Stay on the carrier at 1x while the probe circularizes.").
        log_line("Carrier message queues after release: vessel " + SHIP:MESSAGES:LENGTH
            + ", processor " + CORE:MESSAGES:LENGTH + ".", FALSE).
        transmit_log().
        SET earliest_release TO release_time + (coast_laps - 0.5) * target_period.
        SET release_deadline TO earliest_release + target_period.
        LOCAL relay_fields IS relay_name:SPLIT("-").
        LOCAL relay_vessel_name IS "Jeblink JL-" + train_name + "-RELAY-" + relay_fields[1].
        SET relay_summary TO wait_for_relay_report(relay_name, relay_uid, relay_vessel_name, release_time).
        SET manual_check_required TO relay_summary = "".
        IF unattended {
            IF NOT check_line(NOT manual_check_required, "Relay circularisation report",
                relay_name + ", " + ROUND(TIME:SECONDS - release_time, 2)
                + " s since release, requires a verified success report within 90 s") {
                RETURN FALSE.
            }
            SET verified_releases TO verified_releases + 1.
            IF verified_releases = unattended_releases { RETURN TRUE. }
        }
    }
    RETURN TRUE.
}
