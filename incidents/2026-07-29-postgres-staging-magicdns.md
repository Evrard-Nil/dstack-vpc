# Postgres staging MagicDNS failure, 2026-07-29

## Summary

During a protected Postgres staging rotation, an older cpu02 replica could not
resolve the later-created cpu01 member's `.dstack.internal` hostname. The
cpu01 member could resolve and reach cpu02, Headscale showed both nodes online,
and Patroni advertised the same names Headscale assigned. The failure was
therefore asymmetric within the Headscale/Tailscale MagicDNS path, not a failed
VPC registration or a general DNS outage.

The former leader disappeared during the rotation and the new cpu01 member
promoted to timeline 8. DNS did not demonstrably cause that disappearance, but
it prevented the cpu02 replica from following the new leader. The replica
remained on timeline 7 while the leader continued generating WAL.

## Impact

- New leader: cpu01 Patroni member `594ff4e22486`, running on timeline 8.
- Stranded replica: cpu02 Patroni member `8db10901df38`, running on timeline 7.
- At 2026-07-30 04:31:49 UTC, the replica was 327,719,384 bytes
  (312.54 MiB) behind the leader.
- The leader still had 14.82 GiB free on its persistent disk. This was not an
  immediate disk emergency, but Patroni physical slots were enabled without a
  configured `max_slot_wal_keep_size`, so the retained-WAL risk compounded
  while the replica remained unable to connect.
- Staging `/v1/health` and the DB-backed `/v1/model/list` both returned HTTP
  200 during the final readback.

## Timeline

Pacific times below are PDT (UTC-7).

| UTC | Pacific | Event |
|---|---|---|
| 2026-07-29 17:13:32-17:14:22 | 10:13:32-10:14:22 PDT | A transient cpu01 member deployment completed. |
| 2026-07-29 17:47:55 | 10:47:55 PDT | The old leader's planned switchover failed because it could not resolve the candidate hostname. |
| 2026-07-29 17:48:19-17:49:12 | 10:48:19-10:49:12 PDT | The current cpu02 replica deployment completed. |
| 2026-07-29 17:50:36 | 10:50:36 PDT | cpu02 joined Headscale as node 2425, `postgres-staging-fmbqrrqv`. |
| 2026-07-29 18:00:09-18:00:38 | 11:00:09-11:00:38 PDT | The current cpu01 member deployment completed. |
| 2026-07-29 18:01:55 | 11:01:55 PDT | cpu01 joined as node 2426, `postgres-staging-gej12j6r`; cpu02 received the peer-map update. |
| 2026-07-29 18:33:05 | 11:33:05 PDT | PostgreSQL started on the current cpu01 member. |
| 2026-07-29 18:34:15-18:34:21 | 11:34:15-11:34:21 PDT | The former leader logged its last healthy state and disconnected without a graceful shutdown line. |
| 2026-07-29 18:34:19 | 11:34:19 PDT | cpu02 replayed its last timeline-7 WAL at LSN `37/46211690`. |
| 2026-07-29 18:34:45 | 11:34:45 PDT | cpu02 failed to resolve cpu01 while cpu01 successfully reached cpu02. |
| 2026-07-29 18:34:47 | 11:34:47 PDT | cpu01 acquired the Patroni lock and promoted to timeline 8. |
| 2026-07-29 18:34:49 | 11:34:49 PDT | The first recurring SQL hostname-resolution error appeared on cpu02. |
| 2026-07-29 18:34:55 | 11:34:55 PDT | The backup workflow started, after promotion, and was not the trigger. |
| 2026-07-29 22:50 and 2026-07-30 03:50 | 15:50 and 20:50 PDT | cpu02's Headscale map stream reconnected normally without repairing DNS. |
| 2026-07-30 04:30:49 | 2026-07-29 21:30:49 PDT | The DNS error was still recurring. |

## Root cause

The immediate failure was that the older cpu02 peer did not materialize or
resolve the later-created cpu01 MagicDNS name even though:

- the cpu01 Headscale registration succeeded;
- both current nodes were online in Headscale;
- Patroni advertised the exact Headscale-assigned names;
- cpu02 received a peer-map update when cpu01 joined; and
- resolution worked in the reverse direction.

The retained logs do not identify whether the deepest defect is duplicate-name
handling while Headscale builds the DNS map or ingestion of that map by the
cpu02 tailscaled resolver. Guest netmap and resolver state were not exposed.
The confirmed fault boundary is the duplicate-name MagicDNS propagation path
for an older peer learning a later-created peer.

## Why it recurred

Every CVM used the same configured hostname for its service role, such as
`postgres-staging`. Headscale had to disambiguate each registration by
generating a new random suffix. At the time of the incident, the control plane
contained 2,434 node rows but only 9 online rows. It contained 23 historical
`postgres-staging` rows with only 2 online.

The growth was unbounded because the VPC API issued reusable, non-ephemeral
pre-authentication keys and the VM removal path did not deregister Headscale
nodes. Each rotation therefore combined two failure-inducing conditions:

1. an older member had to learn a newly generated collision suffix; and
2. the DNS map retained a continually growing set of historical identities.

Deleting same-role nodes during registration is not safe. Protected database
rotations intentionally overlap an old member and its replacement until the
replacement is streaming with zero lag.

## Prevention implemented in dstack-vpc

The durable fix changes the identity lifecycle rather than adding DNS retries:

1. `VPC_NODE_NAME` remains a readable service-role name, but the setup process
   normalizes it and appends the first 12 characters of the CVM instance ID.
   The same CVM gets the same name after a container restart; replacement CVMs
   get distinct names without Headscale collision suffixes.
2. The API creates one-use, ephemeral Headscale pre-authentication keys.
3. Headscale removes ephemeral nodes after 24 hours offline. The explicit
   24-hour window is intentionally longer than Headscale's 30-minute default,
   so a transient control-plane outage does not immediately delete a running
   CVM identity.
4. The client writes the derived enrollment name into the shared bootstrap
   volume, and the Tailscale container uses that exact name for `tailscale up`.
5. Go and shell regression tests verify the enrollment flags, deterministic
   naming, DNS-label safety, length limit, and per-instance uniqueness.

Consumers continue reading Tailscale's actual `Self.DNSName` from
`/shared/actual_hostname`. Postgres/Patroni and other services therefore keep
their existing actual-hostname contract.

## Safe rollout

1. Build and attest the updated dstack-vpc image.
2. Update the VPC server first so new registrations receive one-use ephemeral
   keys.
3. Deploy one non-leader database replica with the new image. Do not restart or
   replace the leader.
4. Verify the canary's Headscale name includes its instance suffix and that the
   node is online.
5. From both old and new peers, verify the other's exact
   `.dstack.internal` name resolves and `tailscale ping` succeeds.
6. Require Patroni `streaming`, the leader's current timeline, zero replay lag,
   and sustained zero lag before replacing another replica.
7. Rotate one replica at a time while protecting the leader and at least one
   known-good replica.
8. After the fixed fleet is stable, clean legacy offline Headscale rows in
   bounded batches using exact node IDs. Never select rows by the shared base
   name alone.

There is no fail-closed deadline. Stop a rollout on any bidirectional DNS
failure, timeline mismatch, replay stall, or unexpected leader change.

## Legacy node cleanup

Legacy non-ephemeral rows do not become ephemeral after this change. Clean them
only after exporting the inventory, mapping every protected live member to its
exact Headscale ID, and confirming the Headscale SQLite backup is current.

Dry-run inventory:

```bash
docker exec vpc-server headscale nodes list -o json |
  jq '.[] | {id, name, given_name, online, last_seen}'
```

For each reviewed offline row, delete only its exact numeric ID:

```bash
docker exec vpc-server headscale nodes delete --identifier NODE_ID --force
```

Read the inventory back after each bounded batch. Do not automate deletion from
`online:false` alone because a transiently disconnected but still-owned CVM can
briefly satisfy that condition.

## Verification and alerts

- Gate every database replacement on bidirectional DNS resolution before
  promotion or retirement.
- Alert when a Patroni replica is present but has no replication-delay series,
  when timelines differ, or when replay LSN stops advancing.
- Alert on repeated `could not translate host name` and
  `getaddrinfo returns an empty list` messages in every environment.
- Track Headscale total, online, offline, and ephemeral node counts.
- Keep WAL disk-free and physical-slot retained-byte monitoring separate from
  `postgresql_wal_age_seconds`; WAL age is an archive-timer signal, not a
  replica-backlog measurement.

## Residual risk

This change removes the two repeatable preconditions observed in the incident,
but it does not prove or patch a specific Headscale or tailscaled source-level
DNS defect. A canary must still prove bidirectional resolution with the pinned
production versions before the database fleet is rotated.
