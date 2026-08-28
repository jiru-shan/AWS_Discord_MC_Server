# Discord setup

Discord has no API for creating an application, so this part is manual. It takes
about ten minutes and you only do it once.

You will collect four things:

| Value              | What it is                                          | Where it goes                             | Secret? |
| ------------------ | --------------------------------------------------- | ----------------------------------------- | ------- |
| **Public key**     | the public half of Discord's signing key for your application — the Lambda checks incoming requests against it | `discord_public_key` in terraform.tfvars  | No      |
| **Application ID** | the ID of your application; appears in the API path the registration script calls | Used once, by the registration script     | No      |
| **Bot token**      | the bot's password — it authorises that same call    | Used once, by the registration script     | **Yes** |
| **Webhook URL**    | a per-channel URL that anything can post to          | `discord_webhook_url` in terraform.tfvars | **Yes** |

The first three all live on the same two pages of the developer portal and are
routinely confused for one another; a fifth value, the **client secret**, sits
there too and is not used by this project at all. If the registration script
returns a 401, it is almost always because the token field got a public key or
a client secret.

You will also need your **server ID**, which comes from the Discord client
rather than the portal — see [step 9](#9-register-the-slash-commands).

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

## 3. Copy the application ID

Still on **General Information**, copy **Application ID** — about 19 digits,
with a **Copy** button under it. The **OAuth2** page shows the same number
labelled **Client ID**; either is fine, they are the same value.

This is not a credential. It only says *which* application an API call is
about: the registration script in step 9 puts it in the URL it calls,
`/applications/<application ID>/guilds/<server ID>/commands`. Authorisation
comes from the bot token instead.

Nothing needs it until step 9, so either keep it on the clipboard or set it
now:

```bash
export DISCORD_APPLICATION_ID='...'
```

## 4. Create the bot and copy its token

Go to **Bot** in the left sidebar. Recent versions of the portal create the bot
with the application, so it is already there; if you see an **Add Bot** button
instead, click it first.

Click **Reset Token**, confirm, and copy what appears. Discord shows a token
exactly once — there is no way to view it again, only to reset it and get a new
one. Resetting immediately invalidates the previous token, which is also the fix
if it ever leaks.

**What this token is for.** One thing only: `scripts/register_commands.py` uses
it to tell Discord which slash commands exist. It is never given to AWS, never
stored in Terraform, and never used by the running system — the Lambda
authenticates incoming requests with the *public key* from step 2 instead. So
the token stays on the machine you run the script from, and after step 9 you do
not need it again until you change the command list.

Because of that it does **not** go in `terraform.tfvars`. Either let the script
prompt for it, or put it in the environment for one shell session:

```bash
export DISCORD_BOT_TOKEN='...'      # not committed, gone when the shell closes
```

While you are on this page:

- **Privileged Gateway Intents** — leave all three off. They govern reading
  message content and member lists over a gateway connection, and this bot
  opens no gateway connection at all.
- **Public Bot** — turn it off if you are the only person who will add this bot
  to a server. It stops anyone else generating an invite for it.

## 5. Invite the bot to your server

The application exists, but it is not in your server yet. Go to **OAuth2** →
**URL Generator** (in newer portals there is also an **Installation** page; the
URL Generator still works and is the more explicit of the two).

- **Scopes:** check **`applications.commands`** and **`bot`**
- **Bot permissions:** none are actually required — leave them unchecked, or
  tick **Send Messages** if an empty permission set makes you uneasy

Copy the generated URL from the bottom of the page, open it in a browser, pick
your server and click **Authorize**. You need **Manage Server** on the server
you are adding it to.

Two things worth knowing about this step:

**`applications.commands` is the scope that matters.** It is what authorises
the application to have slash commands in that server. Without it, step 9 fails
with a 403 no matter how correct the token is. `bot` is what puts the
application in the member list; it is conventional rather than required.

**No permissions are required because the bot never posts as itself.** Replies
to `/start` and friends go back through Discord's interaction response, which
needs no channel permission, and the "Server is up" messages are posted by the
webhook from step 6, which carries its own.

**The bot will show as offline, permanently.** That is correct and not a
problem. A normal bot appears online by holding a gateway connection open; this
one is a Lambda that exists only for the milliseconds it takes to answer an
interaction. Slash commands work regardless of the online indicator.

If you later change the scopes, re-open the invite URL — authorisations are not
retroactive.

## 6. Create the notification webhook

This is how the server posts "Server is up" and "Server stopped due to
inactivity" into a channel. It is separate from the bot, and optional.

In Discord, right-click the channel you want the messages in → **Edit Channel**
→ **Integrations** → **Webhooks** → **New Webhook** → **Copy Webhook URL**.

```hcl
discord_webhook_url = "https://discord.com/api/webhooks/..."
```

Treat this like a password: anyone with the URL can post to that channel as your
bot. Leave it as `""` to run without notifications.

## 7. Deploy, then come back

```bash
cd terraform
terraform init
terraform apply
```

Copy the `discord_interactions_endpoint_url` output.

## 8. Set the interactions endpoint

Back on **General Information**, paste that URL into **Interactions Endpoint
URL** and click **Save Changes**.

Discord immediately sends a signed PING, plus a deliberately *invalid* request
to check that you reject it. Saving succeeds only if both behave correctly.

If it refuses to save, see
[troubleshooting](troubleshooting.md#discord-will-not-accept-the-interactions-endpoint-url).

## 9. Register the slash commands

```bash
python scripts/register_commands.py --guild <your server ID>
```

This is the call that needs all three identifiers at once:

| Value              | From                                    | How the script gets it                          |
| ------------------ | --------------------------------------- | ----------------------------------------------- |
| **Application ID** | [step 3](#3-copy-the-application-id)    | prompt, or `DISCORD_APPLICATION_ID`             |
| **Bot token**      | [step 4](#4-create-the-bot-and-copy-its-token) | prompt (hidden), or `DISCORD_BOT_TOKEN`  |
| **Server ID**      | the Discord client, below               | the `--guild` argument                          |

The server ID is the only one that does not come from the developer portal: in
Discord, **Settings** → **Advanced** → turn on **Developer Mode**, then
right-click your server icon → **Copy Server ID**. It is a server you are in,
not the application — right-clicking the *bot* copies its user ID instead,
which is a different number and will fail.

Guild commands appear instantly. Registering globally (omit `--guild`) makes
them available in every server the bot is in, but can take up to an hour to
propagate — use `--guild` while setting up.

Check what is registered at any time:

```bash
python scripts/register_commands.py --list --guild <server ID>
```

## 10. Try it

Type `/start` in the channel. You should get "Starting the server." within a
second, and a webhook message with the address a few minutes later.

---

## Restricting who can start the server

By default anyone in the Discord server can. To limit it to a role:

1. Turn on Developer Mode (step 9).
2. **Server Settings** → **Roles**, right-click the role → **Copy Role ID**.
3. Add it to `terraform.tfvars` and apply:

```hcl
discord_allowed_role_ids = ["123456789012345678"]
```

Anyone without the role gets a private "You do not have permission" reply.

Note this check is enforced in the Lambda rather than by Discord, so it applies
regardless of channel permissions.

## Restricting who can stop it

`discord_allowed_role_ids` gates every command together. To leave `/start` and
`/status` open to everyone but keep `/stop` for the people running the server,
use the role ID from step 2 above in:

```hcl
discord_stop_role_ids = ["123456789012345678"]
```

Or take the command away from everyone, so the server only ever powers off by
going idle:

```hcl
allow_stop_command = false
```

Either way the refusal is private to whoever ran the command, and says how long
the server waits when empty. See
[Who can stop the server](../README.md#who-can-stop-the-server).

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
