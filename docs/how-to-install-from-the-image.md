# How to install Omashiki from the image

Use this procedure to run a house from the published image, without a checkout.
The house runs on one machine. It serves the browser UI and the API, and it runs the agent containers.
The image is `ghcr.io/this-is-npc/omashiki`.

## Before you start

You need a Linux host with Docker and Compose support.
Your account must have access to the Docker daemon.
You need a free TCP port. The house uses `4010` by default.

## 1. Download the files

Create a directory for the house and download the two install files:

```bash
mkdir omashiki && cd omashiki
curl -LO https://github.com/This-Is-NPC/omashiki/releases/latest/download/compose.yml
curl -LO https://github.com/This-Is-NPC/omashiki/releases/latest/download/omashiki.toml
```

`compose.yml` starts PostgreSQL and the house.
`omashiki.toml` is the house configuration. It declares one OpenCode environment, `opencode`.
The house also saves configuration history in this directory.

Create the cache directory, so that it belongs to your account:

```bash
mkdir -p ~/.cache/omashiki
```

## 2. Prepare the agent image

The agent image is not published. Build it from the repository, at the release that you run:

```bash
docker build -t omashiki/agent:latest \
  "https://github.com/This-Is-NPC/omashiki.git#v0.1.0:agent"
```

Replace `v0.1.0` with your release.
To use your own image, set its tag in `[runtimes.docker.runc.debian.images]` in `omashiki.toml`.
The image must contain the `opencode` binary.
The house checks each image when it loads the configuration. It does not start without the image.
The house never pulls an agent image, so build it or pull it yourself with `docker pull`.

## 3. Give the agent model access

The starter configuration uses your OpenCode login on this machine.
Log in with OpenCode on this machine first.
The house reads the login files inside its container, so mount them.
Create `compose.override.yml` beside `compose.yml`:

```yaml
services:
  omashiki:
    volumes:
      - ${HOME}/.local/share/opencode:${HOME}/.local/share/opencode:ro
      - ${HOME}/.config/opencode:${HOME}/.config/opencode:ro
```

Compose reads this file with `compose.yml`.
For other agents and for gateway access, see [configure model access](how-to-configure-model-access.md).

## 4. Start the house

Set the session secret in `.env`. Compose reads this file from the same directory.

```bash
echo "SECRET_KEY_BASE=$(openssl rand -base64 48)" > .env
docker compose up -d
```

Keep `.env`. A new secret signs out every browser session.
To use another port, add `OMASHIKI_PORT=4020` to `.env`.
The house applies database migrations when it starts.

## 5. Create the operator account

Open <http://127.0.0.1:4010/signup>.
Create the first operator account.
Signup closes after the first account exists, so do this step at once.

## 6. Check the installation

```bash
curl --fail-with-body http://127.0.0.1:4010/api/v1/health
docker compose exec omashiki bin/doctor
```

The doctor checks Docker, the agent image, the network, and the host credential files.
Each check prints `ok`, `warn`, or `error`, and each problem has a fix.

Agent containers reach the house on its port on the host.
A host firewall such as `ufw` can block that route. The doctor then names the port and the fix.
Without that route, an agent runs until its timeout without its tools.

## 7. Issue an API token

```bash
docker compose exec omashiki bin/token create \
  --name my-client --env opencode --scopes read,submit --user YOUR_USERNAME
```

The command prints the token once.
`bin/token list --user YOUR_USERNAME` lists your tokens.
Next, [submit a job](how-to-submit-a-job.md).

## Edit the configuration

Edit `omashiki.toml` in this directory, or use the [Files page](how-to-edit-configuration.md) at `/config/files`.
See the [configuration reference](configuration.md) for each section.

## Upgrade

Set the release in `.env`, for example `OMASHIKI_VERSION=0.2.0`. Without it, Compose uses `latest`.
Then pull the image and restart the house:

```bash
docker compose pull
docker compose up -d
```

Build the agent image again at the same release.

## Stop

```bash
docker compose stop
```

`docker compose down` removes the containers and keeps the database volume.
`docker compose down -v` also deletes the database volume, with the queue and the accounts.

## Publish the image package

The repository owner does this step once, after the first image is published.
A new GitHub Container Registry package is private.
Open the repository on GitHub, then select **Packages**, **omashiki**, **Package settings**, and **Change visibility**.
Select **Public**. The image then pulls without a login.
