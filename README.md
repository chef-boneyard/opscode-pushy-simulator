Pushy Client Simulator
======================

Overview
--------
The Pushy Client Simulator allows you to start up many pushy clients
inside a single Erlang VM.

The Clients are named according to the hostname and a unique client
identifier. This allows to shut down the clients and start them up again
where they keep the same name but have a different Instantiation ID.
The name is constructed as `hostname()-XXXX` where `XXXX` is a 0-padded
numeric Id representing the client.  An example is `private-chef-0001`
for a client created on the default Erchef VM with pushysim loaded.

All clients currently follow the standard success state transitions
(i.e. `COMMIT` -> `ACK_COMMIT`, `RUN` -> `ACK_RUN`, `COMPLETE`, i
`ABORT` -> `ABORTED`).

API
---
The public API is exposed through the `pushysim` module.

+ `pushysim:start_clients(N)` - Start up N clients (numbered 1..N) that
  connect to the pushy server and start heartbeating

TODO
----
+ Handle server heartbeats
+ Allow for different state transitions to exercise error cases
+ Implement erratic heartbeating


