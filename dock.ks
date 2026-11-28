@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/rcs.ks"
// #include "0:/lib/docking.ks"
PARAMETER station_name, chaser_port_tag IS "", station_port_tag IS "",
    open_chaser_shield IS FALSE, run_token IS "".

RUNONCEPATH("0:/lib/telemetry.ks").
RUNONCEPATH("0:/lib/rcs.ks").
RUNONCEPATH("0:/lib/docking.ks").
open_log("docking").
IF run_token <> "" { PRINT "TEST-START " + run_token. }
dock_to_station(station_name, LEXICON("chaser_port_tag", chaser_port_tag,
    "station_port_tag", station_port_tag, "open_chaser_shield", open_chaser_shield)).
IF run_token <> "" { end_test(run_token). } ELSE { transmit_log(). }
