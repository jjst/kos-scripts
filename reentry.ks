// ============================================================
//  reentry.ks — atmospheric guidance and land handoff
// ============================================================
//  Manages the high-energy reentry profile, then hands off to
//  land_guided.ks only after the vessel reaches the descent envelope.

PARAMETER airbrake_control_mode IS "pid".
PARAMETER trajectories_profile_id IS "proxy".
PARAMETER custom_fixed_airbrake_angle_deg IS -1.
PARAMETER entry_corridor_id IS "trajectories_miss".
PARAMETER target_entry_fpa_down_deg IS -1.
PARAMETER predicted_entry_fpa_down_deg IS -1.
PARAMETER target_deorbit_phase_angle_deg IS -1.
PARAMETER actual_deorbit_burn_phase_angle_deg IS -1.

// --- CONFIG (edit these) ------------------------------------
SET entry_telemetry_interval TO 20.
SET predictor_telemetry_sample_interval TO 2.
SET predictor_telemetry_checkpoint_interval TO 20.
SET entry_brakes_enabled TO TRUE.
SET entry_brakes_deploy_alt_meters TO 70000.
SET entry_brakes_retract_speed_mps TO 1200.
// Keep actual vessel AoA independent from the Trajectories descent profile.
// Trajectories does not model airbrake drag, while this script uses a PID to
// vary airbrake deployment as its primary way to shed velocity and steer the
// predicted impact. deorbit.ks uses a separately calibrated AoA profile as a
// proxy for that missing drag in Trajectories' prediction.
SET entry_aoa_deg TO 10.
SET entry_aoa_retract_speed_mps TO 1200.
SET entry_roll_correction_gain TO 0.001.
SET airbrake_pid_kp TO 0.001.
SET airbrake_pid_ki TO 0.000001.
SET airbrake_pid_kd TO 0.
SET airbrake_pid_epsilon TO 1000.
SET airbrake_pid_gain_ref_alt_meters TO 100000.
SET airbrake_base_angle TO 90.
// Aerodynamic-survivability testing established 60-90 deg as the safe control
// envelope. Fixed test modes may still command lower experimental angles, but
// closed-loop PID guidance must never command below this minimum.
SET airbrake_min_angle TO 60.
SET airbrake_fixed30_angle TO 30.
SET airbrake_fixed45_angle TO 45.
SET airbrake_fixed50_angle TO 50.
SET airbrake_fixed60_angle TO 60.
SET airbrake_actuator_speed_degps TO 20.
SET airbrake_authority_command_percent TO 0.
SET entry_orbit_retro_alt_meters TO 70000.
SET reentry_handoff_alt_meters TO 20000.
SET reentry_guided_land_alt_meters TO 5000.
SET reentry_handoff_speed_mps TO 1400.
SET reentry_handoff_tr_miss_meters TO 5000.
SET monitor_telemetry_interval TO 5.
SET monitor_throttle_pid_kp TO 0.0001.
SET monitor_throttle_pid_ki TO 0.00000005.
SET monitor_throttle_pid_kd TO 0.0002.
SET monitor_throttle_pid_max_throttle TO 1.0.
SET monitor_throttle_pid_epsilon TO 50.
SET land_script_path TO "1:/land_guided.ks".
SET land_unguided_script_path TO "1:/land_unguided.ks".
SET pad_geo TO LATLNG(-0.0972, -74.5577).
SET log_path TO "reentry.log".
SET predictor_telemetry_start_time TO TIME:SECONDS.
SET predictor_telemetry_real_start_time TO KUNIVERSE:REALTIME.
SET predictor_telemetry_run_id TO FLOOR(predictor_telemetry_real_start_time).
SET predictor_telemetry_base_name TO "reentry_telemetry_" + predictor_telemetry_run_id + "_" + airbrake_control_mode + "_" + trajectories_profile_id + "_" + entry_corridor_id.
SET predictor_telemetry_segment_index TO 0.
SET predictor_telemetry_path TO "1:/" + predictor_telemetry_base_name + "_part_" + predictor_telemetry_segment_index + ".json".
SET predictor_telemetry_run TO LEXICON().
SET predictor_telemetry_document TO LEXICON().
SET predictor_telemetry_samples TO LIST().
SET predictor_telemetry_events TO LIST().
SET predictor_telemetry_pending_paths TO LIST().
SET predictor_telemetry_total_samples TO 0.
SET predictor_telemetry_next_sample TO predictor_telemetry_start_time.
SET predictor_telemetry_next_checkpoint TO predictor_telemetry_start_time + predictor_telemetry_checkpoint_interval.
SET predictor_telemetry_last_sample_time TO predictor_telemetry_start_time.
SET predictor_telemetry_last_airspeed TO SHIP:AIRSPEED.
SET predictor_telemetry_last_airbrake_count TO SHIP:PARTSTAGGED("airbrake"):LENGTH.
SET predictor_telemetry_initial_part_count TO SHIP:PARTS:LENGTH.
SET predictor_telemetry_last_part_count TO predictor_telemetry_initial_part_count.
SET airbrake_last_command_deg TO -1.
SET airbrake_next_command_verification TO predictor_telemetry_start_time.
SET airbrake_angle_reassertion_count TO 0.
SET airbrake_authority_original_fields_percent TO LIST().
SET airbrake_authority_locked TO FALSE.
// ------------------------------------------------------------

FUNCTION clamp {
    PARAMETER value, min_value, max_value.
    RETURN MIN(max_value, MAX(min_value, value)).
}

FUNCTION log_line {
    PARAMETER msg.
    PRINT msg.
    LOG msg TO log_path.
}

FUNCTION configured_fixed_airbrake_angle {
    IF airbrake_control_mode = "fixed" {
        RETURN custom_fixed_airbrake_angle_deg.
    }
    IF airbrake_control_mode = "fixed30" {
        RETURN airbrake_fixed30_angle.
    }
    IF airbrake_control_mode = "fixed45" {
        RETURN airbrake_fixed45_angle.
    }
    IF airbrake_control_mode = "fixed50" {
        RETURN airbrake_fixed50_angle.
    }
    IF airbrake_control_mode = "fixed60" {
        RETURN airbrake_fixed60_angle.
    }
    IF airbrake_control_mode = "fixed90" {
        RETURN airbrake_base_angle.
    }
    RETURN 0.
}

FUNCTION is_fixed_airbrake_mode {
    RETURN airbrake_control_mode = "fixed" OR airbrake_control_mode = "fixed30" OR airbrake_control_mode = "fixed45" OR airbrake_control_mode = "fixed50" OR airbrake_control_mode = "fixed60" OR airbrake_control_mode = "fixed90".
}

FUNCTION airbrake_angle_readbacks {
    LOCAL angles IS LIST().
    FOR p IN SHIP:PARTSTAGGED("airbrake") {
        IF p:HASMODULE("ModuleAeroSurface") {
            angles:ADD(p:GETMODULE("ModuleAeroSurface"):GETFIELD("deploy angle")).
        }
    }
    RETURN angles.
}

FUNCTION airbrake_authority_readbacks {
    LOCAL limits IS LIST().
    FOR p IN SHIP:PARTSTAGGED("airbrake") {
        IF p:HASMODULE("ModuleAeroSurface") {
            limits:ADD(p:GETMODULE("ModuleAeroSurface"):GETFIELD("authority limiter")).
        }
    }
    RETURN limits.
}

FUNCTION lock_airbrake_control_authority {
    IF airbrake_authority_locked {
        RETURN FALSE.
    }
    SET airbrake_authority_original_fields_percent TO LIST().
    FOR p IN SHIP:PARTSTAGGED("airbrake") {
        IF p:HASMODULE("ModuleAeroSurface") {
            LOCAL module IS p:GETMODULE("ModuleAeroSurface").
            airbrake_authority_original_fields_percent:ADD(module:GETFIELD("authority limiter")).
            module:SETFIELD("authority limiter", airbrake_authority_command_percent).
        }
    }
    SET airbrake_authority_locked TO TRUE.
    RETURN TRUE.
}

FUNCTION restore_airbrake_control_authority {
    IF NOT airbrake_authority_locked {
        RETURN FALSE.
    }
    LOCAL module_index IS 0.
    FOR p IN SHIP:PARTSTAGGED("airbrake") {
        IF p:HASMODULE("ModuleAeroSurface") {
            IF module_index < airbrake_authority_original_fields_percent:LENGTH {
                p:GETMODULE("ModuleAeroSurface"):SETFIELD("authority limiter", airbrake_authority_original_fields_percent[module_index]).
            }
            SET module_index TO module_index + 1.
        }
    }
    SET airbrake_authority_locked TO FALSE.
    RETURN TRUE.
}

FUNCTION available_sensor_types {
    LOCAL sensor_types IS LIST().
    LIST SENSORS IN sensor_parts.
    FOR sensor_part IN sensor_parts {
        IF NOT sensor_types:CONTAINS(sensor_part:TYPE) {
            sensor_types:ADD(sensor_part:TYPE).
        }
    }
    RETURN sensor_types.
}

FUNCTION start_predictor_telemetry_segment {
    SET predictor_telemetry_path TO "1:/" + predictor_telemetry_base_name + "_part_" + predictor_telemetry_segment_index + ".json".
    SET predictor_telemetry_document TO LEXICON().
    SET predictor_telemetry_samples TO LIST().
    SET predictor_telemetry_events TO LIST().
    SET predictor_telemetry_document["schema"] TO "reentry_airbrake_predictor".
    SET predictor_telemetry_document["schema_version"] TO 4.
    SET predictor_telemetry_document["status"] TO "running".
    SET predictor_telemetry_document["segment_index"] TO predictor_telemetry_segment_index.
    SET predictor_telemetry_document["sensor_note"] TO "pressure, temperature, and acceleration sensor values are zero when the vessel lacks the corresponding part".
    SET predictor_telemetry_document["run"] TO predictor_telemetry_run.
    SET predictor_telemetry_document["samples"] TO predictor_telemetry_samples.
    SET predictor_telemetry_document["events"] TO predictor_telemetry_events.
}

FUNCTION initialize_predictor_telemetry {
    LOCAL sensor_types IS available_sensor_types().
    SET predictor_telemetry_run["run_id"] TO predictor_telemetry_run_id.
    SET predictor_telemetry_run["start_time_s"] TO predictor_telemetry_start_time.
    SET predictor_telemetry_run["real_start_time_s"] TO predictor_telemetry_real_start_time.
    SET predictor_telemetry_run["vessel_name"] TO SHIP:NAME.
    SET predictor_telemetry_run["body"] TO SHIP:BODY:NAME.
    SET predictor_telemetry_run["body_radius_m"] TO SHIP:BODY:RADIUS.
    SET predictor_telemetry_run["initial_mass_t"] TO SHIP:MASS.
    SET predictor_telemetry_run["initial_apoapsis_m"] TO SHIP:APOAPSIS.
    SET predictor_telemetry_run["initial_periapsis_m"] TO SHIP:PERIAPSIS.
    SET predictor_telemetry_run["initial_orbit_eccentricity"] TO SHIP:OBT:ECCENTRICITY.
    SET predictor_telemetry_run["atmosphere_molar_mass_kgpmol"] TO SHIP:BODY:ATM:MOLARMASS.
    SET predictor_telemetry_run["atmosphere_adiabatic_index"] TO SHIP:BODY:ATM:ADIABATICINDEX.
    SET predictor_telemetry_run["target_lat_deg"] TO pad_geo:LAT.
    SET predictor_telemetry_run["target_lng_deg"] TO pad_geo:LNG.
    SET predictor_telemetry_run["airbrake_control_mode"] TO airbrake_control_mode.
    SET predictor_telemetry_run["trajectories_profile_id"] TO trajectories_profile_id.
    SET predictor_telemetry_run["entry_corridor_id"] TO entry_corridor_id.
    SET predictor_telemetry_run["target_entry_fpa_down_deg"] TO target_entry_fpa_down_deg.
    SET predictor_telemetry_run["predicted_entry_fpa_down_deg"] TO predicted_entry_fpa_down_deg.
    SET predictor_telemetry_run["target_deorbit_phase_angle_deg"] TO target_deorbit_phase_angle_deg.
    SET predictor_telemetry_run["actual_deorbit_burn_phase_angle_deg"] TO actual_deorbit_burn_phase_angle_deg.
    SET predictor_telemetry_run["airbrake_min_angle_deg"] TO airbrake_min_angle.
    SET predictor_telemetry_run["airbrake_max_angle_deg"] TO airbrake_base_angle.
    SET predictor_telemetry_run["airbrake_fixed_angle_deg"] TO configured_fixed_airbrake_angle().
    SET predictor_telemetry_run["airbrake_part_count"] TO SHIP:PARTSTAGGED("airbrake"):LENGTH.
    SET predictor_telemetry_run["initial_vessel_part_count"] TO predictor_telemetry_initial_part_count.
    SET predictor_telemetry_run["airbrake_actuator_speed_degps"] TO airbrake_actuator_speed_degps.
    SET predictor_telemetry_run["airbrake_authority_limiter_command_percent"] TO airbrake_authority_command_percent.
    SET predictor_telemetry_run["airbrake_authority_limiter_original_fields_percent"] TO airbrake_authority_original_fields_percent.
    SET predictor_telemetry_run["airbrake_deploy_altitude_m"] TO entry_brakes_deploy_alt_meters.
    SET predictor_telemetry_run["airbrake_retract_speed_mps"] TO entry_brakes_retract_speed_mps.
    SET predictor_telemetry_run["entry_aoa_deg"] TO entry_aoa_deg.
    SET predictor_telemetry_run["entry_aoa_retract_speed_mps"] TO entry_aoa_retract_speed_mps.
    SET predictor_telemetry_run["entry_steering_source"] TO "scripted_signed_aoa".
    IF trajectories_profile_id = "matched10" {
        SET predictor_telemetry_run["entry_steering_source"] TO "scripted_belly_aoa_no_roll_correction".
    }
    SET predictor_telemetry_run["airbrake_pid_kp"] TO airbrake_pid_kp.
    SET predictor_telemetry_run["airbrake_pid_ki"] TO airbrake_pid_ki.
    SET predictor_telemetry_run["airbrake_pid_kd"] TO airbrake_pid_kd.
    SET predictor_telemetry_run["airbrake_pid_epsilon_m"] TO airbrake_pid_epsilon.
    SET predictor_telemetry_run["airbrake_pid_gain_ref_altitude_m"] TO airbrake_pid_gain_ref_alt_meters.
    SET predictor_telemetry_run["sample_interval_s"] TO predictor_telemetry_sample_interval.
    SET predictor_telemetry_run["checkpoint_interval_s"] TO predictor_telemetry_checkpoint_interval.
    SET predictor_telemetry_run["has_pressure_sensor"] TO sensor_types:CONTAINS("PRES").
    SET predictor_telemetry_run["has_temperature_sensor"] TO sensor_types:CONTAINS("TEMP").
    SET predictor_telemetry_run["has_acceleration_sensor"] TO sensor_types:CONTAINS("ACC").
    SET predictor_telemetry_run["has_gravity_sensor"] TO sensor_types:CONTAINS("GRAV").
    IF ADDONS:TR:AVAILABLE {
        IF ADDONS:TR:ISVERTWOFOUR {
            SET predictor_telemetry_run["trajectories_descent_angles_deg"] TO ADDONS:TR:DESCENTANGLES.
            SET predictor_telemetry_run["trajectories_descent_grades"] TO ADDONS:TR:DESCENTGRADES.
            SET predictor_telemetry_run["trajectories_descent_modes"] TO ADDONS:TR:DESCENTMODES.
        }
    }
    start_predictor_telemetry_segment().
}

FUNCTION record_predictor_event {
    PARAMETER event_name, detail.
    LOCAL event IS LEXICON().
    SET event["time_s"] TO TIME:SECONDS.
    SET event["elapsed_s"] TO TIME:SECONDS - predictor_telemetry_start_time.
    SET event["event"] TO event_name.
    SET event["detail"] TO detail.
    predictor_telemetry_events:ADD(event).
}

FUNCTION transmit_predictor_telemetry {
    IF HOMECONNECTION:ISCONNECTED {
        FOR pending_path IN predictor_telemetry_pending_paths {
            COPYPATH(pending_path, "0:").
            DELETEPATH(pending_path).
        }
        SET predictor_telemetry_pending_paths TO LIST().
        RETURN TRUE.
    }
    RETURN FALSE.
}

FUNCTION checkpoint_predictor_telemetry {
    SET predictor_telemetry_document["checkpoint_time_s"] TO TIME:SECONDS.
    SET predictor_telemetry_document["segment_sample_count"] TO predictor_telemetry_samples:LENGTH.
    SET predictor_telemetry_document["total_sample_count"] TO predictor_telemetry_total_samples.
    WRITEJSON(predictor_telemetry_document, predictor_telemetry_path).
    predictor_telemetry_pending_paths:ADD(predictor_telemetry_path).
    transmit_predictor_telemetry().
    SET predictor_telemetry_segment_index TO predictor_telemetry_segment_index + 1.
    start_predictor_telemetry_segment().
    SET predictor_telemetry_next_checkpoint TO TIME:SECONDS + predictor_telemetry_checkpoint_interval.
}

FUNCTION capture_predictor_sample {
    PARAMETER phase, airbrake_angle, airbrake_pid_output, airbrake_pid_gain, throttle_command.
    LOCAL sample IS LEXICON().
    LOCAL surface_velocity IS SHIP:VELOCITY:SURFACE.
    LOCAL horizontal_velocity IS VXCL(UP:FOREVECTOR, surface_velocity).
    LOCAL sensors IS SHIP:SENSORS.
    LOCAL sensor_types IS available_sensor_types().
    LOCAL pressure_sensor_kpa IS 0.
    LOCAL temperature_sensor_k IS 0.
    LOCAL acceleration_sensor_magnitude IS 0.
    LOCAL gravity_sensor_g IS 0.
    IF sensor_types:CONTAINS("PRES") {
        SET pressure_sensor_kpa TO sensors:PRES.
    }
    IF sensor_types:CONTAINS("TEMP") {
        SET temperature_sensor_k TO sensors:TEMP.
    }
    IF sensor_types:CONTAINS("ACC") {
        SET acceleration_sensor_magnitude TO sensors:ACC:MAG.
    }
    IF sensor_types:CONTAINS("GRAV") {
        SET gravity_sensor_g TO sensors:GRAV:MAG.
    }
    LOCAL has_impact IS ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT.
    LOCAL trajectories_planned_aoa IS 0.
    LOCAL trajectories_planned_facing_error IS -1.
    IF has_impact {
        SET trajectories_planned_aoa TO signed_entry_aoa_for_vector(ADDONS:TR:PLANNEDVEC).
        SET trajectories_planned_facing_error TO VANG(SHIP:FACING:FOREVECTOR, ADDONS:TR:PLANNEDVEC).
    }
    LOCAL sample_dt IS TIME:SECONDS - predictor_telemetry_last_sample_time.
    LOCAL airspeed_rate IS 0.
    LOCAL density_from_q IS 0.
    LOCAL model_pressure_atm IS SHIP:BODY:ATM:ALTITUDEPRESSURE(SHIP:ALTITUDE).
    LOCAL model_temperature_k IS SHIP:BODY:ATM:ALTITUDETEMPERATURE(SHIP:ALTITUDE).
    LOCAL model_density IS 0.
    LOCAL model_sound_speed IS 0.
    LOCAL model_mach IS 0.
    LOCAL current_airbrake_count IS SHIP:PARTSTAGGED("airbrake"):LENGTH.
    LOCAL current_part_count IS SHIP:PARTS:LENGTH.
    LOCAL airbrake_angle_fields IS airbrake_angle_readbacks().
    LOCAL airbrake_authority_fields IS airbrake_authority_readbacks().
    LOCAL airbrake_angle_field_min IS 0.
    LOCAL airbrake_angle_field_max IS 0.
    LOCAL airbrake_authority_field_min IS 0.
    LOCAL airbrake_authority_field_max IS 0.
    IF airbrake_angle_fields:LENGTH > 0 {
        SET airbrake_angle_field_min TO airbrake_angle_fields[0].
        SET airbrake_angle_field_max TO airbrake_angle_fields[0].
        FOR field_angle IN airbrake_angle_fields {
            SET airbrake_angle_field_min TO MIN(airbrake_angle_field_min, field_angle).
            SET airbrake_angle_field_max TO MAX(airbrake_angle_field_max, field_angle).
        }
    }
    IF airbrake_authority_fields:LENGTH > 0 {
        SET airbrake_authority_field_min TO airbrake_authority_fields[0].
        SET airbrake_authority_field_max TO airbrake_authority_fields[0].
        FOR field_authority IN airbrake_authority_fields {
            SET airbrake_authority_field_min TO MIN(airbrake_authority_field_min, field_authority).
            SET airbrake_authority_field_max TO MAX(airbrake_authority_field_max, field_authority).
        }
    }
    IF current_airbrake_count <> predictor_telemetry_last_airbrake_count {
        record_predictor_event("airbrake_count_changed", predictor_telemetry_last_airbrake_count + " -> " + current_airbrake_count + " at " + ROUND(SHIP:ALTITUDE) + " m").
        SET predictor_telemetry_last_airbrake_count TO current_airbrake_count.
    }
    IF current_part_count <> predictor_telemetry_last_part_count {
        record_predictor_event("vessel_part_count_changed", predictor_telemetry_last_part_count + " -> " + current_part_count + " at " + ROUND(SHIP:ALTITUDE) + " m, q " + ROUND(SHIP:Q * CONSTANT:ATMTOKPA, 2) + " kPa").
        SET predictor_telemetry_last_part_count TO current_part_count.
    }
    IF sample_dt > 0 {
        SET airspeed_rate TO (SHIP:AIRSPEED - predictor_telemetry_last_airspeed) / sample_dt.
    }
    IF SHIP:AIRSPEED > 0 {
        SET density_from_q TO 2 * SHIP:Q * CONSTANT:ATMTOKPA * 1000 / SHIP:AIRSPEED^2.
    }
    IF model_temperature_k > 0 AND SHIP:BODY:ATM:MOLARMASS > 0 {
        SET model_density TO model_pressure_atm * CONSTANT:ATMTOKPA * 1000 * SHIP:BODY:ATM:MOLARMASS / (8.314462618 * model_temperature_k).
        SET model_sound_speed TO SQRT(SHIP:BODY:ATM:ADIABATICINDEX * 8.314462618 * model_temperature_k / SHIP:BODY:ATM:MOLARMASS).
        IF model_sound_speed > 0 {
            SET model_mach TO SHIP:AIRSPEED / model_sound_speed.
        }
    }

    SET sample["time_s"] TO TIME:SECONDS.
    SET sample["elapsed_s"] TO TIME:SECONDS - predictor_telemetry_start_time.
    SET sample["phase"] TO phase.
    SET sample["latitude_deg"] TO SHIP:GEOPOSITION:LAT.
    SET sample["longitude_deg"] TO SHIP:GEOPOSITION:LNG.
    SET sample["altitude_asl_m"] TO SHIP:ALTITUDE.
    SET sample["altitude_radar_m"] TO ALT:RADAR.
    SET sample["surface_speed_mps"] TO surface_velocity:MAG.
    SET sample["horizontal_speed_mps"] TO horizontal_velocity:MAG.
    SET sample["vertical_speed_mps"] TO SHIP:VERTICALSPEED.
    SET sample["airspeed_mps"] TO SHIP:AIRSPEED.
    SET sample["airspeed_rate_mps2"] TO airspeed_rate.
    SET sample["dynamic_pressure_atm"] TO SHIP:Q.
    SET sample["dynamic_pressure_kpa"] TO SHIP:Q * CONSTANT:ATMTOKPA.
    SET sample["density_from_q_kgpm3"] TO density_from_q.
    SET sample["static_pressure_model_atm"] TO model_pressure_atm.
    SET sample["temperature_model_k"] TO model_temperature_k.
    SET sample["density_model_kgpm3"] TO model_density.
    SET sample["sound_speed_model_mps"] TO model_sound_speed.
    SET sample["mach_model"] TO model_mach.
    SET sample["static_pressure_sensor_kpa"] TO pressure_sensor_kpa.
    SET sample["temperature_sensor_k"] TO temperature_sensor_k.
    SET sample["acceleration_sensor_magnitude_mps2"] TO acceleration_sensor_magnitude.
    SET sample["gravity_sensor_g"] TO gravity_sensor_g.
    SET sample["gravity_model_mps2"] TO SHIP:BODY:MU / (SHIP:BODY:RADIUS + SHIP:ALTITUDE)^2.
    SET sample["mass_t"] TO SHIP:MASS.
    SET sample["aoa_command_deg"] TO entry_aoa_command().
    SET sample["aoa_actual_deg"] TO actual_entry_aoa().
    SET sample["trajectories_planned_aoa_deg"] TO trajectories_planned_aoa.
    SET sample["trajectories_planned_facing_error_deg"] TO trajectories_planned_facing_error.
    SET sample["airbrake_angle_command_deg"] TO airbrake_angle.
    SET sample["airbrake_angle_deg"] TO airbrake_angle.
    SET sample["airbrake_deploy_angle_fields_deg"] TO airbrake_angle_fields.
    SET sample["airbrake_deploy_angle_field_min_deg"] TO airbrake_angle_field_min.
    SET sample["airbrake_deploy_angle_field_max_deg"] TO airbrake_angle_field_max.
    SET sample["airbrake_deploy_angle_field_spread_deg"] TO airbrake_angle_field_max - airbrake_angle_field_min.
    SET sample["airbrake_authority_limiter_fields_percent"] TO airbrake_authority_fields.
    SET sample["airbrake_authority_limiter_field_min_percent"] TO airbrake_authority_field_min.
    SET sample["airbrake_authority_limiter_field_max_percent"] TO airbrake_authority_field_max.
    SET sample["airbrake_authority_limiter_field_spread_percent"] TO airbrake_authority_field_max - airbrake_authority_field_min.
    SET sample["airbrake_angle_reassertion_count"] TO airbrake_angle_reassertion_count.
    SET sample["airbrake_part_count"] TO current_airbrake_count.
    SET sample["vessel_part_count"] TO current_part_count.
    SET sample["brakes_action_group"] TO BRAKES.
    SET sample["airbrake_pid_output_deg"] TO airbrake_pid_output.
    SET sample["airbrake_pid_kp"] TO airbrake_pid_gain.
    SET sample["throttle_command"] TO throttle_command.
    SET sample["has_trajectories_impact"] TO has_impact.

    IF has_impact {
        LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
        LOCAL to_pad_from_impact_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION) - VXCL(UP:FOREVECTOR, impact_geo:POSITION).
        LOCAL along_miss IS 0.
        LOCAL cross_miss IS 0.
        IF horizontal_velocity:MAG > 1 {
            SET along_miss TO VDOT(to_pad_from_impact_h, horizontal_velocity:NORMALIZED).
            SET cross_miss TO VDOT(to_pad_from_impact_h, VCRS(UP:FOREVECTOR, horizontal_velocity:NORMALIZED)).
        }
        SET sample["impact_lat_deg"] TO impact_geo:LAT.
        SET sample["impact_lng_deg"] TO impact_geo:LNG.
        SET sample["impact_miss_m"] TO target_miss_distance(impact_geo, pad_geo).
        SET sample["impact_along_miss_m"] TO along_miss.
        SET sample["impact_cross_miss_m"] TO cross_miss.
    }

    predictor_telemetry_samples:ADD(sample).
    SET predictor_telemetry_total_samples TO predictor_telemetry_total_samples + 1.
    SET predictor_telemetry_last_sample_time TO TIME:SECONDS.
    SET predictor_telemetry_last_airspeed TO SHIP:AIRSPEED.
    SET predictor_telemetry_next_sample TO TIME:SECONDS + predictor_telemetry_sample_interval.
    IF TIME:SECONDS >= predictor_telemetry_next_checkpoint {
        checkpoint_predictor_telemetry().
    }
}

FUNCTION finalize_predictor_telemetry {
    PARAMETER final_status, detail.
    IF restore_airbrake_control_authority() {
        record_predictor_event("airbrake_authority_restored", "restored original authority limiter values at entry handoff").
    }
    record_predictor_event(final_status, detail).
    SET predictor_telemetry_document["status"] TO final_status.
    SET predictor_telemetry_document["end_time_s"] TO TIME:SECONDS.
    checkpoint_predictor_telemetry().
}

FUNCTION check_line {
    PARAMETER ok, label, detail.
    LOCAL mark IS "[x]".
    IF ok {
        SET mark TO "[✓]".
    } ELSE {
        SET preflight_failed TO TRUE.
    }
    log_line(mark + " " + label + " - " + detail).
}

FUNCTION info_line {
    PARAMETER label, detail.
    log_line("[i] " + label + " - " + detail).
}

FUNCTION warn_line {
    PARAMETER label, detail.
    log_line("[!] " + label + " - " + detail).
}

FUNCTION transmit_log {
    LOCAL recovered_on_kerbin IS FALSE.
    IF SHIP:BODY:NAME = "Kerbin" {
        IF SHIP:STATUS = "LANDED" OR SHIP:STATUS = "SPLASHED" {
            SET recovered_on_kerbin TO TRUE.
        }
    }

    IF recovered_on_kerbin OR HOMECONNECTION:ISCONNECTED {
        COPYPATH(log_path, "0:").
        RETURN TRUE.
    }
    RETURN FALSE.
}

FUNCTION abort_reentry {
    PARAMETER msg.
    LOCK THROTTLE TO 0.
    UNLOCK THROTTLE.
    UNLOCK STEERING.
    log_line("ABORT: " + msg).
    finalize_predictor_telemetry("abort", msg).
    transmit_log().
    WAIT 5.
    SHUTDOWN.
}

FUNCTION set_airbrake_angle {
    PARAMETER angle.
    LOCAL rounded_angle IS ROUND(angle).
    LOCAL command_changed IS rounded_angle <> airbrake_last_command_deg.
    IF NOT command_changed AND TIME:SECONDS < airbrake_next_command_verification {
        RETURN FALSE.
    }
    SET airbrake_next_command_verification TO TIME:SECONDS + 1.
    LOCAL changed_any IS FALSE.
    LOCAL part_index IS 0.
    FOR p IN SHIP:PARTSTAGGED("airbrake") {
        IF p:HASMODULE("ModuleAeroSurface") {
            LOCAL module IS p:GETMODULE("ModuleAeroSurface").
            LOCAL field_angle IS module:GETFIELD("deploy angle").
            IF command_changed OR ABS(field_angle - rounded_angle) > 0.5 {
                module:SETFIELD("deploy angle", rounded_angle).
                SET changed_any TO TRUE.
                IF NOT command_changed {
                    SET airbrake_angle_reassertion_count TO airbrake_angle_reassertion_count + 1.
                    record_predictor_event("airbrake_angle_reasserted", "part " + part_index + " field " + ROUND(field_angle, 1) + " -> " + rounded_angle + " deg").
                }
            }
        }
        SET part_index TO part_index + 1.
    }
    SET airbrake_last_command_deg TO rounded_angle.
    RETURN changed_any.
}

FUNCTION target_miss_distance {
    PARAMETER impact_geo, target_geo.
    LOCAL impact_radial IS impact_geo:POSITION - SHIP:BODY:POSITION.
    LOCAL target_radial IS target_geo:POSITION - SHIP:BODY:POSITION.
    IF impact_radial:MAG <= 0 OR target_radial:MAG <= 0 {
        RETURN 999999999.
    }
    RETURN SHIP:BODY:RADIUS * VANG(impact_radial, target_radial) * CONSTANT:PI / 180.
}

FUNCTION signed_entry_aoa_for_vector {
    PARAMETER facing_vector.
    LOCAL srfret IS SHIP:SRFRETROGRADE:FOREVECTOR.
    LOCAL axis IS VCRS(UP:FOREVECTOR, srfret).
    LOCAL angle IS VANG(facing_vector, srfret).
    IF axis:MAG <= 0.01 {
        RETURN angle.
    }
    IF VDOT(VCRS(srfret, facing_vector), axis:NORMALIZED) < 0 {
        RETURN -angle.
    }
    RETURN angle.
}

FUNCTION actual_entry_aoa {
    RETURN signed_entry_aoa_for_vector(SHIP:FACING:FOREVECTOR).
}

FUNCTION entry_aoa_active {
    RETURN SHIP:ALTITUDE < entry_orbit_retro_alt_meters AND
           SHIP:VELOCITY:SURFACE:MAG > entry_aoa_retract_speed_mps.
}

FUNCTION entry_aoa_command {
    IF NOT entry_aoa_active() {
        RETURN 0.
    }
    RETURN entry_aoa_deg.
}

FUNCTION entry_retrograde_steering {
    IF SHIP:ALTITUDE > entry_orbit_retro_alt_meters {
        RETURN RETROGRADE.
    }
    IF entry_aoa_active() {
        LOCAL srfret IS SHIP:SRFRETROGRADE:FOREVECTOR.
        LOCAL axis IS VCRS(UP:FOREVECTOR, srfret).
        IF axis:MAG > 0.01 {
            LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
            // Trajectories' profile has no bank schedule. Keep matched10 in its
            // vertical AoA plane; operational proxy guidance still corrects cross-track.
            IF trajectories_profile_id <> "matched10" AND horiz_vel:MAG > 1 AND ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
                LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
                LOCAL to_pad_from_impact_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION) - VXCL(UP:FOREVECTOR, impact_geo:POSITION).
                LOCAL cross_miss_v IS VXCL(horiz_vel:NORMALIZED, to_pad_from_impact_h).
                LOCAL roll_dir IS VCRS(cross_miss_v:NORMALIZED, srfret:NORMALIZED).
                LOCAL blended IS axis:NORMALIZED + roll_dir * (cross_miss_v:MAG * entry_roll_correction_gain).
                LOCAL corrected IS VXCL(srfret, blended).
                IF corrected:MAG > 0.01 { SET axis TO corrected. }
            }
            RETURN ANGLEAXIS(entry_aoa_command(), axis:NORMALIZED) * srfret.
        }
    }
    RETURN SHIP:SRFRETROGRADE.
}


CLEARSCREEN.
lock_airbrake_control_authority().
initialize_predictor_telemetry().
log_line("=== reentry.ks ===").
LOCAL preflight_failed IS FALSE.
log_line("Target       : " + ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5) + " on " + pad_geo:BODY:NAME).
log_line("Airbrake mode: " + airbrake_control_mode + "  |  telemetry: " + predictor_telemetry_path).
log_line("Entry corridor: " + entry_corridor_id + "  |  target/predicted FPA: " + ROUND(target_entry_fpa_down_deg, 3) + "/" + ROUND(predicted_entry_fpa_down_deg, 3) + " deg down at 70 km").
log_line("Deorbit phase : target/actual burn " + ROUND(target_deorbit_phase_angle_deg, 3) + "/" + ROUND(actual_deorbit_burn_phase_angle_deg, 3) + " deg").
log_line("Airbrake authority: locked to " + airbrake_authority_command_percent + "% during entry; original values restored at handoff.").
log_line("Entry attitude: orbit retro above " + ROUND(entry_orbit_retro_alt_meters/1000, 1) + " km, surface retro below.").
log_line("Entry AoA    : " + entry_aoa_deg + " deg fixed, retract below " + ROUND(entry_aoa_retract_speed_mps) + " m/s.").
log_line("Handoff gate : " + ROUND(reentry_handoff_alt_meters/1000, 1) + " km alt  |  spd <= " + ROUND(reentry_handoff_speed_mps) + " m/s  |  TR miss <= " + ROUND(reentry_handoff_tr_miss_meters) + " m  |  guided land at " + ROUND(reentry_guided_land_alt_meters/1000, 1) + " km").

log_line("--- Preflight checks ---").
check_line(pad_geo:BODY:NAME = SHIP:BODY:NAME, "Target body", "target " + pad_geo:BODY:NAME + ", current " + SHIP:BODY:NAME).
check_line(entry_brakes_retract_speed_mps > 0, "Entry brake retract speed", ROUND(entry_brakes_retract_speed_mps) + " m/s").
LOCAL preflight_airbrake_authority_fields IS airbrake_authority_readbacks().
LOCAL airbrake_authority_ok IS preflight_airbrake_authority_fields:LENGTH > 0.
FOR field_authority IN preflight_airbrake_authority_fields {
    IF ABS(field_authority - airbrake_authority_command_percent) > 0.5 {
        SET airbrake_authority_ok TO FALSE.
    }
}
check_line(airbrake_authority_ok, "Airbrake control authority locked", airbrake_authority_command_percent + "% across " + preflight_airbrake_authority_fields:LENGTH + " surfaces").
check_line(airbrake_control_mode = "off" OR is_fixed_airbrake_mode() OR airbrake_control_mode = "pid", "Airbrake control mode", airbrake_control_mode).
check_line(airbrake_control_mode <> "fixed" OR (custom_fixed_airbrake_angle_deg >= 0 AND custom_fixed_airbrake_angle_deg <= airbrake_base_angle), "Custom fixed airbrake angle", ROUND(custom_fixed_airbrake_angle_deg, 2) + " deg within 0-" + airbrake_base_angle).
check_line(trajectories_profile_id = "proxy" OR trajectories_profile_id = "matched10", "Trajectories profile ID", trajectories_profile_id).
check_line(entry_corridor_id = "trajectories_miss" OR entry_corridor_id = "entry_fpa29", "Entry corridor ID", entry_corridor_id).
check_line(entry_corridor_id <> "entry_fpa29" OR (target_entry_fpa_down_deg > 0 AND predicted_entry_fpa_down_deg > 0), "Entry corridor target", "target " + ROUND(target_entry_fpa_down_deg, 3) + " deg, predicted " + ROUND(predicted_entry_fpa_down_deg, 3) + " deg").
check_line(entry_corridor_id <> "entry_fpa29" OR (target_deorbit_phase_angle_deg >= 0 AND actual_deorbit_burn_phase_angle_deg >= 0), "Deorbit phase telemetry", "target " + ROUND(target_deorbit_phase_angle_deg, 3) + " deg, actual burn " + ROUND(actual_deorbit_burn_phase_angle_deg, 3) + " deg").
check_line(airbrake_min_angle >= 0 AND airbrake_min_angle < airbrake_base_angle, "PID airbrake envelope", ROUND(airbrake_min_angle, 1) + "-" + ROUND(airbrake_base_angle, 1) + " deg").
check_line(airbrake_fixed30_angle >= 0 AND airbrake_fixed30_angle <= airbrake_base_angle, "Fixed-30 airbrake angle", ROUND(airbrake_fixed30_angle, 1) + " deg experimental").
check_line(airbrake_fixed45_angle >= 0 AND airbrake_fixed45_angle <= airbrake_base_angle, "Fixed-45 airbrake angle", ROUND(airbrake_fixed45_angle, 1) + " deg experimental").
check_line(airbrake_fixed50_angle >= 0 AND airbrake_fixed50_angle <= airbrake_base_angle, "Fixed-50 airbrake angle", ROUND(airbrake_fixed50_angle, 1) + " deg experimental").
check_line(airbrake_fixed60_angle >= airbrake_min_angle AND airbrake_fixed60_angle <= airbrake_base_angle, "Fixed-60 airbrake angle", ROUND(airbrake_fixed60_angle, 1) + " deg safe-envelope endpoint").
check_line(entry_aoa_deg >= 0 AND entry_aoa_deg <= 90, "Entry AoA", ROUND(entry_aoa_deg, 1) + " deg").
check_line(entry_aoa_retract_speed_mps > 0, "Entry AoA retract speed", ROUND(entry_aoa_retract_speed_mps) + " m/s").
check_line(reentry_handoff_alt_meters > 0, "Reentry handoff altitude", ROUND(reentry_handoff_alt_meters/1000, 1) + " km").
check_line(reentry_handoff_tr_miss_meters > 0, "Reentry handoff TR miss", ROUND(reentry_handoff_tr_miss_meters) + " m").
info_line("Landing target coordinates", ROUND(pad_geo:LAT, 5) + ", " + ROUND(pad_geo:LNG, 5)).
IF preflight_failed {
    abort_reentry("preflight checks failed.").
}
record_predictor_event("preflight_complete", "airbrake mode " + airbrake_control_mode).
checkpoint_predictor_telemetry().
transmit_log().

SAS OFF.
LOCAL monitor_throttle IS 0.
LOCK THROTTLE TO monitor_throttle.
LOCAL next_print IS TIME:SECONDS.
LOCAL airbrake_pid IS PIDLOOP(airbrake_pid_kp, airbrake_pid_ki, airbrake_pid_kd, airbrake_min_angle - airbrake_base_angle, 0, airbrake_pid_epsilon).
SET airbrake_pid:SETPOINT TO 0.

FUNCTION monitor_steering {
    IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
        RETURN ADDONS:TR:CORRECTEDVEC.
    }
    RETURN entry_retrograde_steering().
}

LOCK STEERING TO entry_retrograde_steering().
log_line("--- ENTRY GUIDANCE ---").
LOCAL airbrake_control_active IS entry_brakes_enabled AND airbrake_control_mode <> "off".
LOCAL entry_brakes_deployed IS airbrake_control_active AND SHIP:VELOCITY:SURFACE:MAG > entry_brakes_retract_speed_mps.
IF entry_brakes_deployed {
    BRAKES ON.
    log_line("  Entry brakes armed  |  speed: " + ROUND(SHIP:VELOCITY:SURFACE:MAG, 1) + " m/s").
} ELSE {
    BRAKES OFF.
}
LOCAL ab_angle IS 0.
IF airbrake_control_active {
    IF is_fixed_airbrake_mode() {
        SET ab_angle TO configured_fixed_airbrake_angle().
    } ELSE {
        SET ab_angle TO airbrake_base_angle.
    }
    set_airbrake_angle(ab_angle).
}
LOCAL ab_correction IS 0.
LOCAL next_brake_update IS 0.
record_predictor_event("entry_guidance_start", "airbrake mode " + airbrake_control_mode).
UNTIL SHIP:ALTITUDE <= reentry_handoff_alt_meters {
    LOCAL surface_speed IS SHIP:VELOCITY:SURFACE:MAG.

    IF airbrake_control_active {
        IF NOT entry_brakes_deployed AND SHIP:ALTITUDE < entry_brakes_deploy_alt_meters AND surface_speed > entry_brakes_retract_speed_mps {
            BRAKES ON.
            SET entry_brakes_deployed TO TRUE.
            record_predictor_event("airbrakes_deployed", "altitude " + ROUND(SHIP:ALTITUDE) + " m").
            log_line("  Entry brakes deployed  |  alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  speed: " + ROUND(surface_speed, 1) + " m/s").
        }
    }

    IF airbrake_control_mode = "off" {
        SET ab_angle TO 0.
        SET ab_correction TO 0.
        BRAKES OFF.
    } ELSE IF is_fixed_airbrake_mode() {
        SET ab_angle TO configured_fixed_airbrake_angle().
        SET ab_correction TO 0.
    } ELSE IF NOT (ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT) {
        SET ab_angle TO airbrake_base_angle.
        SET ab_correction TO 0.
    } ELSE IF TIME:SECONDS >= next_brake_update {
        LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
        LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
        LOCAL to_pad_from_impact_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION) - VXCL(UP:FOREVECTOR, impact_geo:POSITION).
        LOCAL along_miss IS 0.
        IF horiz_vel:MAG > 1 {
            SET along_miss TO VDOT(to_pad_from_impact_h, horiz_vel:NORMALIZED).
        }
        SET airbrake_pid:KP TO airbrake_pid_kp * (airbrake_pid_gain_ref_alt_meters / MAX(SHIP:ALTITUDE, reentry_handoff_alt_meters)).
        SET ab_correction TO airbrake_pid:UPDATE(TIME:SECONDS, along_miss).
        SET ab_angle TO clamp(airbrake_base_angle + ab_correction, airbrake_min_angle, airbrake_base_angle).
        SET next_brake_update TO TIME:SECONDS + 2.
    }
    IF airbrake_control_mode <> "off" {
        set_airbrake_angle(ab_angle).
    }

    IF TIME:SECONDS >= predictor_telemetry_next_sample {
        capture_predictor_sample("entry", ab_angle, ab_correction, airbrake_pid:KP, 0).
    }

    IF TIME:SECONDS >= next_print {
        log_line("  Alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  spd: " + ROUND(surface_speed, 1) + " m/s  |  vs: " + ROUND(SHIP:VERTICALSPEED, 1) + " m/s  |  cmd: " + ROUND(entry_aoa_command(), 1) + " deg  |  actual: " + ROUND(actual_entry_aoa(), 1) + " deg").
        IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
            LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
            LOCAL tr_miss IS target_miss_distance(impact_geo, pad_geo).
            LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
            LOCAL to_pad_from_impact_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION) - VXCL(UP:FOREVECTOR, impact_geo:POSITION).
            LOCAL along_miss IS 0.
            LOCAL lateral_miss IS 0.
            IF horiz_vel:MAG > 1 {
                SET along_miss TO VDOT(to_pad_from_impact_h, horiz_vel:NORMALIZED).
                SET lateral_miss TO VDOT(to_pad_from_impact_h, VCRS(UP:FOREVECTOR, horiz_vel:NORMALIZED)).
            }
            log_line("    TR impact: " + ROUND(impact_geo:LAT, 4) + ", " + ROUND(impact_geo:LNG, 4) + "  |  miss: " + ROUND(tr_miss/1000, 2) + " km  |  along: " + ROUND(along_miss/1000, 2) + " km  |  cross: " + ROUND(lateral_miss/1000, 2) + " km  |  ab: " + ROUND(ab_angle, 1) + " deg").
        } ELSE {
            log_line("    TR impact: no prediction").
        }
        transmit_log().
        SET next_print TO TIME:SECONDS + entry_telemetry_interval.
    }
    WAIT 0.
}

LOCAL handoff_speed IS SHIP:VELOCITY:SURFACE:MAG.
LOCAL handoff_tr_miss IS 999999.
IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
    SET handoff_tr_miss TO target_miss_distance(ADDONS:TR:IMPACTPOS, pad_geo).
}
LOCAL guide_ok IS handoff_speed <= reentry_handoff_speed_mps AND handoff_tr_miss <= reentry_handoff_tr_miss_meters.
log_line("--- Reentry handoff gate ---").
log_line("  alt: " + ROUND(SHIP:ALTITUDE) + " m  |  spd: " + ROUND(handoff_speed, 1) + " m/s  |  TR miss: " + ROUND(handoff_tr_miss) + " m").
capture_predictor_sample("handoff_gate", ab_angle, ab_correction, airbrake_pid:KP, 0).
record_predictor_event("handoff_gate", "guided " + guide_ok).
checkpoint_predictor_telemetry().
transmit_log().

IF NOT guide_ok {
    set_airbrake_angle(90).
    log_line("Outside guided envelope at gate — falling back to unguided landing.").
    log_line("  spd: " + ROUND(handoff_speed, 1) + " m/s (limit " + ROUND(reentry_handoff_speed_mps) + ")  |  TR miss: " + ROUND(handoff_tr_miss) + " m (limit " + ROUND(reentry_handoff_tr_miss_meters) + " m)").
    finalize_predictor_telemetry("fallback_unguided", "outside handoff envelope").
    transmit_log().
    RUNPATH(land_unguided_script_path, predictor_telemetry_run_id, predictor_telemetry_base_name, predictor_telemetry_segment_index, predictor_telemetry_initial_part_count, airbrake_control_mode, trajectories_profile_id).
}

log_line("Guide condition met at gate — monitoring to " + ROUND(reentry_guided_land_alt_meters/1000, 1) + " km.").
LOCK STEERING TO monitor_steering().
LOCAL monitor_thr_pid IS PIDLOOP(monitor_throttle_pid_kp, monitor_throttle_pid_ki, monitor_throttle_pid_kd, 0, monitor_throttle_pid_max_throttle, monitor_throttle_pid_epsilon).
SET monitor_thr_pid:SETPOINT TO 0.
SET next_print TO TIME:SECONDS.

UNTIL SHIP:ALTITUDE <= reentry_guided_land_alt_meters {
    LOCAL surface_speed IS SHIP:VELOCITY:SURFACE:MAG.

    LOCAL monitor_tr_miss IS 999999.
    LOCAL along_miss IS 0.
    LOCAL cross_miss IS 0.
    IF ADDONS:TR:AVAILABLE AND ADDONS:TR:HASIMPACT {
        LOCAL impact_geo IS ADDONS:TR:IMPACTPOS.
        SET monitor_tr_miss TO target_miss_distance(impact_geo, pad_geo).
        LOCAL horiz_vel IS VXCL(UP:FOREVECTOR, SHIP:VELOCITY:SURFACE).
        LOCAL to_pad_from_impact_h IS VXCL(UP:FOREVECTOR, pad_geo:POSITION) - VXCL(UP:FOREVECTOR, impact_geo:POSITION).
        IF horiz_vel:MAG > 1 {
            SET along_miss TO VDOT(to_pad_from_impact_h, horiz_vel:NORMALIZED).
            SET cross_miss TO VDOT(to_pad_from_impact_h, VCRS(UP:FOREVECTOR, horiz_vel:NORMALIZED)).
        }
        set_airbrake_angle(90).
    }

    SET monitor_throttle TO monitor_thr_pid:UPDATE(TIME:SECONDS, along_miss).

    IF TIME:SECONDS >= predictor_telemetry_next_sample {
        LOCAL monitor_ab_angle IS 90.
        IF NOT BRAKES {
            SET monitor_ab_angle TO 0.
        }
        capture_predictor_sample("monitor", monitor_ab_angle, 0, 0, monitor_throttle).
    }

    IF monitor_tr_miss > reentry_handoff_tr_miss_meters {
        SET monitor_throttle TO 0.
        set_airbrake_angle(90).
        log_line("Guide condition lost (TR miss) — falling back to unguided landing.").
        log_line("  alt: " + ROUND(SHIP:ALTITUDE) + " m  |  TR miss: " + ROUND(monitor_tr_miss) + " m (limit " + ROUND(reentry_handoff_tr_miss_meters) + " m)").
        finalize_predictor_telemetry("fallback_unguided", "monitor trajectories miss exceeded limit").
        transmit_log().
        RUNPATH(land_unguided_script_path, predictor_telemetry_run_id, predictor_telemetry_base_name, predictor_telemetry_segment_index, predictor_telemetry_initial_part_count, airbrake_control_mode, trajectories_profile_id).
    }

    IF TIME:SECONDS >= next_print {
        log_line("  [monitor] alt: " + ROUND(SHIP:ALTITUDE/1000, 1) + " km  |  spd: " + ROUND(surface_speed, 1) + " m/s  |  TR miss: " + ROUND(monitor_tr_miss) + " m  |  along: " + ROUND(along_miss) + " m  |  cross: " + ROUND(cross_miss) + " m  |  thr: " + ROUND(monitor_throttle, 3)).
        transmit_log().
        SET next_print TO TIME:SECONDS + monitor_telemetry_interval.
    }

    WAIT 0.
}

SET monitor_throttle TO 0.
set_airbrake_angle(90).
log_line("Handing off to guided landing at " + ROUND(SHIP:ALTITUDE) + " m: " + land_script_path).
LOCAL final_ab_angle IS 90.
IF NOT BRAKES {
    SET final_ab_angle TO 0.
}
capture_predictor_sample("guided_landing_handoff", final_ab_angle, 0, 0, 0).
finalize_predictor_telemetry("guided_landing_handoff", land_script_path).
transmit_log().
RUNPATH(land_script_path, predictor_telemetry_run_id, predictor_telemetry_base_name, predictor_telemetry_segment_index, predictor_telemetry_initial_part_count, airbrake_control_mode, trajectories_profile_id).
