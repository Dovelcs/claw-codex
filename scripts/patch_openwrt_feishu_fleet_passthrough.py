#!/usr/bin/env python3
"""Patch OpenClaw Feishu group messages to pass through bound fleet chats.

OpenClaw handles Feishu inbound messages before the codex bridge sees them.  For
fleet-bound Feishu groups, the group should behave as a transport only: create or
guide the bound fleet task and then stop OpenClaw's normal agent dispatch.
"""

from __future__ import annotations

import shutil
import subprocess
import time
from pathlib import Path


CONTAINER = "openclaw-gateway-v2"
TARGET_GLOB = "/usr/local/lib/node_modules/openclaw/dist/extensions/feishu/monitor.account-*.js"

HELPER_MARKER = "codex fleet Feishu group passthrough"
HELPER_BLOCK = r'''//#region codex fleet Feishu group passthrough
async function tryCodexFleetFeishuGroupPassthrough(params) {
	const { cfg, accountId, ctx, isGroup, log } = params;
	if (!isGroup) return false;
	const chatId = String(ctx?.chatId ?? "").trim();
	const prompt = String(ctx?.content ?? "").trim();
	if (!chatId || !prompt) return false;
	const baseUrl = String(process.env.CODEX_FLEET_MANAGER_URL ?? process.env.FLEET_MANAGER_URL ?? "http://100.106.225.53:18992").replace(/\/+$/, "");
	const statusUrl = `${baseUrl}/api/chat-bindings?channel=feishu&chat_id=${encodeURIComponent(chatId)}`;
	let binding = null;
	try {
		const statusResp = await fetch(statusUrl, {
			headers: { "accept": "application/json" }
		});
		if (!statusResp.ok) {
			log(`feishu[${accountId}]: fleet passthrough status failed for ${chatId}: HTTP ${statusResp.status}`);
			return false;
		}
		const status = await statusResp.json().catch(() => ({}));
		binding = status?.binding ?? null;
	} catch (err) {
		log(`feishu[${accountId}]: fleet passthrough status error for ${chatId}: ${String(err)}`);
		return false;
	}
	if (!binding) return false;
	try {
		const taskResp = await fetch(`${baseUrl}/api/chat-bindings/task`, {
			method: "POST",
			headers: {
				"accept": "application/json",
				"content-type": "application/json"
			},
			body: JSON.stringify({
				channel: "feishu",
				chat_id: chatId,
				prompt
			})
		});
		const taskText = await taskResp.text();
		let task = {};
		try {
			task = taskText ? JSON.parse(taskText) : {};
		} catch {
			task = {};
		}
		if (!taskResp.ok) {
			log(`feishu[${accountId}]: fleet passthrough task failed for ${chatId}: HTTP ${taskResp.status} ${taskText.slice(0, 300)}`);
			await sendMessageFeishu({
				cfg,
				to: `chat:${chatId}`,
				text: `Codex fleet 透传失败：HTTP ${taskResp.status}`,
				accountId
			}).catch((err) => log(`feishu[${accountId}]: failed to send fleet passthrough error: ${String(err)}`));
			return true;
		}
		log(`feishu[${accountId}]: fleet passthrough routed group ${chatId} to ${binding.project_alias ?? "unknown"} task=${task?.task_id ?? "guidance"} guidance=${Boolean(task?.guidance)}`);
		return true;
	} catch (err) {
		log(`feishu[${accountId}]: fleet passthrough task error for ${chatId}: ${String(err)}`);
		await sendMessageFeishu({
			cfg,
			to: `chat:${chatId}`,
			text: `Codex fleet 透传失败：${String(err)}`,
			accountId
		}).catch((sendErr) => log(`feishu[${accountId}]: failed to send fleet passthrough error: ${String(sendErr)}`));
		return true;
	}
}
//#endregion
'''

CALL_MARKER = "fleet passthrough consumed group message"
CALL_BLOCK = r'''	if (await tryCodexFleetFeishuGroupPassthrough({
		cfg,
		accountId: account.accountId,
		ctx,
		isGroup,
		log
	})) {
		log(`feishu[${account.accountId}]: fleet passthrough consumed group message ${ctx.messageId}`);
		return;
	}
'''


def insert_once(text: str, marker: str, anchor: str, block: str, *, before: bool = True) -> str:
    if marker in text:
        return text
    index = text.find(anchor)
    if index < 0:
        raise RuntimeError(f"anchor not found: {anchor}")
    if before:
        return text[:index] + block + "\n" + text[index:]
    return text[: index + len(anchor)] + "\n" + block + text[index + len(anchor) :]


def patch_file(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    original = text
    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = path.with_name(path.name + f".bak-fleet-passthrough-{stamp}")
    shutil.copy2(path, backup)

    text = insert_once(
        text,
        HELPER_MARKER,
        "function resolveFeishuGroupSession(params) {",
        HELPER_BLOCK,
        before=True,
    )
    text = insert_once(
        text,
        CALL_MARKER,
        "\ttry {\n\t\tconst core = getFeishuRuntime();",
        CALL_BLOCK,
        before=True,
    )

    if text == original:
        print(f"unchanged {path}")
        backup.unlink(missing_ok=True)
        return
    path.write_text(text, encoding="utf-8")
    print(f"patched {path}")
    print(f"backup {backup}")


def main() -> None:
    targets = sorted(Path("/").glob(TARGET_GLOB.lstrip("/")))
    if not targets:
        script = Path(__file__).resolve()
        try:
            subprocess.check_call(["docker", "cp", str(script), f"{CONTAINER}:/tmp/{script.name}"])
            subprocess.check_call(["docker", "exec", CONTAINER, "python3", f"/tmp/{script.name}"])
            subprocess.check_call(
                [
                    "docker",
                    "exec",
                    CONTAINER,
                    "sh",
                    "-lc",
                    f"node --check {TARGET_GLOB}",
                ]
            )
            return
        except (FileNotFoundError, subprocess.CalledProcessError) as exc:
            raise SystemExit(f"no OpenClaw Feishu monitor files matched {TARGET_GLOB}") from exc
    for target in targets:
        patch_file(target)


if __name__ == "__main__":
    main()
