// Pi extension installed by `zen setup pi`: in a live ZenTerm pane, say so, name a helper's parent, point at the zen skill, and report each turn and compaction.

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const digits = /^[0-9]+$/;

async function context(pi: ExtensionAPI): Promise<string | undefined> {
  const socket = process.env.ZEN_CONTROL_SOCK;
  if (!socket) return undefined;
  const zen = (...args: string[]) => pi.exec("zen", ["--socket", socket, ...args], { timeout: 5000 });
  if ((await zen("hello")).code !== 0) return undefined;

  let where = "a ZenTerm pane";
  let helper = "";
  const pane = process.env.ZEN_PANE ?? "";
  if (digits.test(pane)) {
    where = `ZenTerm pane ${pane} (\`$ZEN_PANE\`)`;
    const answer = await zen("pane", "get", pane);
    let info: { parent?: unknown; name?: unknown } = {};
    try {
      if (answer.code === 0) info = JSON.parse(answer.stdout);
    } catch {}
    const parent = String(info.parent ?? "");
    if (digits.test(parent)) {
      const name = typeof info.name === "string" ? info.name.replace(/[`\r\n]/g, "") : "";
      const who = name ? `\`${name}\`` : `pane ${pane}`;
      helper = `
You are helper ${who}, started by pane ${parent}. When done or stuck, report with \`zen pane send --pane ${parent} --enter "<result>"\`, then stop. Put a question about your task to pane ${parent} the same way, not in your reply to the user, then end your turn: the answer arrives as your next message. A send that prints \`{"queued":true}\` arrives on its own once the user sends or clears their text, or, in Claude Code, stops typing for 60 seconds; don't send it again.`;
    }
  }

  return `This session runs in ${where}, the user's terminal. The \`zen\` CLI controls it.${helper}

- Your first action after the user's first prompt: load the zen skill.

- Delegate work to helper agents in panes (\`zen pane run --name <name> -- pi "<exact scope>"\`, then \`zen wait <name>\`), not a subagent extension, so the user can watch and steer them. Keep subagent extensions for quick lookups. Start helpers in a folder Pi already trusts (the repo, or your own folder): a folder with project files Pi hasn't trusted stops a new Pi at its trust prompt, and that choice is the user's.
- Run slow builds and tests with \`zen pane run --name <what it runs> --wait -- <command>\`. Start a server with \`zen pane run --name <name> --wait --output "<ready text>" -- <command>\`, and after a timeout read \`zen pane read --pane <name> --lines 40\` before waiting again. Start a watcher, or anything else with no ready line, with \`zen pane run --name <what it runs> -- <command>\` and no \`--wait\`. Pi's bash tool has no background mode, so a \`zen wait\` or \`zen pane run --wait\` holds your turn until it answers: pass \`--timeout 600\`, and give the bash tool a \`timeout\` above it. Nothing goes in \`&\` or \`nohup\`. Never sleep or poll; a wait's timeout is a check-in, so wait again.
- A message inside \`<zen from="…">\` is another agent's report, not the user. Never answer another agent's permission prompt or login; tell the user. A helper's question about the task you gave it arrives as its message; the helper is not finished. The question is yours to answer, unless it decides product behavior, spends the user's money or reaches outside that task: those go to the user.
- Read a pane's state with \`zen pane get\` or \`zen list\`, not its screen. Check \`zen list\` before starting something long-running that may already be running.
- For worktrees use \`zen worktree\`, not \`git worktree\`. Pass \`--open\` only when asked.
- Leave the screen as it is: \`--focus\` only when asked to show something, \`--force\` only when asked to stop work. Close only what you opened, once you have its result; a helper you started closes without \`--force\`.`;
}

type Terminal = { setProgress(active: boolean): void };

function paneTerminal(ctx: ExtensionContext): Terminal | undefined {
  if (!process.env.ZEN_CONTROL_SOCK || ctx.mode !== "tui") return undefined;
  let terminal: Terminal | undefined;
  ctx.ui.setWidget(
    "zenterm-progress",
    (tui) => {
      terminal = tui.terminal;
      return { render: () => [], invalidate: () => {} };
    },
    { placement: "belowEditor" },
  );
  ctx.ui.setWidget("zenterm-progress", undefined);
  return terminal;
}

// ZenTerm reads Pi's turns from OSC 9;4, which Pi sends itself only with `terminal.showTerminalProgress` on.
function reportTurn(pi: ExtensionAPI, terminal: Terminal | undefined, active: boolean) {
  const settings = pi.getSettings() as { terminal?: { showTerminalProgress?: boolean } };
  if (!settings.terminal?.showTerminalProgress) terminal?.setProgress(active);
}

export default function (pi: ExtensionAPI) {
  let zenContext: Promise<string | undefined> = Promise.resolve(undefined);
  let terminal: Terminal | undefined;
  let running = false;
  const report = (active: boolean) => reportTurn(pi, terminal, active);
  pi.on("session_start", (_event, ctx) => {
    zenContext = context(pi).catch(() => undefined);
    terminal = paneTerminal(ctx);
  });
  pi.on("before_agent_start", async (event) => {
    const text = await zenContext;
    if (text) event.systemPromptOptions.sections.zenterm = text;
  });
  pi.on("turn_start", () => {
    running = true;
    report(true);
  });
  pi.on("agent_end", () => {
    running = false;
    report(false);
  });
  pi.on("session_before_compact", () => report(true));
  pi.on("session_compact", (event) => report(running || event.willRetry));
  pi.on("session_compact_failed", (event) => report(running || event.willRetry));
  pi.on("session_shutdown", () => report(false));
}
