@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/burn.ks"
// #include "0:/lib/rendezvous.ks"

FUNCTION fly_rendezvous_transfer {
    PARAMETER station_name, maximum_plane_error IS 0.1, minimum_window_wait IS 90.
    LOCAL stations IS LIST().
    LIST TARGETS IN stations.
    LOCAL matches IS LIST().
    FOR vessel_item IN stations {
        IF vessel_item:NAME = station_name { matches:ADD(vessel_item). }
    }
    IF NOT check_line(matches:LENGTH = 1, "Target station", station_name + ", "
        + matches:LENGTH + " matching vessels, required 1") { RETURN. }
    LOCAL station IS matches[0].
    IF NOT check_line(SHIP = KUNIVERSE:ACTIVEVESSEL AND SHIP:STATUS = "ORBITING"
        AND station:BODY = SHIP:BODY AND station:STATUS = "ORBITING"
        AND station:PERIAPSIS > SHIP:APOAPSIS,
        "Transfer orbits", SHIP:NAME + " Ap " + ROUND(SHIP:APOAPSIS, 1)
        + " m, " + station:NAME + " Pe " + ROUND(station:PERIAPSIS, 1)
        + " m, required active chaser in a lower orbit around the same body") { RETURN. }
    LOCAL plane_error IS rendezvous_plane_error(station).
    IF NOT check_line(plane_error <= maximum_plane_error AND SHIP:OBT:ECCENTRICITY <= 0.01 AND station:OBT:ECCENTRICITY <= 0.01,
        "Transfer geometry", "plane difference " + ROUND(plane_error, 4)
        + " deg (limit " + maximum_plane_error + "), chaser eccentricity " + ROUND(SHIP:OBT:ECCENTRICITY, 5)
        + ", target eccentricity " + ROUND(station:OBT:ECCENTRICITY, 5) + " (limit 0.01 each)") { RETURN. }
    IF NOT check_line(CAREER():CANMAKENODES AND NOT HASNODE, "Node planning",
        "nodes available=" + CAREER():CANMAKENODES + ", existing node=" + HASNODE
        + ", requires node access and an empty flight plan") { RETURN. }
    SET TARGET TO station.
    LOCAL departure_window IS plan_hohmann_to(station, minimum_window_wait).
    info_line("Departure window", "current phase " + ROUND(departure_window["phase"], 3)
        + " deg, Hohmann lead " + ROUND(departure_window["lead"], 3) + " deg, estimated wait "
        + ROUND(departure_window["wait"], 1) + " s, flight time " + ROUND(departure_window["flight_time"], 1) + " s").
    transmit_log().

    LOCAL best_plan IS LEXICON().
    LOCAL best_score IS 1000000.
    LOCAL best_distance IS -1.
    LOCAL best_apoapsis IS 0.
    LOCAL target_ap IS station:OBT:SEMIMAJORAXIS - SHIP:BODY:RADIUS.
    LOCAL start_radius IS SHIP:OBT:SEMIMAJORAXIS.
    LOCAL apoapsis_sensitivity IS 4 * start_radius / SQRT(SHIP:BODY:MU / start_radius).
    LOCAL burn_setup_time IS 20.
    LOCAL first_offset IS MAX(-40, 5 * CEILING((TIME:SECONDS + burn_setup_time + 5 - departure_window["ut"]) / 5)).
    FROM { LOCAL offset_seconds IS first_offset. } UNTIL offset_seconds > 40
        STEP { SET offset_seconds TO offset_seconds + 5. } DO {
        LOCAL candidate IS rendezvous_departure_burn(station, departure_window["ut"] + offset_seconds).
        LOCAL preview IS NODE(candidate["ut"], candidate["radial"], candidate["normal"], candidate["prograde"]).
        ADD preview.
        WAIT 0.
        FROM { LOCAL correction IS 1. } UNTIL correction > 3 STEP { SET correction TO correction + 1. } DO {
            LOCAL altitude_error IS target_ap - preview:ORBIT:APOAPSIS.
            IF ABS(altitude_error) <= 25 { BREAK. }
            SET preview:PROGRADE TO MAX(0, MIN(2 * candidate["prograde"],
                preview:PROGRADE + altitude_error / apoapsis_sensitivity)).
            WAIT 0.
        }
        SET candidate["prograde"] TO preview:PROGRADE.
        LOCAL arrival_ut IS candidate["ut"] + departure_window["flight_time"].
        LOCAL candidate_approach IS closest_approach(station, arrival_ut - 120, arrival_ut + 120).
        LOCAL candidate_ap IS preview:ORBIT:APOAPSIS.
        REMOVE preview.
        LOCAL score IS ABS(candidate_approach["distance"] - 1500).
        IF score < best_score AND ABS(candidate_ap - target_ap) <= 400 {
            SET best_plan TO candidate.
            SET best_score TO score.
            SET best_distance TO candidate_approach["distance"].
            SET best_apoapsis TO candidate_ap.
        }
        info_line("Transfer preview", "departure offset " + offset_seconds + " s, encounter "
            + ROUND(candidate_approach["distance"], 1) + " m, Ap " + ROUND(candidate_ap, 1) + " m, prograde "
            + ROUND(candidate["prograde"], 3) + " m/s").
    }
    LOCAL time_until_departure IS -1.
    IF best_plan:LENGTH > 0 { SET time_until_departure TO best_plan["ut"] - TIME:SECONDS. }
    IF NOT check_line(best_plan:LENGTH > 0 AND best_distance >= 500 AND best_distance <= 5000
        AND time_until_departure >= burn_setup_time, "Transfer preview accepted",
        "encounter " + ROUND(best_distance, 1) + " m (required 500 to 5000 m), predicted Ap "
        + ROUND(best_apoapsis, 1) + " m (target " + ROUND(target_ap, 1)
        + " m, tolerance 400 m), departure in " + ROUND(time_until_departure, 1)
        + " s (minimum " + burn_setup_time + " s)") { RETURN. }
    transmit_log().
    LOCAL result IS execute_burn(best_plan, LEXICON("use_node", TRUE)).
    IF NOT check_line(result["success"], "Outbound transfer burn", result["reason"]
        + ", delivered " + ROUND(result["delivered_dv"], 3) + " m/s, planned "
        + ROUND(best_plan["prograde"], 3) + " m/s") { RETURN. }
    check_line(ABS(SHIP:APOAPSIS - target_ap) <= 400, "Transfer apoapsis",
        ROUND(SHIP:APOAPSIS, 1) + " m, target " + ROUND(target_ap, 1) + " m, tolerance 400 m").
    LOCAL expected_arrival IS best_plan["ut"] + departure_window["flight_time"].
    LOCAL actual_encounter IS closest_approach(station, expected_arrival - 120, expected_arrival + 120).
    LOCAL encounter_ut IS actual_encounter["ut"].
    LOCAL relative_speed IS (VELOCITYAT(SHIP, encounter_ut):ORBIT - VELOCITYAT(station, encounter_ut):ORBIT):MAG.
    check_line(actual_encounter["distance"] <= 5000, "Predicted closest approach",
        ROUND(actual_encounter["distance"], 1) + " m (limit 5000 m) in "
        + ROUND(encounter_ut - TIME:SECONDS, 1) + " s, relative speed " + ROUND(relative_speed, 2) + " m/s").
}
