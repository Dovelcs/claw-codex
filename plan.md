# Codex Fleet Bridge Repair Plan

## Goal

把“微信 -> 家里 Codex/OpenWrt -> 公司 Codex/VS Code”基础链路修到可验证、可恢复、可监控：

- 公司 VS Code Codex 恢复可用，禁止再直接破坏插件自带 binary 的工作状态。
- 微信切换到公司 Codex 会话后，普通消息能明确透传到公司会话，状态能由家里 Codex 汇总。
- 家里 Codex 能批量监控公司 Codex 活动任务，通过微信做节制汇报。
- 会话/对象切换语义清晰，能区分“给家里 Codex 的管理指令”和“给公司 Codex 的工作指令”。
- 用 OpenWrt 上的模拟微信通道完成冒烟测试。

## Operating Rule

每次改动前先在本文件追加事件、写明动作；执行后补充结果和验证证据。涉及 VS Code 插件、OpenWrt 服务、公司 worker 的动作必须可回滚。

Debug scripts must be fixed direct scripts by default: no command-line parameters unless strictly necessary, and no dynamic resource discovery unless strictly necessary. During debugging, hardcode the target session/file/service being tested so a wrong auto-selected target cannot waste time.

## Events

### 058 Separate Feishu Company Fleet From WeChat Local Codex

Status: completed

Planned actions:

1. Keep Feishu as the only channel allowed to enter company fleet routing.
2. Stop WeChat/OpenClaw-Weixin messages from triggering company session lists, bindings, status, task send, or active fleet forwarding.
3. Leave WeChat normal local OpenWrt Codex execution path untouched by returning no direct fleet answer.
4. Deploy to OpenWrt bridge, restart it, and verify channel-policy behavior directly.

Result:

- Added `scripts/patch_openwrt_channel_policy.py` to patch both OpenWrt bridge copies in place.
- Added a `is_company_fleet_channel(channel)` policy gate before company fleet routing.
- Restricted company fleet direct handling to Feishu channels only.
- WeChat/OpenClaw-Weixin now returns no direct fleet answer for:
  - company session listing;
  - `/绑定`;
  - company task forwarding;
  - active fleet session routing.
- Restarted the OpenWrt OpenClaw bridge server after deployment.

Evidence:

- OpenWrt bridge health returned `{"ok":true,...}` after restart.
- Deployed bridge contains:
  - `def is_company_fleet_channel(channel):`;
  - `if not is_company_fleet_channel(channel): return ''`.
- Direct policy smoke inside the OpenWrt bridge process showed:
  - WeChat `列出公司codex所有会话` -> empty direct fleet answer;
  - WeChat `/绑定 codex-server` -> empty direct fleet answer;
  - WeChat normal company-task text -> empty direct fleet answer;
  - Feishu `/绑定 codex-server` -> normal company project binding response;
  - Feishu unbound task text -> normal Feishu binding guidance.

### 057 Install Boot Autostart For Fleet Bridge Services

Status: completed

Planned actions:

1. Preserve current runtime commands and config files instead of inventing new service arguments.
2. Add company-machine autostart for fleet-agent watchdog and log monitor.
3. Add OpenWrt boot autostart for fleet manager, OpenClaw bridge server, and Feishu session-group provisioner.
4. Keep OpenWrt Docker container restart policy enabled.
5. Install and verify the startup entries without rebooting the machines.

Result:

- Added company-machine autostart helpers:
  - `scripts/start-codex-fleet-log-monitor.sh`;
  - `scripts/install-company-autostart.sh`.
- Installed company-machine user systemd services:
  - `codex-fleet-agent-watchdog.service`;
  - `codex-fleet-log-monitor.service`.
- Added company-machine crontab `@reboot` fallback entries for the same two services.
- Confirmed current company worker watchdog, worker agent, and log monitor are running.
- Added OpenWrt autostart script:
  - `scripts/openwrt-codex-fleet-autostart.sh`.
- Deployed it to OpenWrt as `/root/codex-fleet-autostart.sh`.
- Hooked it into `/etc/rc.local` before `exit 0`.
- OpenWrt autostart now ensures:
  - `dockerd` is enabled/started;
  - `openclaw-gateway-v2` has restart policy `unless-stopped`;
  - fleet manager is started if missing;
  - container bridge server is started if missing;
  - Feishu session-group provisioner is started if missing.

Evidence:

- Local shell syntax check passed for all new startup scripts.
- Company user systemd reports both services `enabled`.
- Company crontab contains the `BEGIN CODEX FLEET AUTOSTART` block.
- Company processes include:
  - `fleet-agent-watchdog.sh`;
  - `dist/cli.js worker agent`;
  - `codex-fleet-log-monitor.sh`.
- OpenWrt `/etc/rc.local` now starts `/root/codex-fleet-autostart.sh`.
- OpenWrt autostart script ran successfully and logged `autostart done`.
- Docker reports `/openclaw-gateway-v2 restart=unless-stopped`.
- Container processes include:
  - `codex_bridge_server.py --listen 127.0.0.1 --port 18991`;
  - `feishu_auto_session_groups.sh`.
- Bridge `/health` reports `ok=true`.
- Fleet manager `/api/endpoints` reports `company-main` online.

### 056 Stream VS Code Manual Session Replies To Feishu

Status: completed

Planned actions:

1. Report mirrored VS Code `codex_reply` events from the company worker as `vscode/assistant`.
2. Keep task-owned rollout events deduped so Feishu-origin tasks do not double-report.
3. Extend OpenWrt session mirror to update one Feishu progress card for `vscode/assistant`.
4. Convert the same card to completed when `vscode/final` arrives.
5. Restart the worker and OpenWrt bridge, then verify event formatting and health.

Result:

- Company worker now reports mirrored VS Code manual-session `codex_reply` rollout events as `vscode/assistant`.
- Task-owned rollout events remain filtered out of the manual session mirror, preserving the existing dedupe behavior for Feishu-origin tasks.
- Added `scripts/patch_openwrt_feishu_session_progress.py`.
- OpenWrt session mirror now:
  - treats `vscode/assistant` as progress;
  - creates or edits one Feishu progress card per session/chat;
  - edits that card to completed when `vscode/final` arrives;
  - keeps VS Code user mirror cards unchanged.
- Rebuilt and restarted the company worker through the watchdog.
- Deployed to OpenWrt and restarted the bridge.

Evidence:

- `npm run typecheck` passed.
- `npm test` passed: 27 Node tests.
- Local `python3 -m py_compile scripts/patch_openwrt_feishu_session_progress.py scripts/patch_openwrt_feishu_progress_edit.py` passed.
- Remote `python3 -m py_compile` passed for both deployed bridge files.
- OpenWrt bridge health reports `ok=true` and `outbound_queue`.
- Fleet manager reports `company-main` online after worker restart.
- Deployed formatter smoke:
  - `vscode/assistant` maps to progress text;
  - progress card title is `Codex 处理中` with blue template.

### 055 Edit Feishu Progress Card For Long Tasks

Status: completed

Planned actions:

1. Confirm Feishu supports message editing through the official edit-message API.
2. Treat `vscode/assistant` and progress-style worker events as task progress.
3. For Feishu-origin tasks, create a compact progress card once progress accumulates.
4. Update the same Feishu message when more progress arrives instead of sending many messages.
5. On completion, edit the progress card to completed state; if no progress card exists, keep the existing final message behavior.
6. Deploy to OpenWrt, restart the bridge, and smoke test send-plus-edit behavior.

Result:

- Confirmed Feishu has an official edit-message API and verified it live with the current app.
- Added `scripts/patch_openwrt_feishu_progress_edit.py`.
- Added Feishu progress card helpers to the OpenWrt bridge:
  - `build_feishu_progress_card`;
  - `send_feishu_card_api`;
  - `update_feishu_message_api`;
  - `feishu_progress_message_id`.
- Task progress watcher now treats `vscode/assistant` as progress, in addition to existing delta/progress-report event types.
- For Feishu-origin tasks:
  - progress is buffered;
  - first visible progress creates one compact progress card;
  - later progress edits the same message at a throttled interval;
  - completion/error/cancel updates that same card when it exists;
  - fast tasks with no progress card keep the old final-message behavior.
- Deployed to OpenWrt and restarted the bridge.

Evidence:

- Local `python3 -m py_compile scripts/patch_openwrt_feishu_progress_edit.py` passed.
- Remote `python3 -m py_compile` passed for both deployed bridge files.
- Bridge health after restart reports `ok=true` and `outbound_queue`.
- Live Feishu progress-card smoke:
  - sent progress card message `om_x100b50144a2a90a4c2aff738bb25030`;
  - updated the same message through the edit API;
  - update returned `rc=0`, `action=update`, and `progressCard=true`.

### 054 Compact VS Code User Mirror Feishu Cards

Status: completed

Planned actions:

1. Keep VS Code assistant/final mirror output unchanged.
2. Detect VS Code user mirror messages before normal Feishu text sending.
3. Extract only the real `My request for Codex` content and drop IDE context/open-tab noise.
4. Send user mirror messages as short Feishu cards with a distinct colored header.
5. Deploy to OpenWrt, restart the bridge, and verify with the user's real long VS Code mirror sample.

Result:

- Added a VS Code user mirror card path in the Feishu sender.
- Messages starting with `VS Code：` now become Feishu interactive cards instead of long plain text.
- The card extracts only the real `## My request for Codex:` content.
- IDE context, active file, open tabs, and image placeholders are dropped from the visible Feishu body.
- User-origin VS Code cards use title `VS Code 用户发言` with `turquoise` header color.
- Assistant/final mirror output is unchanged.
- Deployed to OpenWrt and restarted the bridge.

Evidence:

- Local `python3 -m py_compile scripts/patch_openwrt_feishu_output_format.py` passed.
- Remote `python3 -m py_compile` passed for both deployed bridge files.
- Bridge health after restart reports `ok=true` and `outbound_queue`.
- Regression sample:
  - input started with `VS Code：# Context from my IDE setup...`;
  - extracted request is `继续读取，你这里明显换行没有了`;
  - deployed card title is `VS Code 用户发言`;
  - deployed card template is `turquoise`.

### 053 Split Compact Shell Code Blocks In Feishu Cards

Status: completed

Planned actions:

1. Keep the current Feishu card structure and table rendering unchanged.
2. Add shell-code specific normalization for compact one-line fenced code blocks.
3. Split obvious chained shell commands such as `echo ... pwd` into separate lines.
4. Deploy to OpenWrt, restart the bridge, and verify the regression code block renders as two lines in the card payload.

Result:

- Added shell-code specific compaction repair for Feishu card markdown code fences.
- The repair is limited to shell-like fences such as `bash`, `sh`, `zsh`, `shell`, `console`, and `terminal`.
- Compact command strings such as `echo "hello codex" pwd` now render as:
  - `echo "hello codex"`;
  - `pwd`.
- Deployed to OpenWrt and restarted the bridge.

Evidence:

- Local `python3 -m py_compile scripts/patch_openwrt_feishu_output_format.py` passed.
- Remote `python3 -m py_compile` passed for both deployed bridge files.
- Bridge health after restart reports `ok=true` and `outbound_queue`.
- Deployed card payload suffix now contains:
  - ````bash`;
  - `echo \"hello codex\"`;
  - `pwd`;
  - closing fence.

### 052 Restore Line Breaks In Feishu Card Markdown Blocks

Status: completed

Planned actions:

1. Use the mixed-content `测试` output as the regression sample.
2. Keep the Feishu card `table` component unchanged.
3. Normalize compact one-line markdown blocks before inserting them into card `markdown` elements.
4. Restore line breaks around common labels, code fences, bullets, numbered lists, quotes, and task lists.
5. Deploy to OpenWrt, restart the bridge, and verify the generated card suffix is multiline.

Result:

- Added card-only markdown normalization before content is inserted into Feishu card `markdown` elements.
- Kept the `table` component unchanged.
- Restored line breaks around:
  - compact section labels such as `普通文本：` / `代码：` / `链接：`;
  - fenced code blocks;
  - bullets;
  - numbered lists;
  - quotes;
  - task-list items.
- Deployed to OpenWrt and restarted the bridge.

Evidence:

- Local `python3 -m py_compile scripts/patch_openwrt_feishu_output_format.py` passed.
- Remote `python3 -m py_compile` passed for both deployed bridge files.
- Bridge health after restart reports `ok=true` and `outbound_queue`.
- Deployed card builder now emits multiline markdown body:
  - prefix contains `下面是常见消息类型样例：\n普通文本：...\n表格：`;
  - suffix contains multiline `代码：`, code fence, `链接：`, `列表：`, `编号列表：`, `引用：`, and `任务列表：`.

### 051 Remove Duplicated Feishu Card Prefix Title

Status: completed

Planned actions:

1. Keep the mixed-content `markdown -> table -> markdown` card structure.
2. Stop using the message prefix as the card header when that prefix is also emitted as body content.
3. Use a short generic card title for mixed table messages.
4. Deploy to OpenWrt, restart the bridge, and verify the generated card no longer duplicates the first sentence.

Result:

- Kept the mixed-content card body as `markdown -> table -> markdown`.
- Changed mixed table card title from the message prefix to `Codex 输出`.
- The original prefix remains only in the first markdown body element.
- Deployed to OpenWrt and restarted the bridge.

Evidence:

- Local `python3 -m py_compile scripts/patch_openwrt_feishu_output_format.py` passed.
- Remote `python3 -m py_compile` passed for both deployed bridge files.
- Bridge health after restart reports `ok=true` and `outbound_queue`.
- Deployed card builder now emits:
  - title `Codex 输出`;
  - tags `markdown`, `table`, `markdown`;
  - first markdown body containing the original prefix.

### 050 Preserve Non-Table Content In Feishu Card Messages

Status: completed

Planned actions:

1. Use the latest Feishu `测试` run as the regression sample.
2. Fix Markdown table parsing so table prefix and suffix content are preserved.
3. Build Feishu cards with text/markdown blocks before and after the table component.
4. Keep text fallback behavior unchanged.
5. Deploy to OpenWrt, restart the bridge, and verify with a mixed text/table/code/link sample.

Result:

- Confirmed latest Feishu `测试` output contained mixed content:
  - plain text;
  - Markdown table;
  - code block;
  - inline code;
  - Markdown link.
- Root cause was the first card implementation treating the detected table as the whole message.
- Reworked table parsing to preserve:
  - prefix text before the table;
  - table headers/rows;
  - suffix text after the table.
- Feishu card output now uses `markdown -> table -> markdown` elements for mixed messages.
- Text fallback still converts the same message into readable text if card sending fails.
- Deployed to OpenWrt and restarted the bridge.

Evidence:

- Local `python3 -m py_compile scripts/patch_openwrt_feishu_output_format.py` passed.
- Remote `python3 -m py_compile` passed for both deployed bridge files.
- Bridge health after restart reports `ok=true` and `outbound_queue`.
- Deployed card builder for the regression sample emits element tags:
  - `markdown`;
  - `table`;
  - `markdown`.
- Live Feishu API smoke returned:
  - `rc=0`;
  - `msgType=interactive`;
  - `cardTable=true`;
  - message id `om_x100b502beabc10a8c3833712a49aa42`.

### 049 Send Markdown Tables As Feishu Cards

Status: completed

Planned actions:

1. Preserve the Git rollback point before changing runtime behavior.
2. Add Markdown table parsing that can feed both text fallback and card payloads.
3. Extend the Feishu fast API sender to send an `interactive` card when a Markdown table is detected.
4. Keep text fallback for non-table messages and for card send failures.
5. Deploy to OpenWrt, restart the bridge, and verify the deployed payload builder with the screenshot-style table.

Result:

- Created and pushed Git rollback tag `backup-before-feishu-card-table-20260429-202229`.
- Reworked the Feishu formatter patch so Markdown table parsing feeds both:
  - text fallback formatting;
  - Feishu Card JSON 2.0 `table` payloads.
- Changed Feishu queue/direct sends to pass the original message into `send_feishu_api`.
- `send_feishu_api` now:
  - detects Markdown tables;
  - sends `msg_type=interactive` with a card `table` component;
  - falls back to normal text formatting if card send fails or the message has no table.
- Deployed to OpenWrt and restarted the bridge.

Evidence:

- Local `python3 -m py_compile scripts/patch_openwrt_feishu_output_format.py` passed.
- Remote `python3 -m py_compile` passed for both deployed bridge files.
- Bridge health after restart reports `ok=true` and `outbound_queue`.
- Deployed builder emits a card body whose first element is `tag=table` with `columns` and `rows`.
- Live Feishu API smoke to active Codex group returned:
  - `rc=0`;
  - `msgType=interactive`;
  - `cardTable=true`;
  - message id `om_x100b502bc3f2d910c2b7e4a898ad5c4`.

### 048 Convert Markdown Tables For Feishu Text

Status: completed

Planned actions:

1. Keep Feishu text-message transport, avoiding card payload risk for now.
2. Detect compact Markdown tables in outbound Feishu text.
3. Convert tables into readable field-list text for Feishu.
4. Apply the formatter to both queued dispatcher sends and direct Feishu sends.
5. Deploy, restart, and verify with the exact compact table shape from the screenshot.

Result:

- Kept the current Feishu text-message transport; did not switch to card/table payloads.
- Extended `scripts/patch_openwrt_feishu_output_format.py` with compact Markdown table detection.
- Markdown tables are converted into readable field-list text before sending to Feishu.
- Formatter now runs on both outbound queue dispatcher sends and direct Feishu API sends.
- Preserved numeric text inside table cells such as `1. 2. 3.` instead of treating it as a numbered list.
- Deployed the patch to OpenWrt and restarted the bridge.

Evidence:

- Local `python3 -m py_compile scripts/patch_openwrt_feishu_output_format.py` passed.
- Remote `python3 -m py_compile` passed for both deployed bridge files.
- Bridge health after restart reports `ok=true` and `outbound_queue`.
- Deployed formatter converts the screenshot-style compact Markdown table into:
  - `- Feishu 输出格式`
  - `  状态：已启用`
  - `  说明：出队发送前自动美化文本`
  - and equivalent field blocks for the remaining rows.

### 047 Beautify Feishu Output Formatting

Status: completed

Planned actions:

1. Add a Feishu outbound text formatter at the queue dispatcher layer.
2. Keep raw VS Code/manager events unchanged; only format the text sent to Feishu.
3. Strip markdown-only markers that Feishu text messages render literally.
4. Split compact numbered/bullet lists into readable multiline text.
5. Deploy to OpenWrt, restart the bridge, and smoke test with a compact numbered answer.

Result:

- Added `scripts/patch_openwrt_feishu_output_format.py`.
- Deployed a Feishu outbound formatter at the queue dispatcher layer:
  - strips `**bold**`, `__bold__`, and backticks that Feishu text messages render literally;
  - splits compact numbered lists like `1. ... 2. ... 3. ...` into separate lines;
  - preserves short/plain messages.
- Added `scripts/patch_openwrt_feishu_target_normalize.py` after queue inspection showed invalid retry targets like `default:direct:ou_...:thread:...`.
- Feishu target normalization now extracts `oc_`, `ou_`, and `on_` ids from group/direct/session-thread ids.
- Restarted the OpenWrt bridge inside `openclaw-gateway-v2`.
- Marked old invalid retry rows as `failed` so they stop retrying.

Evidence:

- Local `python3 -m py_compile` passed for both new patch scripts.
- Remote `python3 -m py_compile` passed for both deployed bridge files after patching.
- Remote formatter smoke:
  - input `有几类常见原因： 1. **任务需要读仓库**。 2. **上下文很长**。`;
  - output split into:
    - `有几类常见原因：`
    - `1. 任务需要读仓库。`
    - `2. 上下文很长。`
- Real queue smoke row `format-smoke-20260429-2005` sent successfully with formatted `send_json.message`:
  - `FEISHU_FORMAT_SMOKE 有几类常见原因：`
  - `1. 任务需要读仓库或跑命令 比如查文件。`
  - `2. 上下文很长 当前会话带了很多规则。`
  - `3. 需要严格遵守工具/技能规则 涉及代码。`
- Remote target normalization smoke maps `default:direct:ou_b5312...:thread:om_xxx` to `ou_b5312...`.

### 046 Initialize GitHub Repository Management

Status: completed

Planned actions:

1. Initialize this workspace as a Git repository.
2. Bind `origin` to `git@github.com:Dovelcs/claw-codex.git`.
3. Tighten `.gitignore` so generated outputs, local runtime state, caches, logs, and secrets stay out of Git.
4. Stage source code, scripts, tests, templates, and planning docs.
5. Create the initial commit and push it to GitHub if SSH access allows it.

Result:

- Initialized this workspace as a Git repository.
- Set `origin` to `git@github.com:Dovelcs/claw-codex.git`.
- Updated `.gitignore` to exclude runtime logs, caches, generated outputs, `node_modules`, `dist`, local Codex/OpenClaw state, and environment files while keeping `.env.example`.
- Staged source code, tests, debug scripts, fleet manager code, package files, `.github` instructions, `.vscode/mcp.json`, scripts, and this plan.
- Redacted the real Feishu app id from the historical plan entry before commit.

Evidence:

- `git ls-remote git@github.com:Dovelcs/claw-codex.git HEAD` returned without SSH/auth errors; no refs were advertised, so the repository appears empty or HEAD is not initialized.
- `npm run typecheck && npm test` passed: 27 Node tests.
- `python3 -m unittest fleet_manager/test_codex_fleet_manager.py` passed: 7 tests.
- Staged tree excludes ignored runtime files such as `node_modules/`, `dist/`, `debug/*/`, `log.txt`, `.serena/`, `.taskmaster/`, and `test.txt/`.

### 045 Unified Feishu Message Queue

Status: completed

Planned actions:

1. Inspect the deployed OpenWrt bridge Feishu send paths and identify every direct send point.
2. Add a SQLite-backed `outbound_message_queue` with `event_key` uniqueness and a single dispatcher.
3. Route Feishu task completions and VS Code mirrored session events through the queue instead of direct send.
4. Preserve immediate human-visible latency while making duplicate enqueue attempts no-ops.
5. Deploy, restart, and verify one Feishu task produces one queue row and one outgoing message.

Result:

- Added `scripts/patch_openwrt_outbound_queue.py` to patch the deployed OpenWrt bridge deterministically.
- Deployed a SQLite-backed `outbound_message_queue` on OpenWrt:
  - `event_key` is unique;
  - writers use `insert or ignore`;
  - one dispatcher claims `pending/retry` rows and sends through Feishu API;
  - sent rows keep `send_json`, `attempts`, and `sent_at`.
- Feishu task completion watcher now enqueues final/progress/cancel/error messages instead of directly calling Feishu send.
- VS Code session mirror events now enqueue by `fleet-session:<event_id>:<target>`, so the same manager event cannot be sent twice.
- OpenWrt bridge `/health` now reports `outbound_queue` counts.
- Restarted the OpenWrt bridge inside `openclaw-gateway-v2`.

Evidence:

- Remote `python3 -m py_compile` passed for both deployed bridge files:
  - `/data/state/codex-bridge/package/server/codex_bridge_server.py`;
  - `/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py`.
- Bridge health returns `outbound_queue`.
- Smoke run `20260429-115912-994d552c` submitted Feishu prompt `只输出：FEISHU_QUEUE_ONCE_OK`.
- Company task `task-a9f8fa46675c` completed with `FEISHU_QUEUE_ONCE_OK`.
- Queue row:
  - `event_key=fleet-task:task-a9f8fa46675c:final:a06e16b590d1aceb172d1b05`;
  - `status=sent`;
  - `attempts=1`;
  - `target=oc_18b42b40d85048d71ff9d96e744b841b`.
- Run `channel-send.log` contains exactly one `FEISHU_QUEUE_ONCE_OK` send record.

### 044 Deduplicate Feishu Completion Messages

Status: completed

Planned actions:

1. Inspect the latest duplicate Feishu task events and bridge send logs.
2. Identify whether duplicate comes from multiple completion watchers, session mirror plus task watcher, or old non-Feishu branch detection.
3. Patch the smallest bridge/worker path so Feishu group task completion sends exactly one final message.
4. Restart only the affected service and verify logs/tests.

Result:

- Duplicate root cause was two reporting paths for the same VS Code rollout final:
  - task-owned completion watcher sent the Feishu task result;
  - persistent session mirror then saw the same rollout final and reported it again as an unowned `vscode/final`.
- Patched the company worker to remember recent task-owned `user_input` / `final_answer` rollout events for 120s and suppress identical session-mirror events for the same thread.
- Hardened the OpenWrt bridge completion watcher so Feishu group completions always use the Feishu direct final-message branch instead of the generic `公司 Codex 完成：` prefix branch.
- Restarted the OpenWrt bridge and company worker.

Evidence:

- `npm run typecheck && npm test` passed: 27 Node tests.
- `python3 -m unittest fleet_manager/test_codex_fleet_manager.py` passed: 7 tests.
- Verification task `task-9634fe736766` completed in Feishu group session `019dd900-8103-70a0-9922-c74da508c5b8`.
- Verification final summary: `FEISHU_DEDUP_ONCE_OK`.
- Manager global events for `FEISHU_DEDUP_ONCE_OK` contain only task-owned events `vscode/user`, `vscode/assistant`, `task/final`, and `task/completed`; no unowned mirror `task_id=null` `vscode/final` was emitted.

### 043 Fix New Feishu Group Task Failure

Status: completed

Planned actions:

1. Inspect the newest auto-created Feishu group bindings and the latest failed bridge run.
2. Identify whether failure is caused by missing chat binding, OpenClaw config reload, manager task creation, worker send, or completion watcher.
3. Patch only the failing layer and restart the smallest affected process.
4. Verify with logs/health and keep the 10s auto-provision interval.

Result:

- Root cause was not Feishu group creation or binding.
- The new group was bound to session `019dd8fb-f1dd-7a62-bdcf-5532c11eeea6`, and manager created task `task-f38c19822250`.
- Worker failed before VS Code IPC because `BridgeController.bindThread()` tried to refresh unknown full thread IDs through app-server `thread/list`, hitting missing socket `/run/user/1000/app-server.sock`.
- Patched `BridgeController.bindThread()` so a full thread id binds directly into state and goes straight to the official VS Code IPC send path.
- Restarted the company worker after build/test.

Evidence:

- Failed task before fix: `task-f38c19822250`, error `connect ENOENT /run/user/1000/app-server.sock`.
- `npm run typecheck` passed.
- `npm test` passed: 27 tests.
- `python3 -m unittest fleet_manager/test_codex_fleet_manager.py` passed: 7 tests.
- New worker pid `79082` started after restart.
- Verification task on the same new Feishu group/session completed:
  - task `task-dbf4740b569d`;
  - session `019dd8fb-f1dd-7a62-bdcf-5532c11eeea6`;
  - `turn/sent` event reports `message vscode-ipc start`;
  - final summary `NEW_FEISHU_GROUP_IPC_OK`.

### 042 Reduce Feishu Auto Group Provision Interval

Status: completed

Planned actions:

1. Change the OpenWrt Feishu auto session group provisioning loop from 180s to 10s.
2. Update local helper default interval to match the runtime policy.
3. Restart only the auto-provision loop and verify it is running with the new interval.

Result:

- Local `scripts/feishu_provision_session_groups.py` loop default interval is now 10s with a 10s minimum.
- OpenWrt runtime script `/data/state/codex-bridge/scripts/feishu_auto_session_groups.sh` now defaults to `CODEX_FEISHU_SESSION_GROUP_SYNC_INTERVAL:-10`.
- Restarted only the auto-provision background loop.

Evidence:

- New OpenWrt loop pid `12588` stayed alive across more than one 10s interval.
- OpenWrt script shows `INTERVAL="${CODEX_FEISHU_SESSION_GROUP_SYNC_INTERVAL:-10}"`.
- Local `python3 -m py_compile scripts/feishu_provision_session_groups.py` passed.
- OpenWrt `python3 -m py_compile /data/state/codex-bridge/scripts/feishu_provision_session_groups.py` passed.

### 041 Optimize Feishu Mirror And Auto Provision Session Groups

Status: completed

Planned actions:

1. Remove the high-cost per-bound-session rollout polling from the worker hot path.
2. Replace it with a small active mirror set so VS Code send/switch latency is close to the pre-mirror state.
3. Add a low-frequency auto-provision path for new VS Code sessions to create/bind Feishu groups without polling every historical rollout file.
4. Keep existing Feishu groups in direct-message mode and make future groups default to quiet bridge behavior where the Feishu API allows it.
5. Restart only worker/bridge pieces needed for the change and verify typecheck/tests/health.

Result:

- Throttled worker-side Feishu rollout mirrors:
  - default max hot mirrored sessions: `CODEX_FLEET_MIRROR_MAX_SESSIONS=8`;
  - default mirror poll interval: `CODEX_FLEET_MIRROR_POLL_MS=1000`.
- Restarted the company worker with the new throttles.
- Throttled OpenWrt bridge session-event watcher:
  - default event poll interval is now 2s;
  - chat binding lookup is cached for 20s.
- Started OpenWrt/OpenClaw background auto-provision loop:
  - script: `/data/state/codex-bridge/scripts/feishu_auto_session_groups.sh`;
  - interval: 180s;
  - creates missing Feishu groups for Codex sessions;
  - binds each group to its session;
  - reapplies OpenClaw Feishu group direct mode to existing and newly created groups.
- Existing Feishu Codex groups were reapplied into OpenClaw direct mode with owner allowlist.

Evidence:

- `npm run typecheck` passed.
- `npm test` passed: 27 tests.
- `python3 -m unittest fleet_manager/test_codex_fleet_manager.py` passed: 7 tests.
- `python3 -m py_compile` passed for local Feishu helper scripts.
- OpenWrt `python3 -m py_compile` passed for active bridge and Feishu helper scripts.
- Company worker after throttle: CPU about 0.8%, no persistent rollout JSONL file descriptors observed.
- Fleet manager reports `company-main` online.
- OpenWrt bridge `/health` returned `ok=true`.
- Auto-provision loop is running and increased OpenClaw Feishu group defaults from 90 to 94 groups on its first pass.

### 040 Mirror VS Code Manual Conversation To Feishu

Status: completed

Planned actions:

1. Add a worker-side persistent rollout mirror for Feishu-bound VS Code sessions only.
2. Report mirrored VS Code user/final assistant events to fleet manager without `task_id`, so Feishu-origin task completion watchers do not duplicate them.
3. Add an OpenWrt bridge session-event watcher that forwards those unowned session events to the matching Feishu chat binding.
4. Preserve the existing Feishu -> VS Code IPC task path and the fast final reply path.
5. Run tests, deploy worker/manager/bridge changes, restart only the necessary long-running services, and verify health.

Result:

- Company worker now maintains persistent rollout mirrors for Feishu-bound VS Code sessions only.
- Mirrored manual VS Code events are reported to fleet manager without `task_id`:
  - user messages as `vscode/user`;
  - final assistant answers as `vscode/final`.
- The mirror skips sessions while a Feishu-origin fleet task is active, so the existing fast completion watcher remains the only path for those task replies.
- OpenWrt codex bridge now runs a session-event watcher that reads unowned fleet events and sends them to the bound Feishu chat as normal Feishu messages.
- Existing Feishu -> VS Code IPC send path is unchanged.

Evidence:

- `npm run typecheck` passed.
- `npm test` passed: 27 tests.
- `python3 -m unittest fleet_manager/test_codex_fleet_manager.py` passed: 7 tests.
- OpenWrt bridge `python3 -m py_compile` passed for both source and active package copies.
- OpenWrt active bridge `/health` returned `ok=true` from inside `openclaw-gateway-v2`.
- OpenWrt mirror state file was created at `/data/state/codex-bridge/fleet-feishu-session-mirror.json`.
- Fleet manager reports `company-main` online and Feishu session bindings are present.

### 039 Remove Feishu Fleet Completion Prefix

Status: completed

Planned actions:

1. Keep VS Code IPC and the fast final watcher unchanged.
2. Change Feishu-origin fleet completion output from `公司 Codex 完成：\n<final>` to just `<final>`.
3. Apply the patch to both the active OpenClaw state package and the source package copy on OpenWrt.
4. Restart only the container-side codex bridge and verify compile/health.

Result:

- Updated OpenWrt `codex_bridge_server.py` so any Feishu-origin fleet completion sends only the Codex final text.
- Kept non-Feishu completion messages unchanged, so WeChat/home-Codex status wording can still include the company prefix.
- Patched both:
  - `/opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py`;
  - `/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py`.
- Restarted only the OpenClaw-container bridge.

Evidence:

- Container bridge `/health` returned `ok=true`.
- Active bridge code now branches on `feishu_chat` and calls `send_human(final_summary, run_dir)` for Feishu completions.
- Remote `python3 -m py_compile` passed for both bridge copies.
- `python3 -m unittest fleet_manager/test_codex_fleet_manager.py` passed: 7 tests.
- `npm run typecheck` passed.

### 038 Restore Feishu Normal Send And VS Code Live Update

Status: completed

Planned actions:

1. Confirm whether the last OpenWrt bridge restart moved `codex_bridge_server.py` out of the OpenClaw runtime namespace.
2. Restore bridge startup to the OpenClaw-managed path if namespace or state path drift is found.
3. Fix Feishu group completion output so final messages are normal group messages, not threaded replies.
4. Recheck the company worker path still uses VS Code IPC and that the current Feishu binding targets the VS Code session.
5. Run compile/tests and record the recovery evidence.

Result:

- Confirmed the previous restart placed `codex_bridge_server.py` in the host namespace:
  - host bridge net namespace was `4026531840`;
  - OpenClaw/gateway net namespace is `4026532713`.
- Stopped the host-namespace bridge and restarted the bridge inside the OpenClaw container/runtime namespace:
  - active bridge is again `python3 /data/state/codex-bridge/package/server/codex_bridge_server.py --listen 127.0.0.1 --port 18991`;
  - parent is OpenClaw `tini`, and net/mount namespaces match OpenClaw.
- Fixed Feishu group normalization so `oc_xxx:thread:...` and `group:oc_xxx` are normalized to bare `oc_xxx`; completion push now sends normal group messages instead of preserving reply-thread routing.
- Kept the faster final watcher from Event 037.
- Patched fleet manager event recording to avoid nested heartbeat commits inside `record_worker_events`, reducing SQLite transaction conflicts during worker event bursts.
- Restarted fleet manager with the correct SQLite file path and confirmed `company-main` returned online.

Evidence:

- Container bridge `/health` returns `ok=true` with state `/data/state/codex-bridge`.
- Active bridge namespace matches OpenClaw: net `4026532713`, mount `4026532707`, parent `2560`.
- Current Feishu binding still targets VS Code session `019dd3d6-a736-7aa3-bd8c-d749124c5505`.
- Recent manager event evidence for `task-8b1bbf1e7e57` shows `transport="vscode-ipc"` and rollout events `task/final` / `task/completed`.
- `company-main` endpoint is online with fresh heartbeat after manager restart.
- `npm run typecheck` passed.
- `npm test` passed: 27 tests.
- `python3 -m unittest fleet_manager/test_codex_fleet_manager.py` passed: 7 tests.

### 037 Reduce Feishu Completion Echo Latency

Status: completed

Planned actions:

1. Measure the current Feishu return path around worker rollout detection, manager event/task update, and OpenClaw/bridge push timing.
2. Remove fixed 5 second polling or debounce from the Feishu completion path if it is in our code.
3. Prefer immediate push on `task/final` / `task/completed` while preserving periodic polling as a fallback.
4. Run targeted tests and redeploy the changed service files.

Result:

- Confirmed the 5 second feel came from OpenWrt `codex_bridge_server.py` completion watcher behavior:
  - completion push polling default was `CODEX_FLEET_COMPLETION_PUSH_INTERVAL=3`;
  - the watcher waited for task status polling before using final text.
- Patched the active OpenWrt bridge server to:
  - default completion push interval to `0.5s`;
  - poll manager events first;
  - send Feishu group final output as soon as `task/final` or `task/completed` is visible;
  - keep task-status polling as fallback for cancel/error/older event paths.
- Restarted only the codex-bridge Python server on OpenWrt; OpenClaw gateway and fleet manager were left running.
- Synced the patched server back to `/opt/weixin-bot/openclaw/openclaw-codex-bridge/server/codex_bridge_server.py` so the source package copy matches the active state package.

Evidence:

- Active bridge `/health` returned `ok=true` with state `/opt/weixin-bot/data/openclaw/state/codex-bridge`.
- OpenWrt process list shows:
  - fleet manager still running on `100.106.225.53:18992`;
  - codex bridge restarted as `python3 /opt/weixin-bot/data/openclaw/state/codex-bridge/package/server/codex_bridge_server.py --listen 127.0.0.1 --port 18991`.
- Remote `python3 -m py_compile` passed for both active and source bridge server files.
- `npm run typecheck` passed.
- `npm test` passed: 27 tests.
- `python3 -m unittest fleet_manager/test_codex_fleet_manager.py` passed: 7 tests.

### 036 Feishu Route Uses VS Code IPC Write Plus Rollout Read

Status: completed

Planned actions:

1. Persist each discovered session's rollout JSONL path through worker -> manager -> worker cache.
2. Add a TypeScript rollout watcher for worker task completion and final-answer reporting.
3. Start rollout watching before an IPC send so Feishu-bound tasks can receive Codex final output from the same VS Code session.
4. Delete incorrect `codex exec resume` fallback and app-server write/interrupt fallback paths.
5. Keep app-server/state-db usage only for low-risk session discovery/status reads until a better official source replaces it.
6. Run typecheck, JS tests, and fleet manager tests.

Result:

- Added `src/fleet/rollout-monitor.ts` to tail VS Code rollout JSONL and emit stable task/user/final/completion events.
- Worker send path now:
  - resolves the Feishu-bound VS Code session;
  - starts a rollout watcher for that session;
  - sends via official VS Code IPC `thread-follower-start-turn`;
  - posts `task/final` and `task/completed` back to fleet manager from rollout events.
- Removed the incorrect live-control fallbacks:
  - no `codex exec resume` fallback for VS Code/non-VS Code session routing;
  - no app-server `turn/start`, `turn/steer`, or `turn/interrupt` write API remains in `AppServerClient`;
  - `--allow-resume-fallback` now fails fast.
- Fleet manager now stores and returns `rollout_path` for sessions.
- Deployed updated fleet manager files to OpenWrt `/opt/weixin-bot/codex-fleet`, restarted manager, and restarted the local company worker watchdog/worker.
- Confirmed current Feishu group `oc_7aebc9ba04e7e23b3893c85d5cbf360b` remains bound to session `019dd3d6-a736-7aa3-bd8c-d749124c5505`.

Evidence:

- `npm run typecheck` passed.
- `npm test` passed: 27 tests.
- `python3 -m unittest fleet_manager/test_codex_fleet_manager.py` passed: 7 tests.
- OpenWrt `/healthz` returns `{"ok":true}`.
- OpenWrt `/api/sessions?endpoint=company-main` returns sessions with `rollout_path`.
- Company worker is running as `node dist/cli.js worker agent --manager http://100.106.225.53:18992 --endpoint company-main --label Company Main`.

### 035 IPC Probe Run Diagnosis And Compatibility Fix

Status: completed

Planned actions:

1. Confirm whether the user's latest `测试` was sent through the new IPC follower path or the old stdio app-server path.
2. If the old stdio path was used, record that it is expected not to live-refresh VS Code UI.
3. Make the fixed Python IPC probe mirror the TypeScript IPC client response shapes for discovery and unhandled requests.
4. Verify the Python script compiles without sending a real prompt during this active assistant turn.

Result:

- The latest generated probe output is `debug/stdio-turn-probe/summary.json` at `2026-04-29 16:59:35 +0800`.
- That output proves the message was sent by the old independent stdio app-server path:
  - method sequence: `initialize`, `thread/resume`, `turn/start`;
  - turn id: `019dd876-f2cd-71d1-99b5-3019f37e7a32`;
  - final text: `收到。`.
- No `debug/ipc-follower-probe/` directory exists, so the new IPC follower probe did not run to its output phase.
- Updated `debug/codex_ipc_follower_probe.py` so `client-discovery-response` and unhandled `request` responses match the TypeScript IPC client shape.

Evidence:

- `python3 -m py_compile debug/codex_ipc_follower_probe.py` passed.
- Read-only initialization against the live VS Code IPC socket still succeeds and returned client id `b17e1654-761b-40e3-ba64-44ddee58fb5d`.

### 034 Official VS Code IPC Stop Path Integration

Status: completed

Planned actions:

1. Route `/stop` for a bound VS Code session through official IPC `thread-follower-interrupt-turn`.
2. Preserve the old app-server `turn/interrupt` only as an explicit fallback, controlled by `CODEX_BRIDGE_VSCODE_IPC_FALLBACK_TO_APPSERVER=1`.
3. Extend the fake IPC test to verify the interrupt request shape.

Result:

- `BridgeController.stopActiveThread()` now uses `thread-follower-interrupt-turn` through the official VS Code IPC client first.
- The app-server `turn/interrupt` path remains only as explicit fallback when `CODEX_BRIDGE_VSCODE_IPC_FALLBACK_TO_APPSERVER=1`.
- CLI/worker output includes the transport used for stop operations.
- `src/vscode-ipc/client.test.ts` now verifies both `thread-follower-start-turn` and `thread-follower-interrupt-turn`.

Evidence:

- `npm run typecheck` passed.
- `npm test` passed: 27 tests.
- Read-only initialization against the live VS Code IPC socket still succeeds after rebuilding; latest probe returned client id `4949dda4-8694-43ce-bfbe-bbbfba29a02c`.

### 033 Official VS Code IPC Send Path Integration

Status: completed

Planned actions:

1. Add a TypeScript client for the official VS Code extension IPC socket `/tmp/codex-ipc/ipc-<uid>.sock`.
2. Use the same 4-byte little-endian length-prefixed JSON framing confirmed by `debug/codex_ipc_follower_probe.py`.
3. Route VS Code-session sends through `thread-follower-start-turn` so the owning VS Code window/app-server performs the turn and broadcasts UI updates.
4. Keep the old managed app-server client for listing/status/stop and for explicit fallback paths only.
5. Add a local fake IPC-router test so the bridge behavior is verified without sending a real prompt into the active VS Code session.

Result:

- Added `src/vscode-ipc/client.ts`.
- Default VS Code-session sends now prefer the official VS Code IPC socket instead of writing through a separate app-server:
  - IPC socket path defaults to `/tmp/codex-ipc/ipc-<uid>.sock`.
  - Framing is 4-byte little-endian length-prefixed JSON.
  - The client initializes with `clientType=vscode`.
  - The send path uses `thread-follower-start-turn`.
- `BridgeController.sendToActiveThread()` now uses the VS Code IPC path first. The old app-server write path is only used when IPC is disabled or when `CODEX_BRIDGE_VSCODE_IPC_FALLBACK_TO_APPSERVER=1` is explicitly set.
- Output now records `transport=vscode-ipc` or `transport=app-server` for sent messages.
- Added `src/vscode-ipc/client.test.ts` with a fake length-prefixed IPC router.

Evidence:

- `npm run typecheck` passed.
- `npm run build` passed.
- `npm test` passed: 27 tests.
- Read-only initialization against the live VS Code IPC socket succeeded and returned client id `cf9d5f82-de41-4719-a0d6-6a5d20c2c428`.
- The real active VS Code thread was not sent a probe message during this assistant turn to avoid racing the current in-progress conversation.

### 032 Official VS Code Multi-Window Sync Reassessment

Status: in progress

Planned actions:

1. Treat the user's observed official multi-window live sync as authoritative evidence that a VS Code UI refresh path exists.
2. Stop describing relay as the only possible route.
3. Identify which official route the external stdio app-server probe bypasses:
   - app-server loaded-thread ownership;
   - workspace-owner or parent-thread notification;
   - webview query-cache invalidation;
   - live notification forwarding into the app-server manager.
4. Keep the current VS Code plugin startup chain untouched.

Progress:

- Confirmed the bundled app-server binary contains loaded-thread, filesystem-watch, rollout, and notification paths, including `thread/loaded/list`, `thread/inject_items`, `fs/watch`, `failed to notify parent thread`, and `failed to notify workspace owner`.
- Confirmed the webview/app-server manager consumes `turn/started`, `item/*`, `item/agentMessage/delta`, and `turn/completed` notifications and updates in-memory conversation snapshots.
- Confirmed webview code has `query-cache-invalidate` broadcast handling, but the exact conversation query key/refresh trigger for this case is not yet pinned down.
- Current hypothesis: the stdio probe successfully writes a turn through a separate app-server, but bypasses the VS Code-owned loaded-thread/owner notification path, so already-open webviews keep stale in-memory state.
- Confirmed official multi-window IPC uses `/tmp/codex-ipc/ipc-1000.sock` with 4-byte little-endian length-prefixed JSON.
- Confirmed IPC router accepts `initialize` from an external client and returns a `clientId`.
- Confirmed official IPC methods include `thread-stream-state-changed` broadcasts and follower-to-owner requests like `thread-follower-start-turn`.

Next actions:

- Find the exact official message path used when one VS Code window writes and another window refreshes live.
- Reproduce only that refresh/invalidation path after an external turn, without changing `chatgpt.cliExecutable` or wrapping the extension binary.

Planned implementation update:

1. Add a fixed no-argument `debug/codex_ipc_follower_probe.py`.
2. Connect to `/tmp/codex-ipc/ipc-1000.sock` with the official 4-byte little-endian length-prefixed JSON framing.
3. Register as an IPC client via `initialize`.
4. Send `thread-follower-start-turn` for fixed conversation `019dd3d6-a736-7aa3-bd8c-d749124c5505` and prompt `测试`.
5. Save all IPC messages, responses, broadcasts, and summary under `debug/ipc-follower-probe/`.
6. Do not start another app-server and do not modify VS Code settings or extension files.

Result:

- Added `debug/codex_ipc_follower_probe.py`.
- `python3 -m py_compile debug/codex_ipc_follower_probe.py` passed.
- A read-only initialize probe against `/tmp/codex-ipc/ipc-1000.sock` succeeded and returned an IPC `clientId`.
- The full `thread-follower-start-turn` send was not executed during this active assistant turn to avoid racing the current VS Code conversation.

### 031 Harden Stdio App-Server Turn Probe

Status: completed

Planned actions:

1. Keep `debug/codex_stdio_turn_probe.py` fixed-target and no-argument so the user can run it directly.
2. Treat the script as a second VS Code window model, not a short protocol-only probe.
3. Require the target thread to be idle before `turn/start`.
4. Wait for the exact returned turn id to reach `turn/completed` or `turn/aborted`.
5. On timeout, request `turn/interrupt` for the exact turn id before shutting down the probe app-server.
6. Save enough structured output for the user to compare VS Code visibility after running it.

Result:

Completed.

Evidence:

- Updated `debug/codex_stdio_turn_probe.py`.
- It still has no command-line parameters and still uses fixed:
  - thread: `019dd3d6-a736-7aa3-bd8c-d749124c5505`
  - prompt: `测试`
- It now refuses to send if `thread/resume` reports the target thread is not `idle`.
- It waits up to 15 minutes for the exact returned turn id.
- It filters notifications by both thread id and turn id, avoiding unrelated app-server events.
- It records `completed`, `aborted`, `terminalMethod`, `timeout`, and any `interrupt` result in `debug/stdio-turn-probe/summary.json`.
- On timeout, it calls `turn/interrupt` for the exact turn id before stopping the spawned app-server.
- Verification: `python3 -m py_compile debug/codex_stdio_turn_probe.py` passed. The send path was not executed; the user will run it manually.

### 030 Stop Extra Codex Background Processes

Status: completed

Planned actions:

1. Inspect current user processes related to Codex, VS Code Codex, bridge worker, rollout probes, and debug app-server probes.
2. Stop bridge/watchdog processes that can keep polling or scanning Codex state.
3. Stop extra non-VS Code Codex CLI process if it is separate from the current VS Code app-server.
4. Leave the official VS Code Codex app-server running so the current VS Code session is not disconnected.

Result:

Completed.

Evidence:

- Stopped `scripts/fleet-agent-watchdog.sh`.
- Stopped `node dist/cli.js worker agent --manager http://100.106.225.53:18992 --endpoint company-main --label Company Main`.
- Stopped the extra interactive Codex CLI process group that was attached to `pts/2`.
- Confirmed no `codex_rollout_spider.py`, `appserver_probe.py`, `codex_stdio_turn_probe.py`, `fleet-agent-watchdog.sh`, or `dist/cli.js worker agent` process remains.
- Remaining Codex process is the VS Code plugin-owned app-server:
  - `/home/donovan/.vscode-server/extensions/openai.chatgpt-26.422.71525-linux-x64/bin/linux-x86_64/codex app-server --analytics-default-enabled`

### 029 Stdio Probe VS Code Visibility Check

Status: completed

Planned actions:

1. Verify whether the `测试` turn from event 028 is visible as a normal VS Code-restorable turn.
2. Check the fixed rollout JSONL, `state_5.sqlite`, and probe output files.
3. Distinguish protocol success from UI-visible session insertion.

Result:

Completed.

Evidence:

- The fixed rollout file does contain the probe turn context and user message:
  - turn id: `019dd84c-8c70-73d1-8405-ba824f9a3095`
  - rollout lines include `turn_context`, user `response_item`, and `event_msg` for `测试`.
- The same rollout does not contain a terminal `task_complete` or `turn_aborted` for that turn id.
- `debug/stdio-turn-probe/summary.json` recorded `"completed": false`.
- `debug/stdio-turn-probe/notifications.jsonl` shows the independent app-server stream later switched activity to another thread id: `019dd84c-e7a6-7833-bef1-808bbfc8de81`.

Conclusion:

The stdio probe proved the JSONL app-server protocol and did write some rollout items, but it did not produce a clean VS Code UI-restorable turn. The user observation that re-entering the VS Code session does not show the `测试` message is consistent with the evidence. This route is protocol proof only; the write path must target the running VS Code-owned app-server channel or use a relay in front of that channel.

### 028 Stdio App-Server Client Probe

Status: completed

Planned actions:

1. Add a fixed no-argument Python probe that starts the bundled Codex `app-server` over stdio like the VS Code extension does.
2. Speak the app-server JSON-RPC protocol directly over stdio.
3. Use the fixed VS Code thread `019dd3d6-a736-7aa3-bd8c-d749124c5505`.
4. Send one `turn/start` message with content `测试`.
5. Save responses and notifications to a local debug output directory for inspection.
6. Do not modify VS Code settings, wrapper, SQLite, rollout files, or the running VS Code app-server.

Result:

Completed.

Evidence:

- Added `debug/codex_stdio_turn_probe.py`.
- The first attempt proved stdio framing is not `Content-Length`; app-server logged `Failed to deserialize JSONRPCMessage` when it received `Content-Length:`.
- Updated the probe to use app-server stdio JSONL framing: one JSON object per line.
- Verification:
  - `python3 -m py_compile debug/codex_stdio_turn_probe.py` passed.
  - `python3 debug/codex_stdio_turn_probe.py` successfully returned `initialize`, `thread/resume`, and `turn/start`.
  - Fixed target thread: `019dd3d6-a736-7aa3-bd8c-d749124c5505`.
  - Sent prompt: `测试`.
  - New turn id returned by app-server: `019dd84c-8c70-73d1-8405-ba824f9a3095`.
  - Captured app-server notifications include `thread/status/changed`, `turn/started`, `item/started` and `item/completed` for the user message `测试`, token usage updates, and `item/agentMessage/delta`.
- Output files:
  - `debug/stdio-turn-probe/sent.jsonl`
  - `debug/stdio-turn-probe/responses.jsonl`
  - `debug/stdio-turn-probe/notifications.jsonl`
  - `debug/stdio-turn-probe/messages.jsonl`
  - `debug/stdio-turn-probe/summary.json`
  - `debug/stdio-turn-probe/stderr.log`
- This event did not modify VS Code settings, wrapper, SQLite, or rollout files directly. It spawned a separate local app-server stdio process for protocol proof.

### 027 Human-Readable Rollout Spider Output

Status: completed

Planned actions:

1. Keep `debug/codex_rollout_spider.py` no-argument and fixed-target.
2. Preserve `debug/vscode-capture.jsonl` as the machine-readable bridge feed.
3. Add cleaned human-readable output to a fixed text file.
4. Strip IDE context wrappers and reduce noisy metadata for human review.
5. Verify compile and a short fixed-session run.

Result:

Completed.

Evidence:

- `debug/codex_rollout_spider.py` remains no-argument and fixed to thread `019dd3d6-a736-7aa3-bd8c-d749124c5505`.
- Machine feed is preserved in `debug/vscode-capture.jsonl`.
- Human-readable feed is written to `debug/vscode-capture.txt`.
- Stdout now prints the human-readable format by default.
- User messages are cleaned by stripping IDE context wrappers such as `# Context from my IDE setup`, active file/open tabs blocks, and `## My request for Codex:`.
- Human output uses readable labels: `CAPTURE START`, `SESSION`, `TASK START`, `USER`, `CODEX`, `FINAL`, and `TASK COMPLETE`.
- Verification:
  - `python3 -m py_compile debug/codex_rollout_spider.py` passed.
  - `timeout 1.5s python3 debug/codex_rollout_spider.py | head -n 20` emitted human-readable output.
  - `debug/vscode-capture.jsonl` continued receiving schema-v1 JSONL records.

### 026 Rollout Spider Stable Event Stream

Status: completed

Planned actions:

1. Keep `debug/codex_rollout_spider.py` fixed target and no-argument startup.
2. Keep VS Code startup untouched; do not use wrapper or independent app-server.
3. Add stable event kinds for user input, Codex replies, task started, task complete, and final answer.
4. Deduplicate rollout records that appear both as `event_msg` and `response_item`.
5. Verify the script still compiles, rejects arguments, and captures the fixed session.

Result:

Completed.

Evidence:

- `debug/codex_rollout_spider.py` still has fixed `THREAD_ID`, fixed `ROLLOUT_PATH`, and no command-line parameters.
- Output now includes `schema=codex_rollout_spider.v1`.
- Stable event kinds are now:
  - `user_input`
  - `codex_reply`
  - `final_answer`
  - `task_started`
  - `task_complete`
  - plus `session`, `capture_started`, `capture_stopped`, `decode_error`, and `raw`.
- Added an in-process dedupe cache so paired `event_msg` / `response_item` rollout records do not produce duplicate bridge-visible events.
- Verification:
  - `python3 -m py_compile debug/codex_rollout_spider.py` passed.
  - `python3 debug/codex_rollout_spider.py --bad-arg` rejects parameters with `do not pass arguments; run: python3 codex_rollout_spider.py`.
  - `timeout 1.5s python3 debug/codex_rollout_spider.py` starts against the fixed thread and emits schema-v1 `capture_started`.
  - A fixed-rollout replay produced event kinds `user_input`, `codex_reply`, `final_answer`, `task_started`, and `task_complete`, including the user's earlier `测试` turn.

### 025 VS Code Rollout Spider Capture

Status: completed

Planned actions:

1. Abandon the independent app-server path as the default route.
2. Keep VS Code Codex on the official plugin launch path with no `chatgpt.cliExecutable`.
3. Add a crawler-style observer that tails VS Code Codex rollout JSONL files under `~/.codex/sessions`.
4. Normalize persisted user and assistant messages into a small JSONL stream usable by the bridge/manager.
5. Verify with the real `设计 codex-bridge 消息链路` session.

Result:

Completed.

Evidence:

- Added `debug/codex_rollout_spider.py`.
- The spider is fixed to thread `019dd3d6-a736-7aa3-bd8c-d749124c5505` and its known rollout JSONL path; it does not dynamically choose the latest session.
- It emits normalized `message`, `status`, and `session` JSONL records from the rollout file without touching app-server.
- `CODEX_BRIDGE_AUTO_START_APPSERVER` now defaults off.
- Verified `chatgpt.cliExecutable` is absent from VS Code Remote settings.
- Stopped the separate `--listen unix:///run/user/1000/app-server.sock` app-server; only the official VS Code app-server remains.
- Verification:
  - `python3 -m py_compile debug/codex_rollout_spider.py` passed.
  - `python3 debug/codex_rollout_spider.py --thread 019dd3d6-a736-7aa3-bd8c-d749124c5505 --from-start --listen-seconds 0 | head -n 5` emitted persisted VS Code user messages.
  - `npm test` passed, 26 tests.

### 024 Switch To Independent Managed App-Server

Status: completed

Planned actions:

1. Stop using the VS Code `chatgpt.cliExecutable` wrapper as the normal bridge path.
2. Keep the official VS Code Codex plugin launch path untouched.
3. Make the bridge auto-start an independent official `codex app-server` on the configured Unix socket.
4. Reuse the existing WebSocket-over-Unix JSON-RPC client for `thread/list`, `thread/resume`, `turn/start`, `turn/steer`, and `turn/interrupt`.
5. Verify with real `vscode list`, `vscode use`, and `vscode status`.

Result:

Completed.

Evidence:

- Added managed app-server startup in `src/appserver/managed-server.ts`.
- `AppServerClient` now defaults to auto-starting an official app-server for Unix socket endpoints when the socket is missing or stale.
- `README.md` now documents the independent app-server route and marks the old wrapper route as debugging-only.
- Verification:
  - `npm run typecheck` passed.
  - `npm test` passed, 26 tests.
  - `npm run bridge -- vscode list 5` returned VS Code sessions, including `设计 codex-bridge 消息链路`.
  - `npm run bridge -- vscode use 019dd3d6-a736 && npm run bridge -- vscode status` bound `019dd3d6-a736-7aa3-bd8c-d749124c5505` and returned `idle`.

### 022 VS Code stdio App-Server Relay

Status: completed

Planned actions:

1. Replace the broken `--listen` plus `app-server proxy --sock` wrapper path with a stdio relay.
2. Keep the official VS Code Codex extension's stdin/stdout protocol intact.
3. Expose a Unix WebSocket socket for the fleet worker to send JSON-RPC requests into the same app-server process.
4. Multiplex JSON-RPC ids so VS Code and remote clients do not collide.
5. Verify wrapper syntax and, if possible, run a local relay smoke without changing VS Code settings.

Result:

Completed.

Evidence:

- Replaced `bin/codex-vscode-wrapper.mjs` with a stdio relay implementation.
- The relay preserves VS Code stdin/stdout JSONL app-server traffic and exposes a Unix WebSocket socket for fleet/bridge clients.
- Remote JSON-RPC requests are id-remapped as `bridge:<client>:<seq>` and responses are mapped back to the remote caller.
- App-server notifications are forwarded to VS Code and broadcast to connected remote clients.
- Remote `initialize` is answered locally so the real app-server still has a single primary VS Code initialize handshake.
- Verification:
  - `node --check bin/codex-vscode-wrapper.mjs` passed.
  - `npm test` passed, 24 tests.
  - Temporary relay smoke passed: simulated VS Code initialized stdio, WebSocket client connected to `/tmp/codex-stdio-relay-smoke.sock`, and `thread/list` returned 3 VS Code threads including `019dd3d6-a736-7aa3-bd8c-d749124c5505`.
- No VS Code settings were changed during this event.

### 023 Enable Relay On Next VS Code Codex Launch

Status: completed

Planned actions:

1. Back up VS Code Remote Machine settings.
2. Set `chatgpt.cliExecutable` to the tested wrapper path.
3. Do not kill or restart the current official Codex app-server process in this event.
4. Verify the settings file contains only the intended Codex wrapper setting.
5. Leave activation to the next VS Code window reload or Codex panel restart.

Result:

Completed.

Evidence:

- Backed up VS Code Remote Machine settings to `/home/donovan/.vscode-server/data/Machine/settings.json.bak-codex-stdio-relay-20260429151555`.
- Set `chatgpt.cliExecutable=/home/donovan/samba/codex-server/bin/codex-vscode-wrapper.mjs`.
- Verified the Codex-related settings contain only that wrapper path.
- Did not kill or restart the current official Codex app-server process; active process is still the bundled OpenAI binary.
- Relay activation is pending a VS Code window reload or Codex panel restart.

### 021 App-Server Remote Control Hardening

Status: completed

Planned actions:

1. Make the fleet worker accept an explicit app-server socket or URL for remote-control mode.
2. Make VS Code-owned sessions require app-server by default so Feishu/OpenClaw does not report false live-control success through `codex exec resume`.
3. Keep history fallback available only when explicitly enabled for non-live recovery.
4. Add build/test coverage for the new routing switches.
5. Do not change VS Code settings or restart VS Code app-server in this event.

Result:

Completed.

Evidence:

- `worker agent` now accepts explicit live app-server endpoints through `--app-server-sock`, `--app-server-url`, `CODEX_BRIDGE_APP_SERVER_SOCK`, or `CODEX_BRIDGE_APP_SERVER_URL`.
- VS Code sessions now require app-server live control by default in fleet worker mode; if app-server is unavailable, the task fails instead of silently using `codex exec resume`.
- History fallback is still available only when explicitly requested with `--allow-resume-fallback` or `CODEX_FLEET_ALLOW_RESUME_FALLBACK=1`.
- Explicit socket options are pinned as `unix://...` and do not get overridden by ambient `CODEX_BRIDGE_APP_SERVER_URL`.
- Verification: `npm test` passed, 24 tests.
- Deployed locally by rebuilding `dist/` and restarting only the fleet worker through the existing watchdog; current worker pid `42766`.
- Manager endpoint check shows `company-main` online after restart.

### 020 Python app-server Debug Probe

Status: completed

Planned actions:

1. Create a local `debug/` folder for app-server protocol experiments.
2. Implement a dependency-free Python client that consumes app-server JSON-RPC responses and notifications.
3. Start a temporary `codex app-server --listen unix://...` socket locally.
4. Verify read-only protocol calls with `initialize` and `thread/list`.
5. Verify server-published turn events by sending a minimal probe prompt to the existing VS Code thread.

Result:

Completed.

Evidence:

- Added `debug/appserver_probe.py` and `debug/README.md`.
- The first raw-frame attempt showed the current app-server expects WebSocket HTTP Upgrade on the unix socket, so the Python client now implements the upgrade handshake.
- Read-only probe succeeded:
  - `initialize` returned `codex_vscode/0.126.0-alpha.8`
  - `thread/list` returned the target thread `019dd3d6-a736-7aa3-bd8c-d749124c5505` as the first VS Code thread.
- Turn/event probe succeeded:
  - `thread/resume` returned the thread with status `idle`
  - `turn/start` created turn `019dd7f3-e32b-7503-a880-edb4b64ec0f5`
  - Python consumed notifications including `thread/status/changed`, `turn/started`, `item/started`, `item/agentMessage/delta`, `item/completed`, and `turn/completed`
  - streamed deltas assembled to `APP_SERVER_DEBUG_OK`

### 019 Idempotent Resume Metadata Recheck

Status: in_progress

Planned actions:

1. Re-check thread `019dd3d6-a736-7aa3-bd8c-d749124c5505` in `state_5.sqlite`, `session_index.jsonl`, and rollout storage.
2. Create fresh backups before touching `~/.codex`.
3. Idempotently set `threads.has_user_event=1`.
4. Add a `session_index.jsonl` entry only if the index is missing.
5. Restart Codex app-server processes and verify CLI resume/app-server visibility.

Progress:

- Re-check before edits:
  - `threads.has_user_event=1`
  - `session_index.jsonl` already contains this thread
  - rollout JSONL exists and is readable
  - VS Code remote settings does not contain `chatgpt.cliExecutable`

### 017 Roll Back VS Code Wrapper To Restore Plugin

Status: completed

Planned actions:

1. Check whether the broken session is missing from `session_index.jsonl`, `state_5.sqlite`, or rollout storage.
2. Check whether VS Code Codex app-server is currently running.
3. If app-server is absent and SSH MCP recovery is unavailable, roll back the `chatgpt.cliExecutable` setting to restore the official extension launch path.
4. Ask for a VS Code reload/open-panel action after rollback, then verify the session can be reopened.

Progress:

- Session `019dd3d6-a736-7aa3-bd8c-d749124c5505` exists in:
  - `~/.codex/session_index.jsonl`
  - `~/.codex/state_5.sqlite`
  - `~/.codex/sessions/2026/04/28/rollout-2026-04-28T19-25-53-019dd3d6-a736-7aa3-bd8c-d749124c5505.jsonl`
- No `codex app-server` process is running.
- `/run/user/1000/app-server.sock` is absent.
- Starting app-server from the local sandbox is blocked by `Operation not permitted`.
- Company SSH MCP restore attempt was cancelled, so manual socket recovery through SSH is unavailable in this turn.
- 2026-04-29 14:09 restored VS Code Remote Machine settings to the official Codex extension path by removing `chatgpt.cliExecutable`.
- Settings backup: `/home/donovan/.vscode-server/data/Machine/settings.json.bak-restore-official-20260429140943`.
- Stopped the three stale `openai.chatgpt` Codex app-server processes so the next VS Code Codex panel/reload starts from the restored official path.
- Verified `~/.vscode-server/data/Machine/settings.json` now keeps only proxy and Git-scan settings; `chatgpt.cliExecutable` is absent.
- Verified `codex exec --skip-git-repo-check -m gpt-5.5` through `127.0.0.1:7890` returned `CODEX_SMOKE_OK`.
- Verified `~/.codex/state_5.sqlite` integrity check returned `ok`; the smoke thread exists in `threads`.

Result:

Official VS Code Codex launch path restored. A VS Code window reload or reopening the Codex panel is still required to spawn a fresh app-server.

### 018 Repair VS Code Session Metadata For Codex Bridge Thread

Status: completed

Planned actions:

1. Re-check session `019dd3d6-a736-7aa3-bd8c-d749124c5505` across `session_index.jsonl`, `state_5.sqlite`, and rollout JSONL.
2. Prove whether CLI resume can open the thread independently of VS Code.
3. Repair only the inconsistent metadata for this thread.
4. Restart stale VS Code Codex app-server processes so the extension reloads state.

Progress:

- Session exists in `~/.codex/session_index.jsonl`, `~/.codex/state_5.sqlite`, and rollout storage.
- Rollout file `/home/donovan/.codex/sessions/2026/04/28/rollout-2026-04-28T19-25-53-019dd3d6-a736-7aa3-bd8c-d749124c5505.jsonl` parses cleanly with no JSON errors in the checked pass.
- `codex resume --all --include-non-interactive 019dd3d6-a736-7aa3-bd8c-d749124c5505` opened the thread and returned `RESUME_PROBE_OK`.
- Root inconsistency found: SQLite row had `has_user_event=0` even though the rollout contains user messages and the thread can resume.
- Backups created:
  - `/home/donovan/.codex/state_5.sqlite.bak-restore-019dd3d6-a736-7aa3-bd8c-d749124c5505-20260429141704`
  - `/home/donovan/.codex/session_index.jsonl.bak-restore-019dd3d6-a736-7aa3-bd8c-d749124c5505-20260429141704`
- Updated `threads.has_user_event` to `1` for this thread.
- Appended a fresh `session_index.jsonl` entry with `updated_at=2026-04-29T06:17:04Z`.
- Restarted the stale VS Code Codex app-server processes.
- Post-repair `pragma integrity_check` returned `ok`.

Result:

Thread metadata is repaired. VS Code still needs to reopen the Codex panel or reload the window to start a fresh app-server against the repaired state.

### 016 Restore VS Code Live App-Server Socket

Status: blocked_waiting_for_vscode_reload

Planned actions:

1. Confirm the user's latest Feishu `测试` task reached the right Codex session but used history fallback.
2. Confirm the worker error is `connect ENOENT /run/user/1000/app-server.sock`.
3. Back up VS Code remote settings before changing `chatgpt.cliExecutable`.
4. Point VS Code Codex extension to `bin/codex-vscode-wrapper.mjs` so future app-server launches expose the shared socket.
5. Restart only Codex app-server processes if needed, then verify `/run/user/1000/app-server.sock` exists and `node dist/cli.js vscode list` can connect.
6. Re-run a fleet task and verify the worker uses `turn/start` / app-server instead of `codex exec resume` fallback.

Progress:

- Latest Feishu `测试` became task `task-5c5645e12d17` and returned `收到。`.
- The task did not refresh VS Code because worker reported `app-server unavailable; using codex exec resume fallback ... not live in VS Code`.
- Exact app-server error: `connect ENOENT /run/user/1000/app-server.sock`.
- Existing VS Code app-server processes were not launched with `--listen`, so there was no shared socket for the worker.
- Backed up VS Code remote settings to `/home/donovan/.vscode-server/data/Machine/settings.json.bak-codex-wrapper-20260429135242`.
- Added `chatgpt.cliExecutable=/home/donovan/samba/codex-server/bin/codex-vscode-wrapper.mjs`.
- Existing Codex app-server child processes were stopped, but VS Code did not automatically relaunch them during the check window.
- Starting the shared app-server from the sandboxed local command failed with `Operation not permitted`; the same start through `ssh_mcp` was cancelled.

Next action:

- Reload the VS Code window or reopen the Codex panel so the extension launches through the wrapper and creates `/run/user/1000/app-server.sock`.
- After that, verify `node dist/cli.js vscode list 5` and send another Feishu test; expected worker path is app-server `turn/start`, not fallback.

### 014 Normalize Real Feishu Group Chat IDs

Status: completed

Planned actions:

1. Inspect the real Feishu run produced by the user's no-mention `测试` message.
2. Confirm whether OpenClaw passes `group:oc_...` while fleet stores bare `oc_...`.
3. Patch bridge chat identity normalization so Feishu group identifiers resolve to bare `oc_...` before querying fleet bindings.
4. Keep direct-message and thread-entry fallback routing unchanged.
5. Restart only the bridge sidecar/OpenClaw path needed and run a smoke with the real `group:oc_...` shape.

Action note:

- Real run `20260429-053832-7e19dcd6` used `chat_id=group:oc_7aebc9ba04e7e23b3893c85d5cbf360b` and `session_key=agent:main:feishu:group:oc_7aebc9ba04e7e23b3893c85d5cbf360b`.
- Fleet binding for the same group is stored as bare `oc_7aebc9ba04e7e23b3893c85d5cbf360b`, bound to `codex-server` session `019dd3d6-a736-7aa3-bd8c-d749124c5505`.
- Edit target: normalize Feishu group IDs in the deployed bridge before querying fleet bindings.

Result:

Completed.

Evidence:

- Backed up deployed bridge to `/data/state/codex-bridge/package/server/codex_bridge_server.py.bak-feishu-group-normalize-20260429054206`.
- Patched Feishu group ID normalization so `group:oc_...` and `agent:main:feishu:group:oc_...` resolve to bare `oc_...`.
- Restarted only the bridge sidecar; `/health` returned ok.
- Real-shaped smoke:
  - run `20260429-054317-9321ebde`
  - task `task-a472cd20eecc`
  - input `chat_id=group:oc_7aebc9ba04e7e23b3893c85d5cbf360b`
  - manager routed to `codex-server` session `019dd3d6-a736-7aa3-bd8c-d749124c5505`
  - final `FEISHU_REAL_GROUP_NORMALIZED_OK`
  - Feishu send log targeted bare group `oc_7aebc9ba04e7e23b3893c85d5cbf360b` with no queued acknowledgement.

### 015 Feishu Group Progress Streaming

Status: completed

Planned actions:

1. Keep Feishu group queued acknowledgement suppressed.
2. While a fleet task is running, poll manager events from the bridge completion watcher.
3. Forward only user-visible assistant deltas or `progress_report`-style updates to Feishu groups.
4. Suppress noisy stdout/stderr warnings from group chat unless the task ends in error.
5. Preserve final-result pushback and run a smoke that proves no duplicate final message is sent.

Result:

Completed.

Evidence:

- Backed up deployed bridge to `/data/state/codex-bridge/package/server/codex_bridge_server.py.bak-feishu-progress-20260429054656`.
- Added Feishu group progress forwarding in the completion watcher:
  - forwards `agent_message_delta` / output-text delta style events when present;
  - forwards `progress_report` items from worker stdout events;
  - suppresses raw stdout/stderr warnings in group chat;
  - keeps the final result push as the completion message.
- Restarted only the bridge sidecar; `/health` returned ok.
- Unit smoke in the OpenClaw container returned:
  - progress message `PROGRESS_STREAM_VISIBLE_...`
  - final message `FINAL_STREAM_ONCE_OK`
  - exactly two sends, proving no duplicate final in the progress path.
- Final health check:
  - bridge `/health` ok
  - fleet manager `/healthz` ok
  - endpoint `company-main` online with fresh heartbeat.

### 013 Feishu Group No-Mention Direct Codex Mode

Status: completed

Planned actions:

1. Configure OpenClaw Feishu group handling so only fleet-bound Codex groups can trigger without `@机器人`.
2. Keep non-Codex groups gated by allowlist instead of setting global open/no-mention for every group.
3. Suppress bridge-layer acknowledgements for Feishu group traffic so the group experience is closer to direct Codex interaction.
4. Preserve final-result pushback and progress/fallback visibility.
5. Restart OpenClaw with backups and verify config plus a simulated group route smoke.
6. If platform permissions do not deliver non-mention group events, report the exact Feishu permission still needed.

Result:

Completed for OpenClaw/bridge/fleet configuration and simulated group-route validation.

Evidence:

- Added and deployed `scripts/feishu_apply_codex_group_direct_mode.py`.
- OpenClaw Feishu group config now uses:
  - `groupPolicy=allowlist`
  - global `requireMention=true`
  - `groupAllowFrom` contains `90` fleet-bound Codex group IDs
  - `groups` contains `90` per-group entries with `requireMention=false`
  - each per-group entry is restricted to owner `open_id` through `allowFrom`
- OpenClaw config backup was written:
  - `/data/state/openclaw.json.bak-codex-groups-direct-20260429053319`
- Patched OpenWrt bridge so Feishu group tasks do not send the queued/middle-layer acknowledgement.
- Patched Feishu group final push so completed tasks send only the Codex final text, without the `公司 Codex 完成...` wrapper.
- Restarted OpenClaw; Feishu WebSocket recovered and container health is `healthy`.
- Simulated group route smoke:
  - group `oc_63e02862dd2991318be44e4b164b393e`
  - task `task-a4d7de0fbe9a`
  - final `FEISHU_GROUP_DIRECT_NO_AT_OK`
  - channel send log contained only the final text and no queued acknowledgement.
- Current limitation:
  - `codex exec resume --json` in the active fallback path emits final `agent_message` but no token delta, so this is direct no-mention/no-ack interaction, not true token-by-token streaming.
  - Real non-mention inbound delivery still depends on Feishu App having ordinary group-message receive permission such as `im:message.group_msg`; if a real no-mention group message does not arrive in OpenClaw logs, that permission is the next item to grant.

### 012 Feishu Group Per Codex Session

Status: completed

Planned actions:

1. Stop treating one Feishu bot DM as multiple conversations; keep the message-entry mapping only as fallback.
2. Add a Feishu group-provisioning path that creates one group chat per Codex session and binds each group `chat_id` to the corresponding `session_id`.
3. Use the existing fleet `chat_bindings` table for routing, so normal text in a session group goes directly to that Codex session.
4. Validate Feishu API permissions with a single test group before any larger batch creation.
5. If the single-group smoke passes, provision the remaining mapped sessions idempotently by skipping sessions that already have a Feishu group binding.
6. Keep all OpenWrt changes backed up and record exact smoke evidence here.

Result:

Completed. The primary Feishu mapping is now one group chat per Codex session. Numeric message-entry mapping remains only as fallback.

Evidence:

- Verified Feishu can create a group containing the owner user and the bot:
  - raw create-chat probe returned `code=0`
  - first smoke group `oc_63e02862dd2991318be44e4b164b393e`
- Added and deployed `scripts/feishu_provision_session_groups.py`.
  - It loads Feishu credentials from OpenClaw config without printing secrets.
  - It creates groups idempotently and skips sessions already bound to an `oc_...` group.
  - It binds each group `chat_id` to the matching Codex `session_id` through `/api/session-chats/bind`.
- Removed numeric prefixes from generated group names after user feedback.
  - Group names are now based on project/session title content, not `Codex-01 ...`.
  - The first smoke group was renamed with `PUT /im/v1/chats/{chat_id}`.
- Deleted the unbound raw API probe group `oc_ecffbf9bb11c8709a9528cee6562815d`.
- Group routing smoke passed:
  - simulated Feishu group `oc_63e02862dd2991318be44e4b164b393e`
  - task `task-b9ff177b2cfa`
  - target session `019daf73-cb83-79a0-8b93-e755e41c7f94`
  - final summary `FEISHU_GROUP_FINAL_PUSH_OK`
  - queued ack and final result were sent back to the same group via Feishu fast API.
- Company worker watchdog was restarted after stale heartbeat; endpoint `company-main` reported fresh heartbeat again.
- Full provisioning completed:
  - `90` Feishu `oc_...` group bindings
  - `90` unique Codex sessions mapped

### 011 Auto Map Codex Sessions To Feishu Entries

Status: completed

Planned actions:

1. Add manager-side session chat mapping storage so each Codex session can be associated with a Feishu entry/thread target.
2. Add API support to auto-bind all known sessions for a Feishu owner chat and expose a compact mapping list.
3. Patch OpenWrt bridge commands so Feishu can trigger session sync and route by mapped session number/short id without manual project binding.
4. Keep existing project chat binding behavior intact.
5. Smoke test against the current Feishu user open_id; do not depend on creating multiple Feishu P2P windows because Feishu only has one bot-user DM.

Result:

Completed as fallback and superseded by Event 012 for the primary UX.

Evidence:

- Confirmed one Feishu bot DM cannot become 90 separate left-sidebar chats.
- Implemented message-entry/thread fallback:
  - `/同步全部会话` mapped 90 Codex sessions to Feishu entry messages.
  - `88` new entry messages were sent, `2` existing entries were skipped.
  - `90` total entry/thread mappings were stored.
- Added Feishu fast API send path for text messages; later extended it to use `receive_id_type=chat_id` for group targets.

### 010 Feishu Binding Reply Routing Fix

Status: completed

Planned actions:

1. Inspect the real Feishu `/绑定 codex-server` run and confirm whether it reached OpenClaw.
2. Fix bridge parsing if Feishu message metadata prevents slash command recognition.
3. Fix bridge reply routing so Feishu-origin runs do not send lifecycle replies to the old WeChat target.
4. Smoke test with the same Feishu `open_id` and verify fleet binding state.

Result:

Completed for bridge routing and binding. Feishu application send permission is still missing on the Feishu Open Platform side.

Evidence:

- Real Feishu message was received by OpenClaw:
  - session `agent:main:feishu:default:direct:ou_b5312eaa2d5d8ba516a2d160fd26ccff`
  - display text included `[message_id: ...] ou_b5312...: /绑定 codex-server`
- Patched OpenWrt `codex_bridge_server.py` to strip Feishu `[message_id] sender:` prefixes before direct fleet command parsing.
- Patched `send_human` path so Feishu-origin runs use `openclaw message send --channel feishu --account default --target <open_id>` instead of the legacy WeChat target.
- Smoke run `20260429-035010-b6f9d33f` parsed the prefixed Feishu `/绑定 codex-server` and created binding:
  - `channel=feishu`
  - `chat_id=default:direct:ou_b5312eaa2d5d8ba516a2d160fd26ccff`
  - `project_alias=codex-server`
- Feishu reply send now targets Feishu, but fails until the app has send permission:
  - missing one of `im:message:send`, `im:message`, `im:message:send_as_bot`
  - Feishu permission URL reported by API used the app's real app id; keep the URL out of Git and regenerate it from the Feishu console when needed.

### 009 Feishu Direct Project-Bound Routing

Status: completed

Planned actions:

1. Add channel-aware chat bindings in fleet manager: `channel + chat_id/session_key -> endpoint_id + project_alias + session_policy`.
2. Keep existing WeChat session-selection behavior working, but add slash-style binding commands for Feishu/OpenClaw: `/绑定 <project>`, `/解绑`, `/状态`, `/停止`.
3. Patch OpenWrt `codex_bridge_server.py` so direct fleet routing first checks chat binding and sends ordinary text to the bound project without numeric session switching.
4. Patch OpenClaw `codex-bridge` plugin to pass channel metadata into `/runs` and stop hardcoding `created_by=openclaw-weixin`.
5. Add tests for fleet manager chat binding APIs locally.
6. Deploy only the changed OpenWrt files with backups, restart targeted bridge/OpenClaw processes, and run dry-run smoke using the active OpenClaw session key.
7. Do not configure real Feishu App credentials in this event because app_id/app_secret/event settings are not present in the environment.

Result:

Completed for the bridge/fleet/control-plane side. Real Feishu App event credentials are still not configured on OpenClaw, so the live Feishu channel itself is not enabled yet.

Evidence:

- Fleet manager now has `chat_bindings` and chat APIs:
  - `GET /api/chat-bindings`
  - `POST /api/chat-bindings`
  - `POST /api/chat-bindings/clear`
  - `POST /api/chat-bindings/task`
  - `POST /api/chat-bindings/stop`
- MCP now exposes:
  - `fleet_bind_chat`
  - `fleet_unbind_chat`
  - `fleet_chat_status`
- Local tests passed:
  - `npm run test:fleet` 6/6
  - `npm test` 22/22
- Deployed OpenWrt fleet manager files with backups and restarted manager on `100.106.225.53:18992`.
- Patched OpenWrt `codex_bridge_server.py` so Feishu-style `/绑定` `/解绑` `/状态` `/停止` `/重试` are handled before the old WeChat numeric session flow.
- Patched OpenClaw `codex-bridge` plugin so `/绑定` and related short commands are not dropped and `/runs` receives `channel`, `chat_id`, and channel-aware `created_by`.
- Restarted `openclaw-gateway-v2`; bridge health returns ok.
- Simulated Feishu dry-run binding:
  - run `20260429-030408-a3fa7a8c`
  - reply `已绑定当前聊天窗口到公司工程：codex-server`
- Simulated Feishu ordinary task:
  - run `20260429-030545-b0cd3e78`
  - task `task-bf5a06462a58`
  - manager selected project session `019dd3d6-a736-7aa3-bd8c-d749124c5505`
  - final summary `FEISHU_DIRECT_PROJECT_ROUTE_OK`
  - bridge sent queued acknowledgement and final completion back to the same simulated chat.
- Simulated Feishu `/状态`:
  - run `20260429-030614-40d1817c`
  - reply included `当前绑定：codex-server (openclaw-feishu)` and recent completed task.
- Smoke chat bindings were cleaned after validation.
- `openclaw channels capabilities` still lists only `openclaw-weixin`; Feishu App/channel setup remains a separate credential/configuration step.

### 008 Make VS Code Visibility Explicit

Status: completed

Planned actions:

1. Confirm the latest WeChat-routed task used app-server or `codex exec resume` fallback.
2. Do not modify the VS Code extension binary or install a new wrapper in this event.
3. Patch the company worker event/result data so fallback runs explicitly say `history-fallback` and `vscode_visible=false`.
4. Patch the OpenWrt WeChat bridge completion text so completed fallback tasks say they were not realtime-injected into VS Code.
5. Keep the existing fallback path working, because it is still useful for history/session control when the shared app-server socket is absent.
6. Rebuild/restart only the company worker/bridge services needed for this labeling fix, then run a small dry-run smoke.
7. If the smoke still reports `failed to record rollout items: thread ... not found`, repair that VS Code thread's account-scoped session index/state so fallback history is also recordable.

Result:

Completed for user-facing routing semantics.

Evidence:

- Latest real WeChat task `task-baa9adaf9c2b` used fallback, not app-server: manager event said `app-server unavailable; using codex exec resume fallback`.
- Current VS Code extension processes are stdio app-server children and there is no shared `/run/user/1000/app-server.sock`, so the worker cannot realtime-inject into VS Code UI yet.
- Worker fallback events now include `history-fallback` / `vscode_visible=false` semantics and say `not live in VS Code`.
- OpenWrt bridge completion messages now say `公司 Codex 完成（历史 fallback，未实时注入 VS Code）` when fallback events are detected.
- Restarted company worker and OpenWrt `codex_bridge_server.py` only.
- Dry-run `20260429-022711-cb28a9df` returned both:
  - queued acknowledgement with `若走历史 fallback，不会实时显示在 VS Code`;
  - completion push `公司 Codex 完成（历史 fallback，未实时注入 VS Code）：VSCODE_VISIBILITY_FALLBACK_DRYRUN_OK`.
- Account-scoped session state for `019dd3d6-a736-7aa3-bd8c-d749124c5505` was repaired in root/fullhome/debug state DBs where applicable.
- After repair, fallback still reports `failed to record rollout items: thread ... not found`, but the rollout JSONL does contain the fallback user/assistant messages. This is a remaining CLI record-index stderr issue, not a live VS Code UI injection path.

Decision:

- Do not claim fallback messages are visible in VS Code.
- True VS Code visibility still requires a shared `codex app-server` socket or relay installed through VS Code settings/wrapper and a VS Code extension restart. That is a separate, higher-risk action because direct binary patching previously broke the extension.

### 007 Push Fleet Task Completion Back To WeChat

Status: completed

Planned actions:

1. Confirm the latest WeChat message in `log.txt` reached fleet manager and identify the task id.
2. Verify whether company worker completed the task and whether final text is stored in manager.
3. If manager has final but WeChat only received the queued acknowledgement, patch OpenWrt `codex_bridge_server.py` to poll task completion after fastpath send.
4. Preserve dry-run behavior for simulated WeChat tests by routing completion pushes through the existing `send_human(..., run_dir)` path.
5. Restart only the codex bridge server process/container path required for the patch.
6. Run a smoke task through the active company session and verify two-phase WeChat behavior: queued acknowledgement plus completion reply.

Result:

Completed.

Progress:

- `log.txt` shows message `测试` created task `task-2b4019c744ce` and only returned queued acknowledgement.
- Fleet manager events show the task completed with final text `收到，当前会话可正常响应。`.
- Therefore the current missing piece is completion pushback from OpenClaw codex-bridge to the WeChat window, not company worker execution.

Evidence:

- Patched OpenWrt container file `/data/state/codex-bridge/package/server/codex_bridge_server.py` with a background fleet task completion watcher.
- Restarted `codex_bridge_server.py` on `127.0.0.1:18991`; `/health` returns ok.
- Dry-run WeChat smoke run `20260429-021436-99c2af72` produced two messages:
  - queued acknowledgement with `完成后我会再发一条结果`;
  - completion push `公司 Codex 完成：FLEET_COMPLETION_PUSH_DRYRUN_OK`.

### 006 Repair VS Code Session Index For Existing Thread

Status: in_progress

Planned actions:

1. Locate thread `019dd468-a7b5-7a40-bf55-5f8575ea6d0d` in `~/.codex/sessions` and `state_5.sqlite`.
2. Inspect existing `~/.codex/session_index.jsonl` entries to determine the exact index schema.
3. If only the index entry is missing, append a single reconstructed index record for this thread without modifying rollout content.
4. Add a small repair script for future missing-index cases so the worker can recover before VS Code/app-server hits `thread not found`.
5. Verify the thread is discoverable through the same scanner/manager path and that the index contains exactly one record for it.

Result:

Completed for the current fault path.

Progress:

- Root `~/.codex/session_index.jsonl` already contains thread `019dd468-a7b5-7a40-bf55-5f8575ea6d0d`.
- Root `~/.codex/state_5.sqlite` also contains the thread.
- Account scope `~/.codex/accounts/fullhome-36502773d29c44be860a358a4ed47f71/session_index.jsonl` does not contain this thread.
- Account scope `~/.codex/accounts/fullhome-36502773d29c44be860a358a4ed47f71/state_5.sqlite` also does not contain this thread.
- This matches the VS Code/OAuth failure path: plugin app-server uses account-scoped state and fails to record rollout items against a thread that only exists in root state.

Next actions:

- Back up account scoped `state_5.sqlite` and `session_index.jsonl`.
- Copy the thread row and dynamic tools from root state DB into account state DB.
- Append the missing account-scoped session index line.
- Add a reusable repair script and verify counts.

Follow-up actions after first repair:

1. Verify whether the shutdown-time `failed to record rollout items` is coming from another account-scoped or nested `CODEX_HOME` database.
2. Inspect live VS Code extension/app-server process environment for `CODEX_HOME` without printing credentials.
3. Tighten the repair script so it only targets direct account directories by default and can report nested account trees separately.
4. Repair only the active state scope that the live process is actually using, then rerun the resume smoke.
5. Update company worker routing so non-VS Code sessions use `codex exec resume` directly instead of touching app-server.
6. Rebuild and restart the resident company worker so the routing fix is active.
7. Patch fleet manager SQLite access to avoid shared implicit transactions causing `cannot start a transaction within a transaction` and dropped WeChat replies.

Final evidence:

- Account-scoped `state_5.sqlite` and `session_index.jsonl` now contain thread `019dd468-a7b5-7a40-bf55-5f8575ea6d0d`.
- Added `scripts/repair-codex-account-session.sh` for future root/account index repair.
- Worker now routes `source=cli` / `source=exec` sessions directly through `codex exec resume` fallback instead of app-server.
- OpenWrt fleet manager patched and restarted with SQLite autocommit; health and endpoint APIs respond on `100.106.225.53:18992`.
- Smoke task `task-d713e9acb2c5` targeted `019dd468-a7b5-7a40-bf55-5f8575ea6d0d`, produced event `non-vscode session; using codex exec resume fallback`, completed with `NON_VSCODE_FALLBACK_ROUTE_OK`.
- Local tests passed: `npm test` 22/22, `npm run test:fleet` 3/3.

### 001 Restore VS Code Codex Binary

Status: completed

Planned actions:

1. 检查 VS Code ChatGPT/Codex 扩展目录下是否存在 `bin/linux-x86_64/codex.real`。
2. 如果当前 `codex` 是我写入的 shell wrapper，则备份为 `codex.bridge-wrapper-bak-<timestamp>`。
3. 把 `codex.real` 恢复为 `codex`，恢复插件原始 CLI binary。
4. 验证 `codex --version`、`codex app-server --help` 可运行。
5. 检查现有 VS Code `codex app-server` 进程和日志，确认至少恢复到原始 stdio 模式。

Result:

Completed.

Evidence:

- VS Code extension `bin/linux-x86_64/codex` is back to an ELF binary in both installed extension versions.
- Previous shell wrappers are preserved as `codex.wrapper-bak.20260428221203`.
- `codex.real` copies are still present for rollback/reference.
- Current VS Code process is again starting `codex app-server --analytics-default-enabled` in the original stdio mode.

Decision:

- Do not patch or replace the VS Code extension binary again for this task.
- Real-time VS Code control must be implemented through a separate bridge/relay path or a safe fallback, not by mutating the extension binary in place.

### 002 Repair Company Session Send Path

Status: completed

Planned actions:

1. Inspect company worker send logic and the app-server client failure path.
2. Add a safe fallback for selected company sessions when `/run/user/1000/app-server.sock` is missing:
   - prefer app-server if available;
   - otherwise use `codex exec resume <session_id>` in the session cwd/headless mode;
   - report clearly that this is fallback/headless and may not appear live in VS Code UI until history refresh.
3. Ensure fleet manager records task status/events for queued/running/completed/error.
4. Verify by submitting a simulated WeChat message after `切入 1`.

Result:

Completed.

Progress:

- Added worker fallback: when app-server socket/websocket is unavailable, selected VS Code sessions are resumed with `codex exec resume <session_id>`.
- Fallback emits explicit `task/started`, stdout/stderr, `task/final`, and completion/error events.
- Local verification: `npm test` passed, 21/21 tests.

Next actions:

- Completed by smoke tasks `task-1a4c549bf3da` and `task-9203d396e685`.
- Both used fallback successfully and produced final assistant text.

### 003 Worker Supervision And Stale Task Recovery

Status: completed

Planned actions:

1. Add a local watchdog script for the company worker:
   - checks `~/.codex-bridge/fleet-agent.pid`;
   - restarts `run-fleet-agent.sh` if the process is gone;
   - appends compact health logs.
2. Start the watchdog in background.
3. Add a bounded timeout for headless/fallback Codex child processes so tasks do not remain `running` forever.
4. Mark the interrupted smoke task `task-6817726469a1` as error/stale in manager state.
5. Re-run smoke with a fresh task.

Result:

Completed.

Progress:

- Fresh simulated WeChat task `task-1a4c549bf3da` completed through `codex exec resume` fallback and returned `WECHAT_TO_COMPANY_FALLBACK_SMOKE_OK`.
- The previous stuck smoke task was marked stale/error in manager state.
- Current gap: the worker process and watchdog are not staying resident after debug runs; this must be fixed before relying on long-running monitoring.
- Watchdog and monitor were started in the background.
- Monitor correctly detected manager connectivity failures and launched a Codex CLI audit once.
- New gap: the first monitor version used `/api/state`, which can time out over Tailscale and makes the audit too heavy; switch to smaller endpoints and a narrower prompt.
- Direct `curl` to `/api/endpoints` still timed out after 20s, so the current fault is manager/network reachability, not WeChat routing.
- Add bounded HTTP timeouts in the worker manager client so a dead manager cannot leave worker fetch calls hanging indefinitely.
- Follow-up correction: worker poll is a 25s long-poll, so the manager HTTP timeout must be longer than the poll timeout. Use a 40s default to avoid false timeout loops.

Next actions:

- Make watchdog startup robust with a single pid file for watchdog and worker.
- Add a Codex CLI assisted monitor loop that reads recent worker/manager logs and triggers deterministic recovery when it sees stuck states.
- Re-run a fresh simulated WeChat smoke after the watchdog is proven alive.

Result:

Completed.

Evidence:

- `scripts/fleet-agent-watchdog.sh` is running and restarts the company worker if its pid exits.
- `scripts/codex-fleet-log-monitor.sh` is running in the background and can launch a bounded Codex CLI audit on anomalies.
- Worker HTTP timeout was adjusted to 40s so normal 25s long-poll is not treated as failure.
- Manager endpoint reports `company-main` online with fresh heartbeat.

### 004 Human Target Switching And Home/Company Separation

Status: completed

Planned actions:

1. Inspect the OpenWrt WeChat bridge routing code that handles `列出公司codex所有会话`, `切入 N`, and ordinary messages.
2. Add explicit home/company target commands:
   - `切入 N` selects a company session and routes ordinary text to company Codex.
   - `回到家里` / `本地处理` / `退出公司会话` clears company routing and keeps later text for home Codex.
   - `当前目标` reports whether this WeChat conversation is bound to home Codex or a company session.
3. Keep numeric session mapping cached per WeChat conversation so IDs like `019dd3d6-a736...` do not need to be typed.
4. Verify with the OpenWrt simulated WeChat channel.

Result:

Completed.

Progress:

- OpenWrt SSH currently accepts TCP but does not complete SSH banner/handshake, so direct patching of the WeChat bridge container is blocked.
- Implement the target-separation primitives in `codex-fleet-manager` first:
  - clear current company session/project context;
  - read current target context;
  - expose MCP tool for "回到家里"/clear target.
- OpenWrt WeChat bridge source was backed up and patched with:
  - `回到家里` / `本地处理` / `退出公司会话`;
  - `当前目标`;
  - company Codex status summary fastpath;
  - `显示更多/全部` session listing.

Next actions:

- Restart only the bridge subprocess in `openclaw-gateway-v2`.
- Run simulated WeChat smoke for list/use/send/current-target/return-home/status.

Result:

Completed.

Evidence:

- Simulated WeChat dry-run listed 87 company Codex sessions and displayed `[1]`-style numeric mapping.
- `切入 1` bound the current WeChat conversation to company session `019dd3d6-a736...`.
- `当前目标` reported company routing while bound, and home routing after `回到家里`.
- A normal message was routed to company Codex as task `task-9203d396e685`.
- The task completed with final summary `FLEET_SMOKE_ROUTE_OK`.

### 005 Batch Monitoring And WeChat Status Summary

Status: completed

Planned actions:

1. Add a lightweight status summary endpoint or script that reads manager tasks/events and formats:
   - active/running tasks;
   - recently completed/error tasks;
   - endpoint online/offline and last heartbeat.
2. Make it suitable for home Codex scheduled polling and WeChat reporting without spamming every raw event.
3. Verify that simulated WeChat can request a status summary quickly.

Result:

Completed.

Progress:

- Implement a compact `/api/summary` manager endpoint and MCP `fleet_summary` tool so home Codex can poll status without reading full state.

Next actions:

- Deploy manager/MCP changes to OpenWrt `/opt/weixin-bot/codex-fleet`.
- Restart only the fleet manager process.
- Verify `/api/summary`, `/api/context/clear`, and MCP-visible behavior.
- Fix SQLite concurrency errors observed after restart:
  - `cannot start a transaction within a transaction`;
  - `cannot commit - no transaction is active`.

Result:

Completed.

Evidence:

- OpenWrt `/api/summary?profile=home-codex&limit=3` returns compact context, endpoint, active task, and recent task state.
- OpenWrt `/api/context/clear` clears the home Codex profile target.
- MCP `tools/list` includes `fleet_summary` and `fleet_clear_target`.
- Manager SQLite access now has an in-process lock and `busy_timeout`.
