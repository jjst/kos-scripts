@LAZYGLOBAL OFF.
// #include "0:/dock.ks"
PARAMETER test_id, run_token.

LOCAL options IS READJSON("0:/tests/options/" + test_id + ".json").
RUNPATH("0:/dock.ks", options["station"], "", "", options["open_chaser_shield"], run_token).
