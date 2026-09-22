# gh stack-pull

Pull-only sync for [gh-stack](https://github.com/github/gh-stack).

# The problem

When editing stacks from two machines, `gh stack sync` drops the updates from remote silently. 
Worse than that `gh stack` provides no solution. This is absolutely ridiculous. `gh stack sync` should be renamed to `gh stack force-push`

[gh-stack issue #516](https://github.com/github/gh-stack/issues/516).

`gh stack-pull` is a cure: `git pull` for the whole stack. Fast-forwards what it can, stops on a diverged branch; `--rebase` replays your local commits on top of the remote instead, like `git pull --rebase`.

```
gh stack-pull [--rebase] [--remote <name>]
```

## Install

```
gh extension install Romex91/gh-stack-pull
```

Requires `gh` with the `gh-stack` extension, `git`, and `jq`.

## Working from two machines

Start every session with `gh stack-pull`, end it with `gh stack sync`. Unpushed commits are fine: the next `gh stack-pull --rebase` on that machine adopts whatever the other machine pushed and replays them on top.
