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

PRINT "Launching local launch.ks...".
RUNPATH(launch_local_path).
