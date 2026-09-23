# Edit the configuration in the browser

The Files page edits the house configuration and the task views file.
Each file has named documents. The applied document is the file that the house reads.
The other documents are drafts. The house does not read drafts.

## Prerequisites

- A running house. See [install and stop Omashiki](how-to-install-and-stop.md).
- Write access for the house to the directory of each file. See [containers](#containers).

## Open the page

1. Open the Config screen at `/config`.
2. Select **Edit files**. The page opens at `/config/files`.
3. Select **House config** or **Task views**.

The list shows each document and the time since its last change.
`applied` marks the document that the house reads.
The files that the applied configuration includes appear under it.
They are edited in place and have no drafts.

On first use, the page imports the current file as the applied document.
The document takes the file name, for example `omashiki` for `omashiki.toml`.

## Edit a document

1. Select a document. The editor opens it.
2. Edit the content.
3. Select **Check** to validate the content without saving it.
4. Select **Save**, or press Ctrl+S (Cmd+S on macOS).

**Check** shows the problems above the editor.
A TOML syntax error also marks its line in the editor.
For the house configuration, **Check** also lists the declarations that the content adds, removes, or changes.
The list covers environments, presets, identities, repositories, credentials, and caches.

Saving a draft stores it, even when it is invalid.

Saving the applied document or an included file changes the house immediately.
The page validates the content, shows the changes, and asks for confirmation.
After confirmation, the house reloads the configuration and the page shows the result.
An invalid file is not written.
For task views, the Home screen shows the saved file within seconds.

## Create and apply a draft

1. Select **New**.
2. Enter a name. Use lowercase letters, digits, `-`, and `_`, with a maximum of 40 characters. Start with a letter or a digit.
3. Select `blank`, or a copy of the selected document.
4. Select **Create**, then edit and save the draft.
5. Select **Apply**.
6. Read the changes and select **Apply** to confirm.

Result: the draft becomes the applied document and replaces the live file.
The page shows the result of the reload.
**Apply** uses the saved draft. Save the draft first.

**Delete** removes a draft and its history after confirmation.
The applied document and included files cannot be deleted.

## Changes that need a restart

A reload applies registry sections only.
Changes to `[app]`, `[db]`, `[auth]`, `[limits]`, and `[nodes]` take effect after a restart.
Before you confirm a save or an apply, the page lists these sections in a `Restart required` warning.
The file is still written. Restart the house to apply those sections.

## History

Each document keeps its last 50 versions.
A save, an apply, and a restore each keep the content that they replaced.
The history shows each version with the time it was replaced, the operator, and a short hash.
`an outside edit` marks content replaced by an edit made outside the page.

To undo a change, select **Restore** on a version and confirm.
For the applied document or an included file, a restore is validated and applied like a save.
After an apply, the newest version of the applied document is the content that the apply replaced.

## Edits outside the page

The live file remains the source of truth. You can still edit it with another editor.
When the live file differs from the applied document, the page shows `Edited outside Omashiki`.
The edit becomes the applied document, and the previous content goes to its history.

If a file changes after you open it, a save writes nothing and the page shows `Changed elsewhere`.
Select **Reload** to open the current content. The reload replaces your unsaved edits.

## Where the files live

The page writes the live files at their usual paths.
The house configuration is the `OMASHIKI_CONFIG` file, or `omashiki.toml` at the repository root.
The views file is at its [usual location](how-to-customize-task-views.md#file-location).
Documents and their history live in `.omashiki-files/` next to each live file.
The house does not read this directory at boot.

The page writes a new file and renames it over the old one.
The house therefore needs write access to the directory, not only to the file.
The page does not write through a symbolic link or outside the directory of the file.

If a directory does not accept new files, the page opens in read-only mode.
A `Read-only` banner names the directory. You can open and check documents, but you cannot save, apply, create, delete, or restore them.

## Containers

The [manager Compose file](../examples/compose.manager.yml) mounts a configuration directory writable at `/config`.
Set `OMASHIKI_CONFIG_DIR` to the host directory that contains `omashiki.toml`. The default is the repository root.
The views file is `ui.toml` in the same directory.
A read-only mount puts the page in read-only mode.
With a mount of a single file, a save fails because the file cannot be replaced.

## Login off

With `[auth].enabled = false`, the house has no browser login.
If the house also listens on a non-loopback address, anyone who reaches it can edit its configuration.
The page shows a persistent warning in this case. Editing remains available.
To require login, set `[auth].enabled = true` and restart the house.
