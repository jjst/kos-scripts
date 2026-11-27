@LAZYGLOBAL OFF.
// #include "0:/rendezvous.ks"
PARAMETER test_id, run_token.

LOCAL options IS LEXICON().
SET options TO READJSON("0:/tests/options/" + test_id + ".json").
RUNPATH("0:/rendezvous.ks", options["station"], run_token).
