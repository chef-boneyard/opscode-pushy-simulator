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

Sending Jobs
------------
Currently there is no code in pushysim to allow you to start jobs via
the REST API.  In `opscode-pushy-server` branch `jc/OC-3256/pushysim`
there is a helper function `pushy_tools:send_job(Hostname, N)` which can
start up the job submission cycle to pushysim clients on a given host.

On dev-vm the hostname is `<<"private-chef">>` by default so execute
inside the `pushy-server` VM:

    > pushy_tools:send_job(<<"private-chef">>, 100).

to send a job to the clients named `"private-chef-0001"` to
`"private-chef-0100"`.

TODO
----
+ Handle server heartbeats
+ Allow for different state transitions to exercise error cases
+ Implement erratic heartbeating


## License

All files in the repository are licensed under the Apache 2.0 license. If any
file is missing the License header it should assume the following is attached;

```
Copyright 2014 Chef Software Inc

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```


