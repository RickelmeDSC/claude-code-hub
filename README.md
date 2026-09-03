# Claude Hub (`ch`)

A terminal panel for [Claude Code](https://claude.com/claude-code) on Windows: every
repository you can reach, the conversations you had in each one, and the memory the
project accumulated. Press Enter and Claude starts in the right directory, in the same
window.

Written in PowerShell 5.1 — the one that already ships with Windows. No install step
beyond cloning, and no dependencies other than `git`, `gh` and `claude` themselves.

```
┌─ CLAUDE HUB ────────────────────────────────────────────────────────────────── demo-user ┐
│   REPOSITORY                                       BRANCH              SESS  ACTIVITY    │
│                                                                                          │
│ ▸ alpha-worktree                               ✓   main                ·     today 13:43 │
│   alpha                                        ✓   main                4     14/08 09:00 │
│   beta                                         ↑   main                1     13/08 09:45 │
│   gamma                                        ✓   feature/x           ·     12/08 09:00 │
│   never-cloned                                 ·                       ·     11/08 09:00 │
│   old-thing                                    ·   archived            ·     01/01/25    │
│  ─── other places with history                                                           │
│   home                                         ✓                       1     14/08 09:11 │
│                                                                                          │
│  ↑↓ navigate   Enter open   / repo   s search sessions   r reload   q quit               │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

Enter on a repository gives you its history and its memory:

```
┌─ demo-user/alpha ────────────────────────────────────────────────────────────────── main ┐
│  C:\code\alpha                                            3 changed, 2 to push           │
│  Demo repository                                                                         │
│                                                                                          │
│  SESSIONS (4)                                                                            │
│ ▸ please review the deployment pipeline configuration for staging   12/08 09:20     20min│
│   Refactor the parser                                               11/08 09:08      8min│
│   Fix the login timeout                                             10/08 11:14      2h14│
│   (no conversation)                                                 09/08 07:00     <1min│
│                                                                                          │
│  MEMORY (3)                                                                              │
│   • Deploy is manual - the pipeline builds but never publishes                           │
│   • No staging database - every test runs against a local copy                           │
│   • Parser owns tokenization - do not tokenize in the reader                             │
│  Enter resume  n new  c continue  m memory  e folder  v code  Esc back                   │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

`s` searches every conversation you ever had, across all repositories — the answer to
*"which repo was I doing that in?"*:

```
┌─ SEARCH SESSIONS ──────────────────────────────────────────────────────────────── 1 of 6 ┐
│  text: deploy_                                                                           │
│                                                                                          │
│ ▸ please review the deployment pipeline configuration for staging                        │
│     alpha  •  12/08 09:20  •  main                                                       │
│                                                                                          │
│  type to filter   Enter resume   ↑↓ navigate   Esc back                                  │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

Those are real frames rendered from the test fixtures. `ch --preview` draws them for you.

## Install

```powershell
git clone https://github.com/<you>/claude-hub.git "$env:USERPROFILE\.claude-hub"
& "$env:USERPROFILE\.claude-hub\install.ps1"
```

The installer adds a `ch` function to your `$PROFILE`, between markers, and is
idempotent. If your execution policy still blocks local scripts it says so — and that
check deliberately looks only at the scopes that persist, because `Get-ExecutionPolicy`
on its own includes the Process scope and will cheerfully report that everything is fine
while a normal window is still `Restricted`.

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   # only if the installer asks
```

Then open a new PowerShell and run `ch`.

## Use

| Command | What it does |
|---|---|
| `ch` | opens the repository you are standing in, or the list |
| `ch alpha` | opens the list already filtered |
| `ch --lista` | forces the full list, even inside a repository |
| `ch -s deploy` | searches your conversations across every repository |
| `ch --reindex` | drops the caches and rebuilds |
| `ch --selftest` | runs the test suite |
| `ch --preview [width]` | draws the screens without interactive mode |
| `ch --diag` | prints the module paths and tests loading |

### Keys

**List** — `↑↓` `PgUp` `PgDn` `Home` `End` navigate · `Enter` open · `/` filter
repositories · `s` search sessions · `r` reload · `q` quit

**Repository** — `Enter` resume the selected session · `n` new conversation ·
`c` continue the last one · `m` memory · `e` open the folder · `v` open in VS Code ·
`g` open on GitHub · `Esc` back

**Search** — type to filter · `↑↓` navigate · `Enter` resume · `Esc` back

### The marker next to the name

| | |
|---|---|
| `✓` green | cloned and identical to `origin` |
| `↑` yellow | cloned, with a commit not pushed or not pulled |
| `✓` grey | cloned, no upstream configured |
| `·` grey | not cloned — `Enter` offers to clone it |

The list marker comes from comparing two SHAs read straight out of `.git`, which costs
nothing. The exact counts on the repository screen come from a real `git status`, which
costs about 200 ms — worth paying for one repository, not for all of them.

## How it works

Two sources, neither of them ever written to:

- **Sessions** — `~/.claude/projects/<slug>/*.jsonl`. Only the last 256 KB and the first
  64 KB of each file are read: enough for the title, the dates, the branch and the
  directory, even in a 31 MB transcript.
- **Repositories** — `gh api user/repos` crossed with the clones found on disk, matched
  by the remote URL read straight out of `.git/config`.

A session is matched to a repository by the `cwd` recorded **inside** the `.jsonl`, not
by the project folder name. That matters more than it sounds: on the machine this was
built for, of the 14 sessions stored under the home folder only 4 had actually happened
there. The rest were work in other repositories, and anything trusting the folder name
would have mislabelled all of them.

Subagent transcripts (`<session>/subagents/…`) are ignored — that is agent output, not
your conversations.

## Configuration

`config.json`:

| Key | Default | Meaning |
|---|---|---|
| `ScanRoots` | `~/Documents/GitHub`, `~` | where to look for clones (depth 1) |
| `CloneRoot` | `~/Documents/GitHub` | destination when cloning from the panel |
| `RepoCacheMinutes` | `30` | how long the `gh` answer stays fresh |
| `MemoryPreviewLines` | `4` | memory entries shown on the repository screen |
| `Language` | `auto` | `en`, `pt`, or `auto` to follow the console culture |

## Performance

| Moment | Time |
|---|---|
| First `ch` in a window | ~2.4 s |
| Later `ch` in the same window | ~440 ms |
| `ch --reindex` | ~5 s |

The first version took 6–10 seconds to open. Three measurements fixed that, and two of
them contradicted the assumption that prompted the measuring in the first place. They are
written up in [DESIGN.md](DESIGN.md), along with the bugs that only appear when you run
the thing for real.

## Tests

```powershell
ch --selftest
```

164 assertions against a synthetic world built in a temp folder: fake `.jsonl`
transcripts, fake `.git` directories with loose refs, packed refs and a worktree, and a
cached GitHub answer. **The suite never reads your real sessions and never touches the
network**, so it passes on a machine that has never run Claude Code.

## Requirements

Windows PowerShell 5.1 (PowerShell 7 is not needed), `gh` authenticated, `claude` on
PATH. Without a network the panel still opens, listing the local clones and flagging
itself `offline`.

## Uninstall

```powershell
notepad $PROFILE    # delete the block between >>> claude-hub >>> and <<< claude-hub <<<
Remove-Item -Recurse -Force "$env:USERPROFILE\.claude-hub"
```

Nothing is ever written under `~/.claude/`, so uninstalling touches neither your history
nor your memory.

## License

MIT — see [LICENSE](LICENSE).
