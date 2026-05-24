// ============================================================
//  lib/logger.ks — structured CSV telemetry logger
// ============================================================
//  Writes fixed-column CSV rows to a local volume file with
//  periodic checkpoint copies to the archive (volume 0) for
//  data durability, and a final timestamped archive export on
//  script completion.
//
//  CSV columns:
//    t_s, phase, event, alt_m, vs_ms, spd_ms, ap_m, pe_m, thr, note
//
//  Requirements:
//    - Archive (volume 0) access for checkpoint and finalize.
//    - note_val arguments must not contain commas.
//
//  Usage:
//    RUNONCEPATH("0:/lib/logger").
//    logger_init("hop").
//    // at fixed cadence (e.g. alongside PRINT in rate-limited blocks):
//    logger_log("ascent", "telemetry", thrott, "").
//    // on key events:
//    logger_log("ascent", "staging", thrott, "stage 1 sep").
//    // at script end:
//    logger_finalize().
// ============================================================

SET logger_local_path            TO "".
SET logger_archive_path          TO "".
SET logger_mission_name          TO "".
SET logger_checkpoint_interval_s TO 30.
SET logger_last_checkpoint_s     TO 0.
SET logger_min_freespace_bytes   TO 4096.
SET logger_enabled               TO FALSE.

// --- logger_init ---------------------------------------------

FUNCTION logger_init {
    // Initialize the logger for a mission.
    // Creates a fresh local log file and writes the CSV header.
    // mission_name: short label used in filenames; no spaces or commas.
    PARAMETER mission_name.

    LOCAL ts_s IS ROUND(TIME:SECONDS).
    SET logger_mission_name TO mission_name.
    SET logger_local_path   TO "1:/log_" + mission_name + ".csv".
    SET logger_archive_path TO "0:/logs/" + mission_name + "_" + ts_s + ".csv".

    IF VOLUME(1):FREESPACE < logger_min_freespace_bytes {
        PRINT "[WARN] Logger: insufficient local free space — logging disabled.".
        SET logger_enabled TO FALSE.
        RETURN.
    }

    IF EXISTS(logger_local_path) {
        DELETEPATH(logger_local_path).
    }

    LOG "t_s,phase,event,alt_m,vs_ms,spd_ms,ap_m,pe_m,thr,note" TO logger_local_path.
    SET logger_last_checkpoint_s TO TIME:SECONDS.
    SET logger_enabled TO TRUE.
    PRINT "[INFO] Logger: started -> " + logger_local_path.
}

// --- logger_checkpoint ---------------------------------------

FUNCTION logger_checkpoint {
    // Copy the current local log to a checkpoint file on the archive.
    // Overwrites the previous checkpoint; safe to call frequently.
    IF NOT logger_enabled { RETURN. }
    IF NOT EXISTS(logger_local_path) { RETURN. }
    LOCAL ckpt_path IS "0:/logs/ckpt_" + logger_mission_name + ".csv".
    COPYPATH(logger_local_path, ckpt_path).
    SET logger_last_checkpoint_s TO TIME:SECONDS.
    PRINT "[INFO] Logger: checkpoint -> " + ckpt_path.
}

// --- logger_log ----------------------------------------------

FUNCTION logger_log {
    // Append one telemetry row to the log file.
    // thr_val:  commanded throttle [0..1] (dimensionless).
    // note_val: brief annotation — must not contain commas.
    PARAMETER phase_name, event_name, thr_val, note_val.

    IF NOT logger_enabled { RETURN. }

    IF VOLUME(1):FREESPACE < logger_min_freespace_bytes {
        PRINT "[WARN] Logger: local disk full — logging disabled.".
        SET logger_enabled TO FALSE.
        RETURN.
    }

    LOCAL row IS ROUND(TIME:SECONDS, 1)
        + "," + phase_name
        + "," + event_name
        + "," + ROUND(SHIP:ALTITUDE, 1)
        + "," + ROUND(SHIP:VERTICALSPEED, 2)
        + "," + ROUND(SHIP:VELOCITY:SURFACE:MAG, 2)
        + "," + ROUND(SHIP:APOAPSIS, 0)
        + "," + ROUND(SHIP:PERIAPSIS, 0)
        + "," + ROUND(thr_val, 3)
        + "," + note_val.

    LOG row TO logger_local_path.

    IF TIME:SECONDS - logger_last_checkpoint_s >= logger_checkpoint_interval_s {
        logger_checkpoint().
    }
}

// --- logger_finalize -----------------------------------------

FUNCTION logger_finalize {
    // Append a session_end record and copy the final log to the
    // archive under a unique timestamped filename.
    IF NOT logger_enabled { RETURN. }
    logger_log("finalize", "session_end", 0, "").
    COPYPATH(logger_local_path, logger_archive_path).
    PRINT "[INFO] Logger: archived -> " + logger_archive_path.
    SET logger_enabled TO FALSE.
}
