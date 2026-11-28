@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/burn.ks"
// #include "0:/lib/rendezvous.ks"
// #include "0:/lib/rcs.ks"
// #include "0:/lib/rendezvous_approach.ks"
// #include "0:/lib/docking.ks"
PARAMETER station_name, run_token IS "", approach_options IS LEXICON().

RUNONCEPATH("0:/lib/telemetry.ks").
RUNONCEPATH("0:/lib/burn.ks").
RUNONCEPATH("0:/lib/rendezvous.ks").
RUNONCEPATH("0:/lib/rcs.ks").
RUNONCEPATH("0:/lib/rendezvous_approach.ks").

open_log("test-rendezvous-approach").
IF run_token <> "" { PRINT "TEST-START " + run_token. }
fly_rendezvous_approach(station_name).
IF log_failure_count() = 0 AND approach_options:HASKEY("dock") {
    IF approach_options["dock"] {
        RUNONCEPATH("0:/lib/docking.ks").
        dock_to_station(station_name, approach_options).
    }
}
IF run_token <> "" { end_test(run_token). } ELSE { transmit_log(). }
