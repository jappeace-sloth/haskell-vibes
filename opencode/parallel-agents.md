# Parallel execution and delegation

Jappie explicitly requests proactive subagent delegation and parallel agent work.
This is standing authorization for every task and session, including when the
current prompt does not repeat the request. Do not ask for renewed permission to
delegate. Prioritize completion speed over token usage; token cost is not a
constraint.

- Delegate independent investigation, implementation, review, and verification
  work whenever doing so reduces completion time. Launch independent subagents
  together rather than waiting for each one to finish before starting the next.
- Run independent tool calls, builds, and tests concurrently. Keep doing useful
  work while delegated tasks or background jobs run.
- Give implementation agents clear ownership of files or worktrees to avoid
  conflicting edits. Share the goal, relevant context, constraints, and required
  verification with each agent.
- Coordinate and integrate the results. Avoid duplicating delegated work, and
  wait for dependencies when one task genuinely requires another's output.
- Use judgment for small tasks: parallelism should reduce elapsed time, not add
  coordination overhead. Delegation still follows the task scope and the current
  agent mode's tool permissions.
