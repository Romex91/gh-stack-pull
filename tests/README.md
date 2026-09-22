# Tests

End-to-end, against a real GitHub repository, with the real `gh`, `gh-stack`
and `git`. Nothing is mocked.

```
TESTBED_REPO=owner/repo tests/run.sh [name-filter]
```

The testbed's description must contain `gh-stack-pull e2e testbed`; the runner
refuses any other repo. Before every test it closes all open PRs, unstacks all
stacks, deletes every branch except the default one and force-pushes the
default branch to a fresh root. Run one instance at a time.

Each test builds `main <- s1 <- s2 <- s3` and clones it twice. `A` is the
machine under test. `B` is the other machine: it rewrites or clobbers the stack
with the real `gh stack sync`, then `A` runs `gh stack-pull`. Assertions are
plain git. About 25 seconds per test. `KEEP=1` keeps every work dir; a failed
test's work dir is always kept and its path printed.
