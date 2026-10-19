import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { mkdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Status = "idle" | "busy" | "interrupted" | "error";

interface SessionSnapshot {
	schemaVersion: 1;
	pid: number;
	processStartedAt: number;
	sessionId: string;
	cwd: string;
	name?: string;
	status: Status;
	statusUpdatedAt: number;
	completedAt?: number;
	summary?: string;
}

function plainSummary(text: string): string | undefined {
	const plain = text
		.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, "")
		.replace(/```[^\n]*\n?/g, "")
		.replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
		.replace(/^\s{0,3}(?:#{1,6}\s+|>\s*|[-+*]\s+|\d+\.\s+)/gm, "")
		.replace(/[*_`~]/g, "")
		.replace(/[\x00-\x1f\x7f-\x9f\s]+/g, " ")
		.trim();
	return plain ? (plain.length > 240 ? `${plain.slice(0, 239)}…` : plain) : undefined;
}

/** Publish only explicit interactive lifecycle events; never inspect session transcripts. */
export default function puppy(omp: ExtensionAPI): void {
	const directory = process.env.PUPPY_OMP_SESSIONS_DIR || join(homedir(), ".puppy", "omp-sessions");
	const filename = join(directory, `${process.pid}.json`);
	const processStartedAt = Math.round(Date.now() - process.uptime() * 1000);
	let snapshot: SessionSnapshot | undefined;
	let settlementTimer: NodeJS.Timeout | undefined;

	function cancelSettlement(): void {
		clearTimeout(settlementTimer);
		settlementTimer = undefined;
	}

	function eligible(ctx: ExtensionContext): boolean {
		// Extension factories also run inside in-process subagents, including depth-zero clones.
		return ctx.hasUI && ctx.agent.kind === "main";
	}

	function persist(): void {
		if (!snapshot) return;
		const temporary = `${filename}.${randomUUID()}.tmp`;
		try {
			mkdirSync(directory, { recursive: true, mode: 0o700 });
			writeFileSync(temporary, JSON.stringify(snapshot), { mode: 0o600, flag: "wx" });
			renameSync(temporary, filename);
		} catch {
			// Puppy is optional: an unavailable directory must never interrupt an agent.
		} finally {
			try { unlinkSync(temporary); } catch { /* Renamed already, or never created. */ }
		}
	}

	function update(ctx: ExtensionContext, status: Status, completion?: { at: number; summary?: string }): void {
		snapshot = {
			schemaVersion: 1,
			pid: process.pid,
			processStartedAt,
			sessionId: ctx.sessionManager.getSessionId(),
			cwd: ctx.cwd,
			name: omp.getSessionName(),
			status,
			statusUpdatedAt: Date.now(),
			...(completion ? { completedAt: completion.at, summary: completion.summary } : {}),
		};
		persist();
	}

	function reset(_event: unknown, ctx: ExtensionContext): void {
		if (!eligible(ctx)) return;
		cancelSettlement();
		update(ctx, "idle");
	}

	omp.on("session_start", reset);
	omp.on("session_switch", reset);
	omp.on("session_branch", reset);
	// Navigating within the same session must not retain another branch's completion.
	omp.on("session_tree", reset);

	omp.on("agent_start", (_event, ctx) => {
		if (!eligible(ctx)) return;
		cancelSettlement();
		update(ctx, "busy");
	});

	omp.on("agent_end", (event, ctx) => {
		if (!eligible(ctx)) return;
		cancelSettlement();
		if (event.willContinue || event.awaitingAsyncWork) return;
		// A switch/reset or an already-consumed end cannot complete a different run.
		const run = snapshot;
		if (run?.status !== "busy" || run.sessionId !== ctx.sessionManager.getSessionId()) return;
		const assistant = event.messages.findLast(message => message.role === "assistant");
		let status: Status = "idle";
		let summary: string | undefined;
		const succeeded = assistant?.role === "assistant" && assistant.stopReason === "stop";
		if (assistant?.role === "assistant") {
			if (assistant.stopReason === "aborted") status = "interrupted";
			else if (assistant.stopReason === "error") status = "error";
			else if (succeeded) {
				summary = plainSummary(assistant.content
					.filter(block => block.type === "text")
					.map(block => block.text)
					.join("\n"));
			}
		}
		function settle(): void {
			settlementTimer = undefined;
			if (snapshot !== run || run.sessionId !== ctx.sessionManager.getSessionId()) return;
			// omp emits this callback before its prompt counter unwinds. Waiting inside
			// the callback would block that unwind; publish afterward, unless superseded.
			if (!ctx.isIdle()) {
				settlementTimer = setTimeout(settle, 50);
				settlementTimer.unref();
				return;
			}
			update(ctx, status, succeeded ? { at: Date.now(), summary } : undefined);
		}
		settle();
	});

	omp.on("session_shutdown", (_event, ctx) => {
		if (!eligible(ctx) || !snapshot) return;
		cancelSettlement();
		snapshot = undefined;
		try { unlinkSync(filename); } catch { /* Missing or unwritable: the reader also checks process liveness. */ }
	});
}
