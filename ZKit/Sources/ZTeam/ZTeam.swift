import Foundation
import ZCore

/// ZTeam: several agents working on one goal and one machine.
///
/// Entry points:
/// * `TeamRunner` — builds one `AgentRunner` per `TeamMember` and runs the phases: the lead plans the goal into
///   board tasks → workers do them concurrently (bounded, failed tasks retried once) → the reviewer checks the
///   results (may reopen tasks once) → the lead writes the final report (`TeamOutcome`).
/// * `TaskBoard` — the shared task list (todo / doing / blocked / done / failed, dependencies, attempts).
/// * `SurfaceLease` + `LeasedSurface` — exclusive input on a shared `ComputerSurface` (screenshots never wait).
/// * `MessageBus` — agent-to-agent messages; the `team_*` / `board_*` tools in `TeamTools`.
///
/// Everything a team does is visible twice: as ZCore `AgentEvent`s on the shared `EventBus` (team changes as
/// `.note`s from the "Team" pseudo-agent) and as typed `TeamEvent`s on a `TeamEventHub`.
public enum ZTeamModule { public static let name = "ZTeam" }
