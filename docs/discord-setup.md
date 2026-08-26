# Discord setup

Discord has no API for creating an application, so this part is manual. It takes
about ten minutes and you only do it once.

You will collect three things:

| Value              | Where it goes                            | Secret? |
| ------------------ | ---------------------------------------- | ------- |
| **Public key**     | `discord_public_key` in terraform.tfvars | No      |
| **Bot token**      | Used once by the registration script     | **Yes** |
| **Webhook URL**    | `discord_webhook_url` in terraform.tfvars | **Yes** |

The bot token and webhook URL are credentials. `terraform.tfvars` is gitignored;
keep it that way.

---

## 1. Create the application

Go to <https://discord.com/developers/applications> and click **New
Application**. Name it whatever the bot should be called, for example
`Minecraft Server`.

## 2. Copy the public key

On **General Information**, copy **Public Key** — a 64-character hex string.

This is what verifies that requests to your Lambda genuinely came from Discord.
It is not secret; it is the public half of Discord's signing key for your
application.

Put it in `terraform/terraform.tfvars`:

```hcl
discord_public_key = "paste it here"
```

## 3. Create the bot and copy its token

Go to **Bot** in the sidebar. Click **Reset Token** and copy the token that
appears. You cannot view it again, only reset it.

This is a credential. Anyone holding it controls the bot. Do not commit it; the
registration script reads it from a prompt or from `DISCORD_BOT_TOKEN`.

## 4. Invite the bot to your server

Go to **OAuth2** → **URL Generator**.

- Scopes: check **`applications.commands`** and **`bot`**
- Bot permissions: **Send Messages** is enough

Copy the generated URL at the bottom, open it, and add the bot to your server.

`applications.commands` is the one that matters — without it Discord will not
accept your slash commands for that server.

## 5. Create the notification webhook

This is how the server posts "Server is up" and "Server stopped due to
inactivity" into a channel. It is separate from the bot, and optional.

In Discord, right-click the channel you want the messages in → **Edit Channel**
→ **Integrations** → **Webhooks** → **New Webhook** → **Copy Webhook URL**.

```hcl
discord_webhook_url = "https://discord.com/api/webhooks/..."
```

Treat this like a password: anyone with the URL can post to that channel as your
bot. Leave it as `""` to run without notifications.

## 6. Deploy, then come back

```bash
cd terraform
terraform init
terraform apply
```

Copy the `discord_interactions_endpoint_url` output.

## 7. Set the interactions endpoint

Back on **General Information**, paste that URL into **Interactions Endpoint
URL** and click **Save Changes**.

Discord immediately sends a signed PING, plus a deliberately *invalid* request
to check that you reject it. Saving succeeds only if both behave correctly.

If it refuses to save, see
[troubleshooting](troubleshooting.md#discord-will-not-accept-the-interactions-endpoint-url).

## 8. Register the slash commands

```bash
python scripts/register_commands.py --guild <your server ID>
```

To get the server ID: Discord **Settings** → **Advanced** → turn on **Developer
Mode**, then right-click your server icon → **Copy Server ID**.

Guild commands appear instantly. Registering globally (omit `--guild`) makes
them available in every server the bot is in, but can take up to an hour to
propagate — use `--guild` while setting up.

The script prompts for the application ID and bot token, or reads
`DISCORD_APPLICATION_ID` and `DISCORD_BOT_TOKEN` from the environment.

Check what is registered at any time:

```bash
python scripts/register_commands.py --list --guild <server ID>
```

## 9. Try it

Type `/start` in the channel. You should get "Starting the server." within a
second, and a webhook message with the address a few minutes later.

---

## Restricting who can start the server

By default anyone in the Discord server can. To limit it to a role:

1. Turn on Developer Mode (step 8).
2. **Server Settings** → **Roles**, right-click the role → **Copy Role ID**.
3. Add it to `terraform.tfvars` and apply:

```hcl
discord_allowed_role_ids = ["123456789012345678"]
```

Anyone without the role gets a private "You do not have permission" reply.

Note this check is enforced in the Lambda rather than by Discord, so it applies
regardless of channel permissions.

## Rotating the webhook

If the webhook URL has ever been committed or shared, replace it:

1. Channel → **Edit Channel** → **Integrations** → **Webhooks**
2. Delete the old webhook — this immediately invalidates the URL
3. Create a new one, copy the URL
4. Update `discord_webhook_url` in `terraform.tfvars` and `terraform apply`
5. `/stop` then `/start`, so the instance picks up the new value

## Changing the commands

Edit the `COMMANDS` list in `scripts/register_commands.py`, add a matching entry
to the `COMMANDS` dict in `lambda/lambda_function.py`, then `terraform apply`
and re-run the registration script. It uses `PUT`, which replaces the whole set,
so removals take effect too.
