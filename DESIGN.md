# Design notes

Why the code looks the way it does. Every number here was measured on the machine this
was built for — Windows 11, PowerShell 5.1, 47 sessions totalling 145 MB of transcripts,
19 repositories, 12 local clones.

The interesting part is not the panel. It is that of the five decisions that shaped it,
**three came from measurements that contradicted the assumption which prompted the
measuring**, and two came from bugs that only exist when the thing runs for real.

---

## 1. The session title lives at the end of the file

Each `.jsonl` carries state records repeated throughout the file, among them
`{"type":"ai-title","aiTitle":"..."}`. In a 31 MB transcript the last occurrence of
`aiTitle` sits at byte 32,598,767 of 32,610,304 — **in the final 12 KB**. The same holds
for the most recent `timestamp`, `gitBranch` and `cwd`.

**Consequence:** there is no need to read the file. Reading the last 256 KB and the first
64 KB gives every piece of metadata at constant cost, whatever the size.

## 2. The project folder name is ambiguous; the `cwd` inside the file is not

`~/.claude/projects/` names each folder after a slug of the path, where `\`, `:`, `_` and
`.` all become `-`. That makes `C--Users-me-code-app-backend` indistinguishable between
`code\app-backend` and `code\app\backend`. The drive letter also appears in both cases.

**Consequence:** matching a session to a repository does **not** use the folder name. It
uses the `cwd` field from inside the `.jsonl`, which holds the real absolute path, and
matches by longest prefix.

This is not a theoretical nicety. On the machine this was built for, the home folder's
project directory held 14 sessions — but only 4 had happened in the home folder. Seven
were work in one repository, one in a subfolder of another, one in a third. A tool that
trusted folder names would have mislabelled ten of fourteen. A pleasant side effect falls
out of the same rule: a session started in `app\frontend\src` rolls up into `app`.

## 3. `git status` costs 200 ms; the SHAs are free

Measured: `git status --porcelain=v2 --branch` takes 180–250 ms per repository. With 12
clones, showing git state in the list would cost 2–3 s on every open. Not viable.

But the local branch SHA (`.git/refs/heads/<b>`) and the remote one
(`.git/refs/remotes/origin/<b>`) are text files. Comparing them does not say **how many**
commits apart, but it does say **whether** there is a difference — and that costs about
60 ms for all 12 clones, spawning no process at all.

**Consequence:** the list shows the cheap signal (`✓` in sync, `↑` diverged); the
repository screen, where you have already chosen to look at one thing, pays for the real
`git status` and shows exact numbers. The test suite checks the cheap reading against
real `git` output, repository by repository.

Two traps surfaced while building it: refs may be packed into `.git/packed-refs` instead
of sitting loose, and in a **worktree** the `.git` is a *file*, `HEAD` is local, but the
refs live in the main repository named by `commondir`.

## 4. A useless title is a missing filter, not a missing read

Twelve of 47 sessions displayed badly. Looking closer, they were three different
problems: two sessions contained only a `/model` command and no assistant turn at all;
four had opened with "good morning" and Claude never renamed them; six had a fine title
and only lacked the caption.

The obvious suspicion was that the 64 KB read window was too small. **Measuring showed
the opposite**: in the 31 MB file, the first substantive request appears well inside the
first 64 KB. What was missing was a filter that skips greetings.

**Consequence:** greetings and text under 25 characters are not eligible to become a
title; when the AI title is generic, the first substantive request takes its place; a
session with no assistant turn is labelled `(no conversation)` rather than `(untitled)`,
because calling it untitled implies a defect that is not there. Twelve bad titles became
one — a 52 KB session where the person genuinely only ever wrote "hello".

## 5. `$script:` does not bind to the file that declared the variable

This one broke the tool on its very first real run, and no test caught it.

The `ch` function in `$PROFILE` loads the modules in one scope, and `ch.ps1` calls their
functions from another. `$script:ChRoot`, declared at the top of the repository module,
does **not** resolve to the file that declared it — it resolves to *the script that is
executing at call time*, where the variable was never set. `Join-Path` received `$null`
and the panel died before drawing anything.

**Consequence:** all module state is `$global:` with a `Ch` prefix. Not elegance — the
only way a set of loose `.ps1` files (rather than a real `.psm1` module) can keep state
across script boundaries.

**Why the tests missed it:** they loaded and called everything in the same scope, where
`$script:` works fine. The suite was testing the mechanism, not the arrangement.
`tests/ScopeProbe.ps1` now exists solely to reproduce the boundary: a genuinely separate
script that calls functions loaded by someone else.

## 6. `return @(...)` with a single item returns the item

Searching for one word found exactly one session and reported "nothing found", with the
match sitting right there. `return @(...)` hands back the bare object when the array has
one element, so `.Count` came back empty.

The tempting fix is the unary comma (`return ,@(...)`) in every function. That was tried:
**it broke 14 tests at once**, because nearly every caller in this codebase already wraps
results in `@()`, and the two together produce an array inside an array.

**Consequence:** one convention, no exceptions — functions return the array directly and
**the caller wraps with `@()`**.

---

## Performance, and how it got there

The first working version took **6–10 seconds** to open. Profiling found three things,
none of them where the code looked slow:

| Cause | Cost | Fix |
|---|---|---|
| `ConvertFrom-Json` rebuilding 47 cache records | **1.36 s** | own TAB-separated line format, parsed with `String.Split` |
| `Get-ChildItem` vs `Directory.GetFiles` for the same 47 files | 186 ms vs **27 ms** | `System.IO` directly; the cmdlet wraps every item in a PowerShell-adapted object |
| `Get-Command` as a module-load guard | 7 ms per call | `Test-Path Function:\Name`, 0.45 ms |

And a fourth that was pure bug: the cache stored the file timestamp as an ISO string.
PowerShell 5.1's `ConvertFrom-Json` **converts anything that looks like a date into a
`DateTime`**, so the comparison never matched and the index reparsed 145 MB on every
single open. The self-test now asserts that a warm run reparses exactly zero files.

Result: cold index 3.1 s to 217 ms. A warm open of the panel costs ~640 ms with 16
local clones, of which the session index is only ~70 ms — the rest is the repository
scan, which grows with the number of clones rather than with the size of the history.

## Verifying the tests, not just running them

A green suite proves nothing on its own. `tests/Mutants.ps1` copies the repository,
breaks one behaviour at a time, and runs the suite against the broken copy. Anything the
suite fails to notice is a blind spot.

The first run caught 10 of 12. The two survivors were worth the exercise:

- **The longest-prefix rule was never exercised.** Every fixture repository was a
  sibling of the others, and the rule only decides anything when one repository sits
  inside another. Adding a nested repository — reachable, as in real life, by giving it
  its own scan root — turned five passing assertions into five that can actually fail.
- **A caller forgetting `@()` was invisible.** The convention is that callers wrap, and
  the tests wrapped too, so the omission that shipped could not be caught by any normal
  assertion. It is now checked against the source: the guarded call sites are read from
  the files themselves and asserted to be wrapped.

All 12 are caught today. The number is not the point — the two it found are.

## Rendering

One rule makes the box impossible to break: **every line is measured with the ANSI
escapes stripped**, and a single function decides the final size of every frame. Screens
build a body; that function trims what exceeds the height, pads what is missing, and
nails the key bar and bottom border on.

This is checked, not eyeballed — the escapes hide misalignment from a human reader. The
suite renders all four screens at five terminal sizes, in both languages, and asserts
that every line has the same visible width and that the frame fills the height exactly.
A 60×16 terminal found a real overflow that no amount of looking would have caught.

The panel runs in the terminal's alternate buffer (`ESC[?1049h`), so it never pollutes
your scrollback, and it leaves that buffer before starting Claude — which means the
conversation lands in your normal history, where you can scroll back through it later.

One more subtlety worth writing down: `$r = Show-ChRepoDetail ...` would have been the
natural way to get a result out of the detail screen. It is also a trap. Assigning the
output of a call makes PowerShell capture that pipeline, which redirects the stdout of
the `claude` process running inside it and breaks its interface. The result travels in a
global instead.
