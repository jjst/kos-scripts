// ============================================================
//  boomerang.ks - bootstrap loader for the boomerang vessel.
// ============================================================

PRINT "=== boomerang.ks ===".
PRINT "Syncing launch.ks, deorbit.ks, reentry.ks, and land-guided.ks to local volume...".

LOCAL launch_global_path IS "0:/launch.ks".
LOCAL launch_local_path  IS "1:/launch.ks".
LOCAL deorbit_global_path IS "0:/deorbit.ks".
LOCAL deorbit_local_path  IS "1:/deorbit.ks".
LOCAL reentry_global_path IS "0:/reentry.ks".
LOCAL reentry_local_path  IS "1:/reentry.ks".
LOCAL land_global_path   IS "0:/land-guided.ks".
LOCAL land_local_path    IS "1:/land-guided.ks".

IF EXISTS(launch_local_path) {
    DELETEPATH(launch_local_path).
}
IF EXISTS(deorbit_local_path) {
    DELETEPATH(deorbit_local_path).
}
IF EXISTS(reentry_local_path) {
    DELETEPATH(reentry_local_path).
}
IF EXISTS(land_local_path) {
    DELETEPATH(land_local_path).
}

COPYPATH(launch_global_path, launch_local_path).
COPYPATH(deorbit_global_path, deorbit_local_path).
COPYPATH(reentry_global_path, reentry_local_path).
COPYPATH(land_global_path, land_local_path).

PRINT " ".
PRINT "Initial script:".
PRINT "  1) launch.ks".
PRINT "  2) deorbit.ks".
PRINT "  3) reentry.ks".
PRINT "  4) land-guided.ks".
PRINT "Press RETURN to load nothing.".
TERMINAL:INPUT:CLEAR().
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
LOCAL choice IS TERMINAL:INPUT:GETCHAR().
WAIT 0.
TERMINAL:INPUT:CLEAR().

IF choice = "1" {
    PRINT "Launching local launch.ks...".
    RUNPATH(launch_local_path).
} ELSE IF choice = "2" {
    PRINT "Launching local deorbit.ks...".
    RUNPATH(deorbit_local_path).
} ELSE IF choice = "3" {
    PRINT "Launching local reentry.ks...".
    RUNPATH(reentry_local_path).
} ELSE IF choice = "4" {
    PRINT "Launching local land-guided.ks...".
    RUNPATH(land_local_path).
} ELSE {
    PRINT "No initial script launched.".
}
