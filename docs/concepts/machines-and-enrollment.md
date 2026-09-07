# Machines and enrollment

A machine runs jobs. It does not know who the developer is. You enroll a
machine into each house that it can serve.

## Add a machine

1. Rent a server. It is only hardware and a place to run sandboxes.
2. Give it the machine role: `OMASHIKI_ROLE=worker`. The machine file,
   [worker.toml](../../examples/worker.toml), has only limits and the Docker
   socket path.
3. The machine starts with no house and opens an enrollment listener.
4. From your laptop, enroll each house that the machine can serve:

   ```bash
   mise run worker:enroll -- --manager-id house-a --manager-url http://house-a.lan:4010 --worker-token $TOKEN_A
   mise run worker:enroll -- --manager-id house-b --manager-url http://house-b.lan:4020 --worker-token $TOKEN_B
   ```

The enrollment API on the machine:

| Call | Effect |
| --- | --- |
| `POST /internal/enroll` | Add a house, or replace the house with the same id |
| `DELETE /internal/enroll/<id>` | Remove one house. The other houses are not changed |
| `GET /internal/enroll` | List ids and URLs. Tokens are never returned |

Enrollment survives a restart of the machine.

## Capacity

A machine has a limit, for example four jobs at the same time. The limit is
of the **machine**. It is not "four for house A and four for house B". The
houses share the slots. The machine polls the houses in round-robin order.
The machine is the authority for its slots.

## Presence

Each house shows the machines that polled it, with the free slots and a
`stale` flag after thirty seconds of silence. Presence is per house. A
machine that is silent in one house can be active in another house.

## Shapes

| Shape | What runs where | Config | Proof |
| --- | --- | --- | --- |
| One box | House and machine in one `embedded` process | `examples/single-node.omashiki.toml` | `mise run e2e:overture` |
| One house, several nodes | Several `embedded` nodes share one PostgreSQL, declared in `[nodes.*]` | `examples/multi-node.omashiki.toml` | Queue tests in `server/test/omashiki/jobs/` |
| One house, a fleet | One `manager`, many `worker` machines enrolled over HTTP | `examples/compose.manager.yml`, `examples/compose.worker.yml` | `mise run e2e:host-worker`, `mise run e2e:compose-worker` |
| Many houses, the same fleet | One `manager` per developer; each machine enrolled into each house | One Compose project per house | `mise run e2e:two-houses` |

For two houses on one **host** (not Compose), give each house its own
`OMASHIKI_SUPPLY_CHAIN_SOCKET_PATH`.

## Remove a developer from the fleet

Remove the house from the machines. The machines continue. The other
developers continue. That house can no longer place work on your machines.
