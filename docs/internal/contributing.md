# Contributing

Use this guide before you change the source or documentation.
Start with [development setup](how-to-set-up-development.md).

## Changes and commits

Use short branch names, such as `feature/worker-status` or `fix/job-retry`.
Write commit messages in English.
Use the form `type(scope): summary` or `type: summary`.
Supported types include `feat`, `fix`, `docs`, `refactor`, `chore`, `test`, `build`, `ci`, and `perf`.
Mark a breaking change with `!` after its type or scope.

Keep a change focused on its stated behavior.
Update the relevant requirements and documentation when behavior changes.
Preserve unrelated work in the checkout.

## Code requirements

Use the existing UI tokens and `OmashikiWeb.CoreComponents` components.
Do not introduce duplicate styling for an existing component.
Keep generated assets under `server/priv/static/assets/` out of Git.
The build creates these assets from source.

Run the checks appropriate to the change.
For UI changes, include the asset build.
Before a code pull request, run the required server tests and local CI checks.
See [test procedures](how-to-run-tests.md) for commands and external prerequisites.

## Secrets

Keep `.env`, credential snapshots, and encryption keys out of Git.
Development stores its Cloak key in `.omashiki/cloak_key`.
Standalone installations can store release secrets in `~/.omashiki/secrets.env`.
These secret files use mode `0600`.

Changing `SECRET_KEY_BASE` invalidates existing API tokens.
Changing `OMASHIKI_CLOAK_KEY` can make stored encrypted values unreadable.
Document required credential rotation with the change.

## Documentation language

Use [ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf) as the English writing reference.
Use its approved vocabulary with the technical terms required by this project.
The [configuration reference](../configuration.md#terms) defines the principal product terms.
Code identifiers, filenames, API fields, and product names retain their exact spelling.

Write one instruction per sentence.
Use the imperative form for procedure steps.
Keep procedural sentences within 20 words and descriptive sentences within 25 words.
Use active voice and one term for each technical meaning.
Put prerequisites before commands.
Describe the expected result and relevant failure action.

Check vocabulary and meaning as well as sentence length.
A word-count check alone does not establish STE conformity.
Preserve diagrams and examples during language edits.
Describe the current product.
Do not mention removed features, names, or contracts.

## Documentation review

Check each local link after a file move.
Check command names against `mise.toml` and `.mise/tasks`.
Check API examples against the executable request contract.
Record a measurement with its date and source revision.
Do not present a past measurement as current product behavior.
