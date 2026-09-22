# gh stack-pull

Pull-only sync for [gh-stack](https://github.com/github/gh-stack).

# The problem

When editing stacks from two machines, `gh stack sync` silently drops the updates from remote. 
Worse than that `gh stack` provides no solution. This is absolutely ridiculous. `gh stack sync` should be renamed to `gh stack rebase-and-force-push`

[gh-stack issue #516](https://github.com/github/gh-stack/issues/516).

`gh stack-pull` is a cure: fetch, adopt the remote, replay on top whatever existed there. Like `git pull --rebase`, but for the whole stack.

```
gh stack-pull [--remote <name>] [--discard-local] [--dry-run]
```

## Install

```
gh extension install Romex91/gh-stack-pull
```

Requires `gh` with the `gh-stack` extension, `git`, and `jq`.

## Working from two machines

Start every session with `gh stack-pull`, end it with `gh stack sync`. Never
leave unpushed commits on a machine you are walking away from.
