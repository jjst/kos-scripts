@LAZYGLOBAL OFF.
// #include "0:/rendezvous_approach.ks"
PARAMETER test_id, run_token.

LOCAL options IS READJSON("0:/tests/options/" + test_id + ".json").
RUNPATH("0:/rendezvous_approach.ks", options["station"], run_token, options).
