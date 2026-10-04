# Registered native host lifetime review

The host binds one administrative registration, native service and durable
journal before listening. It supplies the fixed registration verifier and owns
the listener, linked service and bounded acceptor subtree. Temporary supervision
prevents a child failure from silently restarting the same custody incarnation.

Explicit close stops new admission, quiesces the service and stops acceptors
before draining the native pool. Journal release requires durable scope closure,
witnessed native retirement and owned service exit. Uncertain cleanup retains
evidence. A late startup failure can follow peer admission and must never roll
back authority or grant permission to replay.

Nine focused real-helper/TLS tests pass. They cover scope/capacity refusal,
occupied-port startup refusal, replacement of a permissive verifier, service
and acceptor failures, missing journal evidence, lost native drain witness,
quiescence and successful owned shutdown. The root then independently passed
all 132 executor tests, including these nine; lint reports no gating errors.
A fresh Astra review traced the host through listener, service, journal,
registration and weft lifecycle paths and found no actionable code defect.

The close/crash fixtures settle their native command before shutdown. They do
not establish shutdown of an actively running command through this new host,
or inject late initializer timeout and partial acceptor-start failure. Brutal
kill cannot run cleanup and still requires the enclosing owner to reconcile
native custody. The caller must transfer exclusive logical use of supplied
handles; their preexisting creator links are not rewritten by configuration.

This is the typed host assembly boundary. Shipped endpoint configuration,
credential provisioning, workspace/LSP routing and two-host product acceptance
remain separate work. Actor/socket death is never a retirement witness.
