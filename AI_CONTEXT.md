# Architecture and Context of the AI_Attestation (OpenClaw) Project

## Project Description

This project is an automated **"Virtual University Defense Commission"** system built on
the **OpenClaw** framework (using the **Gemini Flash Lite** model). The system deploys a
Telegram bot that simulates an examination commission for defending university term papers.
The Orchestrator (main agent) delegates deep document analysis to three specialized
background sub-agents, synthesizes their findings into 3–5 targeted questions, and
then personally conducts the oral Q&A session with the student — all in formal academic
Ukrainian.

## Main Components and Structure

* **`setup-gcp.sh` and `vm-startup.sh`** — Bash scripts for automatic deployment on a
  Google Cloud Platform VM (e2-micro). They prepare the environment (Node.js 24), install
  the `openclaw` CLI globally, configure GCP Secret Manager for secure key storage
  (Gemini API key and Telegram Bot Token), and run `openclaw` as a systemd service.

* **`config/agents/`** — Directory containing AI sub-agent personas. Each folder
  represents a separate agent and must contain:
  * `IDENTITY.md` — Display name, emoji, competencies, and communication style.
  * `SOUL.md` — Personality, analytical tasks, output format, and hard constraints.
  * **Active agents:**
    * `thesis-pedant` — Analyzes methodology, structure, bibliography freshness, and
      alignment between research goals and conclusions. Returns JSON.
    * `thesis-practitioner` — Analyzes empirical data, charts, formulas, and the
      student's personal contribution. Returns JSON.
    * `thesis-visionary` — Stress-tests proposed solutions via hypothetical real-world
      scenarios and ROI questions. Returns JSON.
    * `session-moderator` — Generates the final structured defense protocol at `/end`.

* **`config/workspace/AGENTS.md`** — **The main orchestration file** (written in
  English, following prompt engineering best practices). Defines the 7-step state-machine
  workflow for the main agent acting as the Head of the commission.


## Defense Flow (Single Workflow)

There is **one defense flow**. The bot triggers automatically when a student uploads a
thesis document and indicates readiness. No specific slash command is required.

```
Student uploads thesis PDF/DOCX
         │
         ▼
[STEP 1] Orchestrator greets the student in Ukrainian
         │
         ▼ (spawn → yield → wait)
[STEP 2] @thesis-pedant     → JSON { proposed_questions: [...] }
         │
         ▼ (spawn → yield → wait)
[STEP 3] @thesis-practitioner → JSON { proposed_questions: [...] }
         │
         ▼ (spawn → yield → wait)
[STEP 4] @thesis-visionary  → JSON { proposed_questions: [...] }
         │
         ▼
[STEP 5] Orchestrator synthesizes → selects 3–5 best questions
         │
         ▼
[STEP 6] Oral examination (one question at a time, sequential dialogue)
         │
         ▼
[STEP 7] "Достатньо." → @session-moderator → Final Protocol
```

> [!WARNING]
> **CRITICAL RULE FOR AI (sessions_spawn)**:
> Sub-agents **MUST** be invoked STRICTLY SEQUENTIALLY. The correct pattern is:
> 1. Invoke the agent via `sessions_spawn`.
> 2. Perform `sessions_yield` and wait for the JSON response.
> 3. Only after that, invoke the next agent.
> 4. `taskName` must contain only `[a-z0-9_]` — NO hyphens.

## Adding and Removing Agents

To add a new sub-agent role to the pipeline, 3 steps are required:
1. Create `config/agents/<agent_name>/` with `IDENTITY.md` and `SOUL.md`.
2. Add its invocation logic to `config/workspace/AGENTS.md`.
3. Add the agent name to the `allowAgents` list in `vm-startup.sh`; otherwise, the
   security layer will block its invocation.

## Deployment Features and Multi-user Mode

* By default, the system is configured for a single user via the Pairing system (enter
  the pairing code from the VM console).
* For simultaneous group use, SSH into the VM and switch to `per-peer` mode and open
  `dmPolicy` via `openclaw config set`.
* The `new/` folder is ignored in this context — it is not part of the
  release architecture.
