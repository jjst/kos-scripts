@LAZYGLOBAL OFF.

FUNCTION rendezvous_plane_error {
    PARAMETER station.
    LOCAL origin IS SHIP:BODY:POSITION.
    RETURN VANG(VCRS(SHIP:POSITION - origin, SHIP:VELOCITY:ORBIT),
        VCRS(station:POSITION - origin, station:VELOCITY:ORBIT)).
}

// Estimate the first usable departure window for two nearly circular orbits.
FUNCTION plan_hohmann_to {
    PARAMETER station, minimum_wait IS 90.
    LOCAL radius_from IS SHIP:OBT:SEMIMAJORAXIS.
    LOCAL radius_to IS station:OBT:SEMIMAJORAXIS.
    LOCAL mu_body IS SHIP:BODY:MU.
    LOCAL transfer_axis IS (radius_from + radius_to) / 2.
    LOCAL flight_time IS CONSTANT:PI * SQRT(transfer_axis^3 / mu_body).
    LOCAL station_rate IS 360 / station:OBT:PERIOD.
    LOCAL relative_rate IS 360 / SHIP:OBT:PERIOD - station_rate.
    LOCAL lead_angle IS 180 - station_rate * flight_time.
    LOCAL radial IS (SHIP:POSITION - SHIP:BODY:POSITION):NORMALIZED.
    LOCAL tangential IS VXCL(radial, SHIP:VELOCITY:ORBIT):NORMALIZED.
    LOCAL station_position IS station:POSITION - SHIP:BODY:POSITION.
    LOCAL phase_angle IS MOD(360 + ARCTAN2(VDOT(station_position, tangential), VDOT(station_position, radial)), 360).
    LOCAL wait_time IS MOD(phase_angle - lead_angle + 360, 360) / relative_rate.
    IF wait_time < minimum_wait { SET wait_time TO wait_time + 360 / relative_rate. }
    RETURN LEXICON("ut", TIME:SECONDS + wait_time, "phase", phase_angle, "lead", lead_angle,
        "wait", wait_time, "flight_time", flight_time).
}

// The circular-orbit estimate seeds the live node preview.
FUNCTION rendezvous_departure_burn {
    PARAMETER station, departure_ut.
    LOCAL radius_now IS SHIP:OBT:SEMIMAJORAXIS.
    LOCAL radius_target IS station:OBT:SEMIMAJORAXIS.
    LOCAL delta_v IS SQRT(SHIP:BODY:MU / radius_now) * (SQRT(2 * radius_target / (radius_now + radius_target)) - 1).
    RETURN LEXICON("ut", departure_ut, "prograde", delta_v, "normal", 0, "radial", 0, "label", "Station transfer").
}

FUNCTION closest_approach {
    PARAMETER station, from_ut, to_ut.
    LOCAL best_ut IS from_ut.
    LOCAL best_distance IS (POSITIONAT(SHIP, from_ut) - POSITIONAT(station, from_ut)):MAG.
    LOCAL step_size IS 10.
    LOCAL first_ut IS from_ut + step_size.
    LOCAL last_ut IS to_ut.
    FROM { LOCAL pass_number IS 1. } UNTIL pass_number > 2 STEP { SET pass_number TO pass_number + 1. } DO {
        FROM { LOCAL sample_ut IS first_ut. } UNTIL sample_ut > last_ut STEP { SET sample_ut TO sample_ut + step_size. } DO {
            LOCAL distance IS (POSITIONAT(SHIP, sample_ut) - POSITIONAT(station, sample_ut)):MAG.
            IF distance < best_distance {
                SET best_distance TO distance.
                SET best_ut TO sample_ut.
            }
        }
        SET first_ut TO MAX(from_ut, best_ut - step_size).
        SET last_ut TO MIN(to_ut, best_ut + step_size).
        SET step_size TO 1.
    }
    RETURN LEXICON("ut", best_ut, "distance", best_distance).
}
