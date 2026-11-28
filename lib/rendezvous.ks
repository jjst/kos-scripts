@LAZYGLOBAL OFF.

FUNCTION rendezvous_plane_error {
    PARAMETER station.
    LOCAL origin IS SHIP:BODY:POSITION.
    RETURN VANG(VCRS(SHIP:POSITION - origin, SHIP:VELOCITY:ORBIT),
        VCRS(station:POSITION - origin, station:VELOCITY:ORBIT)).
}

LOCAL FUNCTION hohmann_timing {
    PARAMETER station, radius_from, parking_period.
    LOCAL radius_to IS station:OBT:SEMIMAJORAXIS.
    LOCAL mu_body IS SHIP:BODY:MU.
    LOCAL transfer_axis IS (radius_from + radius_to) / 2.
    LOCAL flight_time IS CONSTANT:PI * SQRT(transfer_axis^3 / mu_body).
    LOCAL station_rate IS 360 / station:OBT:PERIOD.
    RETURN LEXICON("flight_time", flight_time, "station_rate", station_rate,
        "relative_rate", 360 / parking_period - station_rate, "lead", 180 - station_rate * flight_time).
}

// Estimate the first usable departure window for two nearly circular orbits.
FUNCTION plan_hohmann_to {
    PARAMETER station, minimum_wait IS 90.
    LOCAL timing IS hohmann_timing(station, SHIP:OBT:SEMIMAJORAXIS, SHIP:OBT:PERIOD).
    LOCAL radial IS (SHIP:POSITION - SHIP:BODY:POSITION):NORMALIZED.
    LOCAL tangential IS VXCL(radial, SHIP:VELOCITY:ORBIT):NORMALIZED.
    LOCAL station_position IS station:POSITION - SHIP:BODY:POSITION.
    LOCAL phase_angle IS MOD(360 + ARCTAN2(VDOT(station_position, tangential), VDOT(station_position, radial)), 360).
    LOCAL wait_time IS MOD(phase_angle - timing["lead"] + 360, 360) / timing["relative_rate"].
    IF wait_time < minimum_wait { SET wait_time TO wait_time + 360 / timing["relative_rate"]. }
    RETURN LEXICON("ut", TIME:SECONDS + wait_time, "phase", phase_angle, "lead", timing["lead"],
        "wait", wait_time, "flight_time", timing["flight_time"]).
}

// The station advances relative to the rotating pad while we wait.
FUNCTION plan_rendezvous_launch {
    PARAMETER station, parking_altitude, ascent_time, ascent_angle, parking_wait IS 60.
    LOCAL radius_from IS SHIP:BODY:RADIUS + parking_altitude.
    LOCAL parking_period IS 2 * CONSTANT:PI * SQRT(radius_from^3 / SHIP:BODY:MU).
    LOCAL timing IS hohmann_timing(station, radius_from, parking_period).
    LOCAL pad_rate IS 360 / SHIP:BODY:ROTATIONPERIOD.
    LOCAL station_over_pad IS timing["station_rate"] - pad_rate.
    IF station_over_pad <= 0 OR timing["relative_rate"] <= 0 { RETURN LEXICON(). }
    LOCAL body_position IS SHIP:BODY:POSITION.
    LOCAL pad_radial IS (SHIP:POSITION - body_position):NORMALIZED.
    LOCAL east_direction IS HEADING(90, 0):FOREVECTOR.
    LOCAL station_position IS station:POSITION - body_position.
    LOCAL phase_now IS ARCTAN2(VDOT(station_position, east_direction), VDOT(station_position, pad_radial)).
    LOCAL target_phase IS timing["lead"] + parking_wait * timing["relative_rate"].
    LOCAL earliest_wait IS 35.
    LOCAL earliest_phase IS phase_now + station_over_pad * earliest_wait
        + timing["station_rate"] * ascent_time - ascent_angle.
    LOCAL delay_angle IS MOD(MOD(target_phase - earliest_phase, 360) + 360, 360).
    LOCAL pad_wait IS earliest_wait + delay_angle / station_over_pad.
    RETURN LEXICON("ut", TIME:SECONDS + pad_wait, "wait", pad_wait,
        "cutoff_phase", target_phase, "lead", timing["lead"], "parking_wait", parking_wait).
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
