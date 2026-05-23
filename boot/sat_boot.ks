// ============================================================
//  sat_boot.ks — boot file on each individual sat
// ============================================================

WAIT 3.  // physics settle after separation

PRINT "Sat online. Initialising...".

// Extend solar panels
FOR p IN SHIP:MODULESNAMED("ModuleDeployableSolarPanel") {
    p:DOEVENT("Extend Panels").
}

// Activate Kerbalism orbital scanner
FOR s IN SHIP:PARTS {
    IF s:HASMODULE("Experiment") {
        LOCAL mod IS s:GETMODULE("Experiment").
        IF mod:HASEVENT("Run") {
            mod:DOEVENT("Run").
            PRINT "Scanner activated on " + s:NAME.
        }
    }
}

PRINT "Sat deployment complete.".
