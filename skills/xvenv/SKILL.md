---
name: xvenv
description: Inspect, configure, and use xvenv-managed portable Windows development tools for a repository. Use when a task mentions xvenv, asks to prepare a project-scoped Bun, PowerShell, Python, or Go environment, or needs a command run inside an existing xvenv environment.
---

# Xvenv

Use the non-interactive xvenv commands from the target repository directory.
Keep xvenv's central data model intact: these commands must not create config
files inside the user's repository.

## Workflow

1. Inspect the current environment:

   ```powershell
   xvenv status --json
   ```

   Treat `configured` and `ready` as data. A successful query exits with zero
   even when either field is false.

2. Discover supported tools when needed:

   ```powershell
   xvenv tools --json
   ```

3. Configure only when the task requires it and the desired tool set is known:

   ```powershell
   xvenv set bun pwsh python go
   ```

   `set` declares the complete desired public tool set; omitted tools are
   removed from the project's xvenv configuration. When changing an existing
   environment, preserve every still-wanted tool reported by `status --json`.

4. Run the requested program inside the environment:

   ```powershell
   xvenv exec bun --version
   xvenv exec python -m pytest
   xvenv exec .\scripts\check.ps1
   ```

   Forward the program's stdout and stderr. Treat the `xvenv exec` exit code as
   the program's exit code.

## Rules

- Never invoke bare `xvenv`; it opens an interactive terminal for humans.
- From PowerShell, invoke `xvenv` by name; do not force the `.cmd` frontend.
  PowerShell resolves the argument-safe `xvenv.ps1` frontend.
- Prefer executing a program or script directly. Avoid wrapping complex text in
  `pwsh -Command` or `cmd /c`; nested shells introduce avoidable quoting rules.
- Do not run `xvenv set` merely to inspect or repair speculatively.
- Do not edit generated `env.cmd` or `env.ps1`; regenerate them with `xvenv set`.
- Parse JSON fields instead of human-formatted command output.
