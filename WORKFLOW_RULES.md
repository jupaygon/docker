# Development Workflow Rules (Humans + AI Agents)

This document defines the **global operational workflow rules** for all repositories.

It applies equally to:

- Human developers
- AI coding agents and AI-powered IDEs (Claude Code, Codex, Cursor, Antigravity, Windsurf, etc.)

Repository-specific details must remain in each project `README.md`.

---

## 1. Core Principle: Agents Work Like Human Developers

AI agents are treated as full developers working under the same team rules:

- Full autonomy inside their own branch/worktree
- No direct changes to `master`
- No merge authority (human review required)

All work must remain isolated, reviewable, and reversible.

---

## 2. Task → Branch → Worktree Standard

Tasks may originate from Jira tickets or be described directly by the human.

### Workflow

1. Human provides a task via:
  - Jira ticket ID (agent reads it using `/Users/dev/Workspace/common/jira-read.sh <JIRA_KEY>`)
  - Jira ticket ID + title + description (pasted manually)
  - Free-form task description (no Jira ticket)
2. Agent creates a dedicated branch + worktree
3. Agent implements the task

If `.jira.conf` is not available, the human provides ticket context and acceptance criteria manually.

---

## 3. Branch Naming Convention

Branches must include the Jira key when available:
```
feature/<JIRA_KEY>-<slug>
```

Example:

```
feature/ZN-431-fix-login-timeout
```

If no Jira ticket exists:
```
feature/<slug>
```

Base branch is always:

- `master`

---

## 4. Worktree Naming Convention

Each branch must be developed in an isolated worktree:

```
wt-<repo>-<JIRA_KEY>-<slug>
```

⚠️ **IMPORTANT: Worktree folder names must be entirely lowercase.** DNS hostnames are case-insensitive (browsers lowercase them), but the Linux filesystem inside Docker is case-sensitive. A folder named `wt-my-project-ZN-431-slug` will NOT match the hostname `wt-my-project-zn-431-slug`, causing the local dev URL to fail.

Example:

```
wt-my-project-zn-431-fix-login-timeout
```

If no Jira ticket exists:
```
wt-<repo>-<slug>
```

This enables parallel execution of multiple tasks/agents.

---

## 5. Required Agent Workflow (Mandatory)

Agents must follow this exact sequence:

1. Create branch
2. Create worktree
3. Implement changes inside worktree
4. Run tests
5. Report results
6. Wait for human approval before commit/push

Agents must never skip isolation.

---

## 6. Worktree Bootstrap (Required Non-versioned Files)

Git worktrees do **not** include non-versioned files. Some repositories require local-only files to function.

After creating a new worktree, the agent **must** ensure these files exist in the worktree via symlinks to the main repository folder.

### Resolving the repository root

The main repository folder (the one containing `.git`) can always be resolved dynamically:

```bash
REPO_ROOT=$(git worktree list | head -1 | awk '{print $1}')
```

### Creating symlinks

⚠️ **IMPORTANT: Symlinks must be created from INSIDE Docker**, not from the host machine.

Host paths (e.g. `/Users/dev/...`) do not exist inside the container, so symlinks created on the host with absolute paths will be broken inside Docker. This causes hard-to-debug errors (e.g. missing env vars, `Unable to find the controller`).

**Correct way** — run from inside Docker using relative paths:

```bash
docker exec -w /var/www/html/<worktree-folder> dj_php ln -s ../my-project/.github.conf .github.conf
docker exec -w /var/www/html/<worktree-folder> dj_php ln -s ../my-project/.env.local .env.local
docker exec -w /var/www/html/<worktree-folder> dj_php ln -s ../my-project/.jira.conf .jira.conf
```

Replace `my-project` with the actual main repository folder name (the parent `<repo>` folder).

**Wrong way** — do NOT do this:

```bash
# ❌ Creates absolute host paths that break inside Docker
REPO_ROOT=$(git worktree list | head -1 | awk '{print $1}')
ln -s "$REPO_ROOT/.env.local" .env.local
```

### Rules

- NEVER copy these files
- NEVER commit these files
- NEVER cat, print, or display the contents of `.github.conf` or `.jira.conf`
- `.github.conf.dist`, `.jira.conf.dist` and `.env` are templates only

---

## 7. Git Permissions and Restrictions

### Allowed

- `git status`
- `git diff`
- `git add`
- Local edits inside worktree

### Forbidden without explicit human request

- `git commit`
- `git push`
- Creating pull requests
- Merging branches
- Rebasing shared branches

Human must explicitly say:

- "commit"
- "push"
- "open PR"

---

## 8. GitHub Authentication (Agents Only)

### Git Protocol: HTTPS Only (Agents)

Agents must **NEVER** use SSH for git operations.

⚠️ **NEVER modify the remote URL** with `git remote set-url`. The remote URL belongs to the human developer (typically SSH). Changing it replaces their credentials with the agent token, breaking their push access.

Instead, pass the agent credentials **inline** in push commands:

```bash
source .github.conf
git push https://${GITHUB_AGENT_USER}:${GITHUB_AGENT_TOKEN}@github.com/<owner>/<repo>.git <branch>
```

This uses the agent token for that single operation without altering the repository configuration.

### Agent Identity for Commits

Before performing any authenticated GitHub operation (including Composer installs requiring private repos), ensure `.github.conf` is available (see section 6) and then source it:

```bash
source .github.conf
```

Then, all git commands in that shell session will use the agent identity:
- `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` — Who wrote the code
- `GIT_COMMITTER_NAME` / `GIT_COMMITTER_EMAIL` — Who committed it

### Fine-grained tokens and `gh` CLI

The agent token is a **GitHub fine-grained (repository-scoped) token**, not a classic token.

`gh auth login` requires the `read:org` scope which only exists on classic tokens, so **`gh` CLI commands will fail** with fine-grained tokens.

For operations that require the GitHub API (creating PRs, commenting on issues, etc.), use the **REST API directly** with `curl`:

```bash
source .github.conf

curl -s -X POST \
  -H "Authorization: Bearer $GITHUB_AGENT_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/<owner>/<repo>/pulls \
  -d '{
    "title": "PR title",
    "head": "feature/ZN-XXX-slug",
    "base": "master",
    "body": "PR description"
  }'
```

Git push/pull operations work normally since they use git protocol authentication, not the GitHub API.

**Important:**
- The token file `.github.conf` is excluded from version control.
- See `.github.conf.dist` for the expected format.
- This token belongs to a dedicated agent account with limited permissions.
- Do not commit or expose the token value in logs, PR descriptions, or any output.
- User commits remain unaffected (they use their global git config).

---

## 9. Cleanup Policy

After a PR is merged by a human:

- The worktree folder must be removed
- The branch may be deleted

Example:

```bash
git worktree remove wt-my-project-ZN-431-...
git branch -d feature/ZN-431-...
```

⚠️ **IMPORTANT: Verify the folder is actually deleted.** `git worktree remove` may silently leave the folder behind if it contains non-tracked files (e.g. `.idea/`, `.phpunit.cache/`, `node_modules/`). Always check and force-remove if needed:

```bash
# After git worktree remove, verify the folder is gone
ls wt-my-project-ZN-431-... 2>/dev/null && rm -rf wt-my-project-ZN-431-...
```

Agents must not delete worktrees automatically unless requested.

---

## 10. Definition of Done

A task is complete only when:

- Code follows project architecture rules (Hexagonal + SOLID)
  - Use dependency injection for all dependencies.
  - Define interfaces before implementations.
  - Maintain clean separation between layers.
- Tests pass (when applicable)
- No forbidden operations were executed (migrations, deploy, secrets)
- A clear summary is provided:
  - Files changed
  - Validation commands run and their results
  - Local testing URL for the worktree (e.g. `http://<worktree-folder>.<repo-folder>.test:81`)

---

## 11. Communication and Autonomy Rules

Agents must:

- Work autonomously inside their branch/worktree
- NEVER ask permission for pre-authorized operations (section 13)
- NEVER ask "can I open/read/edit this file?" — just do it
- NEVER ask "can I run composer install/phpunit?" — just do it
- Stop only at high-risk boundaries (section 13: commit/push/migrations/deploy)
- Report results concisely when task is complete

---

## 12. User Context

- **Primary Language**: Spanish (but code/docs in English)
- **Experience**: Strong PHP/Symfony background with Hexagonal Architecture and SOLID
- **Expectations**:
  - Clean, maintainable code
  - Proper abstractions and interfaces
  - Easy to swap implementations
  - Well-documented architectural decisions

---

## 13. Agent Tool Permissions (Reference)

Agents have **full autonomy** inside their branch/worktree. The following operations are pre-authorized and must not require interactive confirmation:

### Allowed without confirmation

- All `docker exec` commands (composer, phpunit, console, etc.)
- Git read operations (`status`, `diff`, `log`, `branch`, `worktree`)
- `git add` (staging files)
- Creating symlinks (`ln -s`)
- Sourcing `.github.conf` and `.jira.conf`
- Running `/Users/dev/Workspace/common/jira-read.sh`
- Reading, editing, and writing files inside worktree directories

### Require explicit human approval

- `git commit`, `git push`
- Creating pull requests
- Database migrations
- Deployment
- Editing `.env`, `.env.local`, `.github.conf`, `.jira.conf`, `deploy.php`
- Introducing new external dependencies

### Forbidden High-Risk Operations (never, even if requested, human-only responsibility)

- Pushing to master/main
- Merging pull requests
- Editing production infrastructure
- Changing authentication/secrets
- Exposing tokens or secrets in output

### Tool-specific configuration

Each agent tool should enforce these allow/deny rules in its own configuration format:

- Claude Code: `.claude/settings.json`
- Cursor: `.cursorrules`
- Others: equivalent configuration

---

## 14. Local Development URLs

- Main: `http://<repo-folder>.<repo-folder>.test:81`
- Worktrees: `http://<worktree-folder>.<repo-folder>.test:81`

---

## 15. References

- Runtime rules: `SYMFONY.md` (or equivalent per stack)
- Repository-specific rules: `README.md`
- Agent entrypoint: `AGENTS.md`

---

**All work must remain isolated, reviewable, and reversible.**
