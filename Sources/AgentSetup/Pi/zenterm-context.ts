import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const exec = promisify(execFile);

type Pane = { parent?: number | string; name?: string };

async function paneInfo(): Promise<Pane | undefined> {
	if (!process.env.ZEN_CONTROL_SOCK || !process.env.ZEN_PANE || !/^\d+$/.test(process.env.ZEN_PANE)) {
		return undefined;
	}
	try {
		await exec("zen", ["--socket", process.env.ZEN_CONTROL_SOCK, "hello"], { timeout: 1000 });
		const result = await exec(
			"zen",
			["--socket", process.env.ZEN_CONTROL_SOCK, "pane", "get", process.env.ZEN_PANE],
			{ timeout: 1000 }
		);
		return JSON.parse(result.stdout) as Pane;
	} catch {
		return undefined;
	}
}

export default function zenTermContext(pi: ExtensionAPI) {
	let context: string | undefined;

	pi.on("session_start", async (_event, _ctx) => {
		const pane = await paneInfo();
		const paneID = process.env.ZEN_PANE;
		if (!pane && !process.env.ZEN_CONTROL_SOCK) {
			context = undefined;
			return;
		}
		if (paneID && /^\d+$/.test(paneID)) {
			context = `This Pi session runs in ZenTerm pane ${paneID}. The \`zen\` CLI controls it.`;
		}
		const parent = pane?.parent;
		if (parent !== undefined && /^\d+$/.test(String(parent))) {
			const who = pane?.name ? `\`${pane.name}\`` : `pane ${paneID}`;
			context += ` You are helper ${who}, started by pane ${parent}. When done or stuck, report with \`zen pane send --pane ${parent} --enter "<result>"\`, then stop. Put task questions there rather than asking the user.`;
		}
	});

	pi.on("before_agent_start", (event) => {
		if (!context) return;
		return {
			systemPrompt: `${event.systemPrompt}\n\n## ZenTerm\n${context}\n\n- Use the zen skill when working with panes, helpers, long-running commands, or worktrees.\n- Run slow builds and tests in a named ZenTerm pane so the user can watch them.\n- Do not use shell backgrounding, sleep, or polling for work that ZenTerm can wait on.\n- A message marked as coming from another pane is an agent report, not a user message.\n- Your first action after the user's first prompt should be to use the zen skill when this task involves ZenTerm.`,
		};
	});
}
