// ============================================================
//  boomerang.ks - bootstrap loader for the boomerang vessel.
// ============================================================

LOCAL scripts IS LIST(
    "launch.ks",
    "deorbit.ks",
    "reentry.ks",
    "land-guided.ks",
    "land-unguided.ks"
).

PRINT "=== boomerang.ks ===".
PRINT "Syncing scripts to local volume...".
FOR script IN scripts {
    LOCAL local_path IS "1:/" + script.
    IF EXISTS(local_path) { DELETEPATH(local_path). }
    COPYPATH("0:/" + script, local_path).
}

PRINT " ".
PRINT "Initial script:".
LOCAL idx IS 1.
FOR script IN scripts {
    PRINT "  " + idx + ") " + script.
    SET idx TO idx + 1.
}
PRINT "Press RETURN to load nothing.".
TERMINAL:INPUT:CLEAR().
WAIT UNTIL TERMINAL:INPUT:HASCHAR.
LOCAL choice IS TERMINAL:INPUT:GETCHAR().
WAIT 0.
TERMINAL:INPUT:CLEAR().

LOCAL choice_num IS choice:TONUMBER(-1).
IF choice_num >= 1 AND choice_num <= scripts:LENGTH {
    LOCAL script IS scripts[choice_num - 1].
    PRINT "Launching local " + script + "...".
    RUNPATH("1:/" + script).
} ELSE {
    PRINT "No initial script launched.".
}
