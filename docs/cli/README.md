# `openhuman`: Mail by OpenHuman on the command line

The CLI reads the same local cache as the Mac app and writes changes to the local queue the app applies. It holds no
tokens, never calls Gmail and never sends mail. Contract: `docs/cli/schema.json`. For AI agents and MCP clients:
`docs/cli/AGENTS.md`. Every command as data: `docs/cli/schema.json` (`openhuman schema --json`).

## Install

```sh
swift build -c release --product openhuman --package-path Packages/OpenHumanCLI
ln -s "$PWD/Packages/OpenHumanCLI/.build/release/openhuman" ~/.local/bin/openhuman
```

Shell completions (ArgumentParser's built-in generator):

```sh
openhuman --generate-completion-script zsh  > ~/.zfunc/_openhuman      # zsh: ~/.zfunc on your fpath
openhuman --generate-completion-script bash > ~/.openhuman-completion.bash   # bash: source it from ~/.bashrc
openhuman --generate-completion-script fish > ~/.config/fish/completions/openhuman.fish
```

## Commands

| Area | Commands | Writes |
|---|---|---|
| Accounts and sync | `accounts list/alias/default`, `auth status`, `sync status/run` | local settings only |
| Read | `gmail search/list/inbox/get`, `gmail thread get`, `gmail labels list`, `gmail counts`, `gmail splits list/show` | no |
| Triage | `gmail done` (`archive`), `move-to-inbox` (`unarchive`), `read`, `unread`, `star`, `unstar`, `snooze`, `unsnooze`, `remind`, `unremind`, `undo` | queued for the app |
| Drafts | `gmail drafts list/get` (`show`)`/create/update/reply/forward/delete` | drafts for review; never sent |
| Review queue | `gmail review list/show [--diff]/open`, `gmail review approve/reject` (a person at a terminal only) | review state |
| Snippets | `gmail snippets list/show/render/add/delete/export/import` (the app's `openhuman-snippets` file) | local snippets |
| Links | `link thread/draft/review/search/compose` (`--open`) | no |
| Tools | `schema`, `doctor`, `config get/list/set`, `mcp [--readonly] [--list-tools]` | `config set` only |

Planned, registered and answering exit 13: `gmail thread modify`, `batch modify`, `trash`, `untrash`, `spam`,
`not-spam`, `labels create`, `splits create/update/delete/reorder`, `attachments get`. Needing network access (exit 12
in this build): `accounts add/remove`, `auth login/logout`, `sync watch`, `gmail history`, `calendar events`.

## Output and versions

Default output is JSON when stdout is not a terminal (`--json`, `--jsonl`, `--plain`, `--human`, or
`OPENHUMAN_OUTPUT`). The envelope is `{"schema": "openhuman.cli/v1", "command", "ok", "data" | "error", "meta"}`;
within v1 fields are only added. `openhuman --version` prints the CLI version; `schema --json` carries `version`
(the envelope schema) and `cliVersion`. Exit codes 0 to 13 are listed in `AGENTS.md` and `schema.json`.
