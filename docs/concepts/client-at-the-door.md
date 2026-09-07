# The client at the door

Omashiki has no tracker integration. It does not need one. Any system that
emits an event becomes a work source when your handler maps the event to
one `POST /api/v1/jobs` envelope.

## The two directions

| Direction | What crosses |
| --- | --- |
| In | One envelope: the name of an environment, an instruction, a context |
| Out | One signed terminal webhook per job |

Nothing else crosses the line. The house never learns that GitHub exists.
The machine never sees the webhook.

## An issue arrives

| Who | On GitHub | In Omashiki |
| --- | --- | --- |
| The house | Accepts the job and keeps the result | The house of the developer |
| The GitHub App | Listens to the issue and comments at the end | A client of the house |
| The machine | Nothing | Runs the job. It does not know GitHub exists |

1. Somebody labels the issue. GitHub calls the handler. This is not
   Omashiki yet.
2. The handler checks the GitHub signature. Then it sends one envelope to
   the house. The envelope has the name of the environment, the
   instruction, and the context (number, title, labels). It has no keys,
   no model, and no "run on machine 3".
3. The house admits the job as its own. A free machine runs it and returns
   the result only to the house.
4. The house sends a signed terminal webhook to the handler. The handler
   comments or labels the issue with its own token.

## The webhook

The house signs each terminal webhook:

```
x-webhook-signature: v1=<hex HMAC-SHA256(secret, timestamp + "." + canonical_json(payload))>
```

Canonical JSON has sorted keys and no spaces. The handler must refuse a
timestamp that is older than five minutes.

## Example

[examples/handler/github_issue_handler.py](../../examples/handler/github_issue_handler.py)
is a reference handler with no dependencies. It verifies the GitHub webhook,
maps a labelled issue to one envelope, and verifies the terminal webhook.
The webhook secret and the event mapping live in the handler, never in
`omashiki.toml`.
