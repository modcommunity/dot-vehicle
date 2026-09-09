extends RefCounted

## A script that is not a chassis. The suite spawns a vehicle naming this to prove the
## spawner refuses it rather than calling `drive` on something with no such method —
## which is a crash on the tick after a spawn, with a player already in the seat.
