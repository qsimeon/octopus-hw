# Octopus — Design Philosophy

Eight principles behind the project. Every decision reduces back to one or
more of these. Two implementation tactics live further down — they're useful
to name but they aren't load-bearing principles.

> A note on the count. An earlier draft had six principles and demoted RALPH
> and the Markov pattern to "implementation tactics." Both belong as
> first-class principles: RALPH because it's the *only* control structure in
> the system (every stage, every daemon tick, every heal action is a RALPH
> iteration), and Markov state propagation because it's the contract that
> keeps context bounded across all of those iterations. They are distinct
> axes — RALPH is control flow, Markov is state shape — so they get separate
> slots rather than being folded together. "Minimal harness" stays separate
> from RALPH for the same reason: minimalism is an architectural value about
> what *not* to put in Python; RALPH is the loop shape itself.

---

## 1. Prompts as protocol

The `protocol/*.md` files are the product. They describe *what to do*; the
agent writes *how to do it* at install time, on the specific machine in front
of it. Specs are markdown — written in English with just enough structure for
an LLM to parse output paths and success conditions.

This is the foundational move: every other principle assumes specs-as-code is
the working frame. Specs don't rot across platforms (Mac, Linux, Windows WSL) or
across models (GLM, Claude, Kimi, Gemini) because the *implementation* is
re-derived per machine. A shell script that calls `lsusb` works on Linux but
not BSD; a spec that says "enumerate every connected USB device" works on
both, because the agent picks the right tool for the OS it's running on.

What this rules out: device manifests, hardcoded driver registries,
platform-specific Python, and "if device == 0x1a86" conditionals (see #5).

## 2. Self-reference with two faces

Octopus is self-referential in two distinct ways. They share a conceptual
shape (the system observes itself) but they're independent mechanisms — don't
conflate them.

**Software self-editing.** Failed pipeline stages are permitted to rewrite the
spec that governs them on retry. The watch/heal daemon tails the generated
server's logs, reasons about its own health, and self-heals on degradation
(missing dep, server crash, broken tool). Pure software; works headless on any
platform; has nothing to do with cameras.

**Hardware self-perception.** When the platform has a camera, the system gives
itself a *mirror* — the perceive step generates a thin capture bridge so one
peripheral can observe the others. The agent maintains a Markov visual state
(current frame, previous frame, rolling text summary — a specific instance of
the general pattern in #8) so it can verify its own physical actions. A
demo-specific design choice we find compelling in its own right
(self-referential robotics).

The first face is what makes the daemon *adaptive*. The second face is what
makes the demo *closed-loop*. They are related (both look at the system from
inside the system) but they live at different layers and have different
prerequisites.

## 3. Privileged framework steps

The general pipeline (probe → identify → interface → serve → deploy) stays
device-agnostic. When a piece of hardware is demo-critical and benefits from
curated context, we add a *privileged framework step* (`protocol/privileged/perceive.md`,
`protocol/privileged/arm.md`) that runs *after* the general pipeline and *only* if that
hardware is discovered.

This names the messy compromise rather than pretending it doesn't exist.
"Hardware-agnostic" was always aspirational; what's actually true is
"device-agnostic for the general path, with privileged hooks for hardware we
care about." The hooks are explicit, scoped, and gated on presence — so a
fresh install on a machine without an arm doesn't drag in arm-specific specs.

What this rules out: `if device_class == "robotic_arm": ...` in the general
pipeline; merging perceive/arm logic into the orchestrator; assuming demo
hardware is "general."

## 4. Interface-agnostic, output-divergent

Three independent layers — swap any one in a single config line:

```toml
command = "pi"                          # HARNESS (pi-coding-agent, amp, opencode)
model   = "openrouter/z-ai/glm-5.1"     # BRAIN  (any model the harness supports)
protocol/*.md                            # SPECS  (what to do)
```

The harness (`pi`, `amp`) provides the agent loop and file/shell tools. The
brain reads the specs. The specs are the same across runs.

But: different brains produce *different outputs* on the same hardware. One
model writes `arm_set_joint_angle`; another writes
`so_arm101_arm_set_joint_angle`. Tools may differ in count, naming, and even
parameter shape across runs. The interface contracts (MCP tool schema, FastMCP
server shape) hold; the *output* content varies.

This is the honest version of the old "model-agnostic" claim. The system is
interface-agnostic; the outputs are model-divergent. Both halves matter.

## 5. Model calls replace code debt

A model call is a unit of code. When the alternative is a brittle parser, an
exception cascade, a regex chain, or an enumeration of conditions you can't
fully list — write a prompt instead. Models are now cheap and capable enough
that they're a first-class implementation primitive, not a fallback.

Concrete patterns that become model calls:

- **Log summarization.** The daemon's heal cycle reads the server log and
  asks a small model to summarize what's wrong. The alternative is a
  200-line regex/grep/awk parser that breaks the moment the log format
  shifts. The prompt is 20 lines and survives format drift for free.
- **Error categorization.** "Is this exception a missing dependency, a
  hardware disconnect, a permission issue, or a logic bug?" — a four-way
  classification that would be a tangle of `except` clauses becomes a
  prompt with four labels.
- **Structured-output extraction.** Pulling JSON or fields out of a tool's
  semi-structured stdout. A regex works for one tool version and breaks on
  the next; a prompt that says "extract the device serial" doesn't.
- **Device identification.** `if device_id == "1a86:7523": capabilities = [...]`
  is the canonical bad pattern. The model knows what a CH340 is. Strengthen
  the spec instead of patching the code.
- **Failure-mode classification in retries.** When a stage fails, deciding
  *how* to retry (edit the spec? change the model? abort?) is a judgement
  call, not a switch statement.

The discipline is: when you feel yourself reaching for `if/elif/else` over a
list you can't fully enumerate, or for a parser whose grammar you don't fully
know, that's the signal. Write the prompt.

Use small/cheap models for the simple classifications (log summaries,
field extraction); reserve larger models for the load-bearing reasoning
(spec rewrites, heal decisions). A model call has a price; pick the right
one.

**Caveat.** This rule applies to *knowledge* problems (the model knows or
doesn't), not to *control* problems. Thermal cooldown logic, voltage checks,
USB autosuspend handling, joint duty-cycle enforcement — those are real
if/then control flow that *must* live in the generated server, because they
govern physical safety and run at frequencies where a model call is wrong on
latency, reliability, and cost. Knowledge belongs in prompts; safety belongs
in code.

## 6. Minimal harness

The orchestrator coordinates; the agent and the specs do the thinking. It
reads `octopus.toml`, spawns a coding agent per stage, checks whether an
output file exists, and loops. There is no device-specific code in the
orchestrator — when we find ourselves adding a conditional for a specific
device, we've made a mistake (#5).

This is a *value*, not a measurement. The line count is what it is; "minimal"
isn't a number we defend. What we defend is: every line of orchestrator code
should be answering a coordination question (which stage runs next, which
spec to render, what to do on retry) — not a hardware question (what does
this CH340 USB chip control). Hardware questions belong in specs.

## 7. RALPH loop

**Read** the spec → **Agent** executes → **Loop** (check the output file) →
**Pass/Halt**. This is the only control structure in Octopus. Every pipeline
stage is a RALPH iteration. Every daemon tick is a RALPH iteration. Every
heal action is a RALPH iteration. There is no second loop, no event queue,
no scheduler — just RALPH, instantiated repeatedly with different specs and
different output-file checks.

Why it's a principle and not a tactic: RALPH is what makes the rest of the
system tractable. Because every step has the same shape, retry policy is
uniform (re-run with optional spec edit), failure detection is uniform
(output file present and well-formed?), and the orchestrator is small (#6)
because it only needs to know how to run *one* loop. Replacing RALPH would
mean inventing per-stage control flow, which would push hardware logic back
into Python and break #1.

The "L" — looping by checking an output file — is also what enforces the
spec contract. Specs declare their output paths and success conditions in
markdown; the loop check reads those declarations. The agent and the
orchestrator never need to share Python types. The filesystem is the API.

## 8. Markov state propagation

Every stage transition and every retry attempt receives bounded state: the
current spec/context plus the output of the immediately prior step (or the
prior failed attempt). Nothing further back. This makes context size
constant regardless of how long the system has been running, and it makes
failure modes recoverable — you can always inspect the last failure to
decide the next move.

Concrete instances:

- **Stage transitions.** `interface.md` reads `_generated/identify/output.json`
  and the current spec; it does not read `probe/output.json` directly. Each
  stage's output is the next stage's input.
- **Retry.** When a stage fails, the next attempt sees the spec, the prior
  attempt's `agent.log`, and any partial output it produced. Not the full
  history of every prior attempt.
- **Daemon perception.** The visual state is exactly two frames (current,
  previous) plus a rolling `state_summary.txt`. Older frames are
  summarized into the rolling text and discarded. The visual case is one
  instance of the general pattern.
- **Daemon health.** Each watch tick reads only the most recent log slice,
  not the full server log since boot.

The cost of unbounded state is real: contexts that grow per-iteration blow
up costs, blow up latency, and degrade model attention. The cost of
zero-state is also real: the agent re-discovers the same failure forever.
Markov state — *one step back, no further* — is the cheapest contract that
preserves enough memory for recovery without any of the rot.

This pairs naturally with #7 (RALPH): every loop iteration is *bounded
state in → decision out*. They are the same claim from two angles. RALPH
says "what's the loop?"; Markov says "what does each iteration see?"

---

## Implementation tactics

These are useful patterns we use throughout the codebase. They aren't
principles — replacing them with alternatives wouldn't change what Octopus
*is*, only how it's wired. Listed here so they don't feel orphaned in the
code.

**Self-editing specs on retry.** When a RALPH iteration fails, the agent is
permitted to edit the spec it just ran from before the next attempt. A
specific use of #2 (software self-reference) inside the #7 loop. Lives as a
flag on the orchestrator's retry path.

**Shell out to shell.** Anything that belongs in shell (nohup, cloudflared,
systemctl, lsof, kill, pkill) stays in bash scripts. Python is for
orchestration logic that needs real data structures. "Start this daemon and
write a PID file" is bash; "decide whether to retry the spec" is Python.

---

## Consequences

These principles imply:

- The **product ships the specs** (markdown files). The Python is
  infrastructure.
- **Generating new capabilities** = adding a line to a spec, not writing
  Python.
- **Porting to new hardware** = letting the pipeline run, not writing
  drivers.
- **Model upgrades** = a one-line config change, not a migration.

## Anti-patterns

Things we actively avoid:

- Device registries or manifests (brittle, rot immediately).
- Hardcoded protocol handlers in Python (defeats #1, #3).
- Stuffing condition enumerations into Python where a model call would do
  — regex chains for log parsing, exception cascades for unknown error
  classes, switch statements over device IDs (defeats #5).
- Unbounded state across retries — passing the whole conversation history
  forward instead of just the prior attempt's output (defeats #8).
- "Safe defaults" that work around model weaknesses (mask the real fix:
  stronger spec).
- Logs that grow without bound (break the Markov contract).
- Scripts that assume a specific OS (break #1).
- Treating the daemon and the camera-perception as the same thing
  (break #2).
- Inventing per-stage control flow instead of running RALPH again with a
  different spec (break #7).

## Origin

The repo is mas664-hw4 at MIT MAS.664 ("AI-enabled programming"). The class
asked: what does it mean for an AI to program? Our answer: it programs
*infrastructure*. The coding agent **is** the software. The five protocol
specs describe a universal pipeline; the privileged framework steps handle
the demo-specific hardware; everything else is orchestration around that
central idea.
