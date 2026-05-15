---
name: pr
description: >
  Create or update a GitHub pull request. Use when you need to open a PR,
  when the user asks for a PR, or after completing work that should be
  submitted as a pull request. Handles stale/closed/merged PRs automatically
  by checking remote state before acting — never relies on memory of PR state.
allowed-tools: Bash, Read, Grep, Glob
---

# Pull Request Workflow

Create or update a pull request for the current branch.

## Critical Rule

**NEVER rely on your memory of PR state.** Always check the remote before
acting. PRs get merged, closed, or updated by other people and other agents.
Your cached knowledge of "PR #42 is open" may be wrong.

## Process

### 1. Gather context

Run these in parallel:

```
git status
git branch --show-current
git log --oneline -10
```

Identify:
- Current branch name
- What remote to push to (check `git remote -v`)
- What the base branch is (usually `master` or `main`)

### 2. Check for existing PRs on this branch

```bash
gh pr list --head "$(git branch --show-current)" --repo OWNER/REPO --json number,state,url --jq '.[]'
```

If the repo is a fork, include the fork owner in `--head`:
```bash
gh pr list --head "FORK-OWNER:$(git branch --show-current)" --repo TARGET/REPO --json number,state,url --jq '.[]'
```

Evaluate the result:
- **Open PR exists**: Update it (push new commits, optionally update description)
- **Merged or closed PR exists**: Create a new PR (do NOT try to reopen)
- **No PR exists**: Create a new PR

### 3. Push the branch

Make sure the branch is pushed and up to date:

```bash
git push REMOTE BRANCH
```

Use the appropriate SSH command if needed:
```bash
GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=/tmp/ssh-home/known_hosts" git push REMOTE BRANCH
```

Never force push unless explicitly asked.

### 4. Create or confirm the PR

When creating a new PR, use a HEREDOC for the body to preserve formatting:

```bash
gh pr create --repo TARGET/REPO --head FORK-OWNER:BRANCH --title "Title here" --body "$(cat <<'EOF'
## Summary
- Bullet points describing what changed and why

## Test plan
- [ ] Verification steps

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

### 5. Report the URL

Always show the user the PR URL when done.

## Determining the target repo

Follow these rules in order:
1. If pushing to `snoyberg/keter` or `winterland1989/mysql-haskell`, target those directly
2. If a `jappeace` remote or upstream exists, target the `jappeace` org repo
3. If only `jappeace-sloth` exists as the org, target `jappeace-sloth`
4. When in doubt, ask the user

## PR title and body guidelines

- Keep the title under 70 characters
- Summarise the *why*, not the *what* — the diff shows the what
- Include a test plan with checkboxes
- Do not include token counts or prompt text in the PR body

## Common pitfalls

- **Stale PR reference**: You said "PR #36" three messages ago but it got
  merged since. Always `gh pr list` or `gh pr view` before acting.
- **Wrong target repo**: Fork PRs need `--head FORK-OWNER:BRANCH` and
  `--repo TARGET/REPO` — these are different repos.
- **Numbering after merge**: If PR #30 was merged and you need changes on
  top, create a new branch or new PR. Don't try to reopen merged PRs.
