@LAZYGLOBAL OFF.

FUNCTION rcs_translate {
    PARAMETER thrust_vector.
    LOCAL body_direction IS SHIP:FACING.
    SET SHIP:CONTROL:TRANSLATION TO V(VDOT(thrust_vector, body_direction:STARVECTOR),
        VDOT(thrust_vector, body_direction:TOPVECTOR), VDOT(thrust_vector, body_direction:FOREVECTOR)).
}
