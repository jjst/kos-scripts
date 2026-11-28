@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/launch.ks"
// #include "0:/lib/burn.ks"
// #include "0:/lib/rendezvous.ks"
// #include "0:/lib/rendezvous_transfer.ks"
// #include "0:/lib/rcs.ks"
// #include "0:/lib/rendezvous_approach.ks"
// #include "0:/lib/docking.ks"

RUNONCEPATH("0:/lib/telemetry.ks").
RUNONCEPATH("0:/lib/launch.ks").
RUNONCEPATH("0:/lib/burn.ks").
RUNONCEPATH("0:/lib/rendezvous.ks").
RUNONCEPATH("0:/lib/rendezvous_transfer.ks").
RUNONCEPATH("0:/lib/rcs.ks").
RUNONCEPATH("0:/lib/rendezvous_approach.ks").
RUNONCEPATH("0:/lib/docking.ks").

LOCAL FUNCTION docktopus_from_pad {
    LOCAL station_name IS "Hope Station".
    LOCAL parking_altitude IS 80000.
    LOCAL last_ascent_stage IS 1.
    LOCAL maximum_plane_error IS 0.25.
    // Two prior due-east Docktopus launches covered about 33.36 deg in 293.3 s.
    LOCAL ascent_time IS 293.3.
    LOCAL ascent_angle IS 33.36.
    LOCAL parking_wait IS 60.
    LOCAL minimum_window_wait IS 20.
    LOCAL phase_tolerance IS 0.5.

    IF NOT check_line(SHIP:NAME = "Docktopus Jr" AND SHIP:STATUS = "PRELAUNCH"
        AND SHIP:BODY:NAME = "Kerbin", "Docktopus pad vessel",
        SHIP:NAME + " / " + SHIP:STATUS + " on " + SHIP:BODY:NAME
        + ", required Docktopus Jr on a Kerbin launchpad") {
        PRINT "Launch stopped before ignition. Load Docktopus Jr. on the pad to start this mission.".
        RETURN.
    }
    CLEARSCREEN.
    PRINT "Select Docktopus Jr. and set time warp to 1x for pad preflight.".
    UNTIL SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:UNPACKED
        AND KUNIVERSE:TIMEWARP:ISSETTLED AND KUNIVERSE:TIMEWARP:RATE <= 1.01 {
        checkpoint_log("Waiting for pad flight controls").
        WAIT 0.
    }

    LOCAL vessels IS LIST().
    LOCAL stations IS LIST().
    LIST TARGETS IN vessels.
    FOR candidate IN vessels {
        IF candidate:NAME = station_name { stations:ADD(candidate). }
    }
    IF NOT check_line(stations:LENGTH = 1, "Station available",
        station_name + ", " + stations:LENGTH + " matching vessels, required 1") {
        PRINT "Launch stopped before ignition. Confirm Hope Station is in this save.".
        RETURN.
    }
    LOCAL station IS stations[0].
    LOCAL plane_bound IS ABS(SHIP:LATITUDE) + ABS(station:OBT:INCLINATION).
    IF NOT check_line(station:BODY = SHIP:BODY AND station:STATUS = "ORBITING"
        AND station:PERIAPSIS > parking_altitude + 3000 AND station:OBT:ECCENTRICITY <= 0.01
        AND plane_bound <= maximum_plane_error, "Station orbit before launch",
        station:NAME + " at " + station:BODY:NAME + ", " + station:STATUS + ", Pe "
        + ROUND(station:PERIAPSIS, 1) + " m (required > 83000 m), eccentricity "
        + ROUND(station:OBT:ECCENTRICITY, 5) + " (limit 0.01), due-east plane difference bound "
        + ROUND(plane_bound, 3) + " deg (limit " + maximum_plane_error + " deg)") {
        PRINT "Launch stopped before ignition. Check Hope Station's orbit and use the Kerbin equatorial pad.".
        RETURN.
    }

    LOCAL rcs_count IS 0.
    FOR thruster IN SHIP:RCS {
        IF thruster:ENABLED AND thruster:AVAILABLETHRUST > 0 { SET rcs_count TO rcs_count + 1. }
    }
    IF NOT check_line(STAGE:NUMBER > last_ascent_stage AND SHIP:DOCKINGPORTS:LENGTH = 1
        AND rcs_count > 0 AND CAREER():CANMAKENODES AND NOT HASNODE, "Mission hardware and controls",
        "pad stage " + STAGE:NUMBER + " (last ascent stage " + last_ascent_stage + "), "
        + SHIP:DOCKINGPORTS:LENGTH + " docking ports (required 1), " + rcs_count
        + " enabled RCS thrusters (required > 0), node access=" + CAREER():CANMAKENODES
        + ", existing node=" + HASNODE) {
        PRINT "Launch stopped before ignition. Check the probe's staging, docking port, RCS and flight plan.".
        RETURN.
    }
    transmit_log().
    CLEARSCREEN.
    TERMINAL:INPUT:CLEAR().
    PRINT "Press Enter to arm Docktopus Jr. for Hope Station.".
    PRINT "Stay on Docktopus Jr. It will auto-warp on the pad, then launch.".
    PRINT "Press any other key to cancel before ignition.".
    UNTIL TERMINAL:INPUT:HASCHAR {
        checkpoint_log("Waiting to arm Docktopus Jr.").
        WAIT 0.
    }
    IF TERMINAL:INPUT:GETCHAR() <> TERMINAL:INPUT:RETURN {
        log_line("Launch cancelled before ignition. Rerun this boot script to arm again.").
        RETURN.
    }

    CLEARSCREEN.
    LOCAL launch_window IS plan_rendezvous_launch(station, parking_altitude, ascent_time, ascent_angle, parking_wait).
    IF NOT check_line(launch_window:LENGTH > 0, "Timed launch solution",
        "Hope Station must advance relative to the pad and lag the parking orbit") {
        PRINT "Launch stopped before ignition. Check the station's orbit before retrying.".
        RETURN.
    }
    info_line("Pad launch window", "ignition UT " + ROUND(launch_window["ut"], 2)
        + " s (pad wait " + ROUND(launch_window["wait"], 1) + " s), predicted phase at circularisation "
        + ROUND(launch_window["cutoff_phase"], 3) + " deg, Hohmann lead " + ROUND(launch_window["lead"], 3)
        + " deg, expected parking wait " + ROUND(launch_window["parking_wait"], 1) + " s, calibration "
        + ascent_time + " s / " + ascent_angle + " deg").
    info_line("Mission phase", "Launch east to an 80 km Kerbin parking orbit").
    LOCAL result IS launch_to_orbit(LEXICON("heading", 90, "target_altitude", parking_altitude,
        "minimum_pe", 75000, "last_stage", last_ascent_stage, "fairing_policy", "none",
        "half_dv_timing", TRUE, "launch_ut", launch_window["ut"])).
    IF NOT check_line(result["success"], "Parking orbit reached", result["reason"])
        OR NOT check_line(result["remaining_dv"] >= 150, "Rendezvous reserve",
            ROUND(result["remaining_dv"], 1) + " m/s, minimum 150 m/s") {
        PRINT "Mission stopped after the launch attempt. Check the logged orbit and fuel before retrying.".
        RETURN.
    }

    LOCAL parking_window IS plan_hohmann_to(station, minimum_window_wait).
    LOCAL phase_error IS MOD(parking_window["phase"] - launch_window["cutoff_phase"] + 540, 360) - 180.
    LOCAL phase_detail IS "measured " + ROUND(parking_window["phase"], 3)
        + " deg, predicted " + ROUND(launch_window["cutoff_phase"], 3) + " deg, error "
        + ROUND(phase_error, 3) + " deg (desired magnitude <= " + phase_tolerance + " deg), transfer ETA "
        + ROUND(parking_window["wait"], 1) + " s (target " + parking_wait + " s)".
    IF ABS(phase_error) > phase_tolerance OR parking_window["wait"] > SHIP:OBT:PERIOD {
        warn_line("Timed launch outcome", phase_detail).
    } ELSE {
        check_line(TRUE, "Timed launch outcome", phase_detail).
    }
    info_line("Mission phase", "Plan and fly the transfer to " + station_name).
    fly_rendezvous_transfer(station_name, maximum_plane_error, minimum_window_wait).
    IF log_failure_count() > 0 {
        PRINT "Mission stopped during transfer. Check the last transfer result before attempting the approach.".
        RETURN.
    }

    info_line("Mission phase", "Intercept " + station_name + " and close to within 100 m").
    fly_rendezvous_approach(station_name).
    IF log_failure_count() > 0 {
        PRINT "Mission stopped during approach. Check the range and relative velocity before attempting docking.".
        RETURN.
    }

    info_line("Mission phase", "Dock to " + station_name + " on RCS").
    dock_to_station(station_name, LEXICON("open_chaser_shield", TRUE)).
}

open_log("docktopus-mission").
docktopus_from_pad().
transmit_log().
