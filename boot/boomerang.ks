// ============================================================
//  boomerang.ks - bootstrap loader for the boomerang vessel.
// ============================================================

PRINT "=== boomerang.ks ===".
PRINT "Syncing launch.ks, deorbit.ks, and land.ks to local volume...".

LOCAL launch_global_path IS "0:/launch.ks".
LOCAL launch_local_path  IS "1:/launch.ks".
LOCAL deorbit_global_path IS "0:/deorbit.ks".
LOCAL deorbit_local_path  IS "1:/deorbit.ks".
LOCAL land_global_path   IS "0:/land.ks".
LOCAL land_local_path    IS "1:/land.ks".

IF EXISTS(launch_local_path) {
    DELETEPATH(launch_local_path).
}
IF EXISTS(deorbit_local_path) {
    DELETEPATH(deorbit_local_path).
}
IF EXISTS(land_local_path) {
    DELETEPATH(land_local_path).
}

COPYPATH(launch_global_path, launch_local_path).
COPYPATH(deorbit_global_path, deorbit_local_path).
COPYPATH(land_global_path, land_local_path).

PRINT " ".
PRINT "Initial script:".
PRINT "  1) launch.ks".
PRINT "  2) deorbit.ks".
PRINT "  3) land.ks".
PRINT "Press RETURN to load nothing.".
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
LOCAL choice IS TERMINAL:INPUT:GETCHAR().

IF choice = "1" {
    PRINT "Launching local launch.ks...".
    RUNPATH(launch_local_path).
} ELSE IF choice = "2" {
    PRINT "Launching local deorbit.ks...".
    RUNPATH(deorbit_local_path).
} ELSE IF choice = "3" {
    PRINT "Launching local land.ks...".
    RUNPATH(land_local_path).
} ELSE {
    PRINT "No initial script launched.".
}
