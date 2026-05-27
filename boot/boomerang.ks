// ============================================================
//  boomerang.ks — bootstrap loader for local hop execution
// ============================================================

PRINT "=== boomerang.ks ===".
PRINT "Syncing hop.ks to local volume...".

LOCAL hop_global_path IS "0:/hop.ks".
LOCAL hop_local_path  IS "1:/hop.ks".

IF EXISTS(hop_local_path) {
    DELETEPATH(hop_local_path).
}

COPYPATH(hop_global_path, hop_local_path).
PRINT "Launching local hop.ks...".
RUNPATH(hop_local_path).
