@LAZYGLOBAL OFF.
// #include "0:/lib/telemetry.ks"
// #include "0:/lib/burn.ks"
// #include "0:/lib/rendezvous.ks"
// #include "0:/lib/rendezvous_transfer.ks"
PARAMETER station_name, run_token IS "".

RUNONCEPATH("0:/lib/telemetry.ks").
RUNONCEPATH("0:/lib/burn.ks").
RUNONCEPATH("0:/lib/rendezvous.ks").
RUNONCEPATH("0:/lib/rendezvous_transfer.ks").

open_log("test-docktopus-transfer").
IF run_token <> "" { PRINT "TEST-START " + run_token. }
fly_rendezvous_transfer(station_name).
IF run_token <> "" { end_test(run_token). } ELSE { transmit_log(). }
