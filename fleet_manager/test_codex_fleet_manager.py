import json
import tempfile
import unittest
from pathlib import Path

from fleet_manager.codex_fleet_manager import FleetStore


class FleetStoreTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = FleetStore(Path(self.tmp.name) / "fleet.db")

    def tearDown(self):
        self.tmp.cleanup()

    def test_register_endpoint_project_and_task(self):
        self.store.register_endpoint("company-main", "Company", {"vscode": True}, [
            {"id": "019dd3d6-a736-7aa3", "source": "vscode", "title": "codex-server", "cwd": "/repo/codex-server"}
        ])
        self.store.register_project("codex-server", "company-main", "/repo/codex-server")
        self.store.use_project("home", "codex-server")
        self.store.use_session("home", "019dd3d6-a736")
        task = self.store.create_task("home", "继续当前任务", None, None, None)
        commands = self.store.claim_commands("company-main")

        self.assertEqual(task["endpoint_id"], "company-main")
        self.assertEqual(task["project_alias"], "codex-server")
        self.assertEqual(task["session_id"], "019dd3d6-a736-7aa3")
        self.assertEqual(commands[0]["type"], "send")
        self.assertEqual(commands[0]["payload"]["prompt"], "继续当前任务")

    def test_events_update_task_status(self):
        self.store.register_endpoint("company-main", "Company", {})
        task = self.store.create_task("default", "hello", None, None, None)
        command = self.store.claim_commands("company-main")[0]
        self.store.record_worker_events("company-main", {
            "command_results": [{
                "command_id": command["command_id"],
                "task_id": task["task_id"],
                "ok": True,
                "task_status": "running",
                "session_id": "thread-1",
            }],
            "events": [{"task_id": task["task_id"], "session_id": "thread-1", "type": "turn/completed", "message": "done"}],
        })
        updated = self.store.task(task["task_id"])
        self.assertEqual(updated["status"], "completed")
        self.assertEqual(updated["last_summary"], "done")

    def test_progress_events_refresh_running_task_summary(self):
        self.store.register_endpoint("company-main", "Company", {})
        task = self.store.create_task("default", "hello", None, None, None)
        command = self.store.claim_commands("company-main")[0]
        self.store.record_worker_events("company-main", {
            "command_results": [{
                "command_id": command["command_id"],
                "task_id": task["task_id"],
                "ok": True,
                "task_status": "running",
                "session_id": "thread-1",
            }],
            "events": [{"task_id": task["task_id"], "session_id": "thread-1", "type": "vscode/assistant", "message": "working"}],
        })

        updated = self.store.task(task["task_id"])
        self.assertEqual(updated["status"], "running")
        self.assertEqual(updated["session_id"], "thread-1")
        self.assertEqual(updated["last_summary"], "working")

    def test_clear_context_and_summary(self):
        self.store.register_endpoint("company-main", "Company", {"vscode": True}, [
            {"id": "019dd3d6-a736-7aa3", "source": "vscode", "title": "codex-server", "cwd": "/repo/codex-server"}
        ])
        self.store.register_project("codex-server", "company-main", "/repo/codex-server")
        self.store.use_project("home", "codex-server")
        self.store.use_session("home", "019dd3d6-a736")
        self.store.create_task("home", "queued prompt", None, None, None)

        summary = self.store.summary("home")
        self.assertEqual(summary["context"]["project_alias"], "codex-server")
        self.assertEqual(summary["counts"]["active"], 1)
        self.assertEqual(summary["counts"]["sessions"], 1)

        cleared = self.store.clear_context("home")
        self.assertIsNone(cleared["project_alias"])
        self.assertIsNone(cleared["session_id"])

    def test_project_task_uses_recent_project_session(self):
        self.store.register_endpoint("company-main", "Company", {"vscode": True}, [
            {"id": "thread-old", "source": "vscode", "title": "old", "cwd": "/repo/codex-server"},
            {"id": "thread-new", "source": "vscode", "title": "new", "cwd": "/repo/codex-server"},
        ])
        self.store.heartbeat("company-main", [
            {"id": "thread-new", "source": "vscode", "title": "new", "cwd": "/repo/codex-server"},
        ])
        self.store.register_project("codex-server", "company-main", "/repo/codex-server")

        task = self.store.create_task("feishu-chat", "继续", "codex-server", None, None)

        self.assertEqual(task["project_alias"], "codex-server")
        self.assertEqual(task["session_id"], "thread-new")

    def test_chat_binding_creates_project_task_and_tracks_status(self):
        self.store.register_endpoint("company-main", "Company", {"vscode": True}, [
            {"id": "thread-1", "source": "vscode", "title": "codex-server", "cwd": "/repo/codex-server"}
        ])
        self.store.register_project("codex-server", "company-main", "/repo/codex-server")

        binding = self.store.bind_chat("openclaw-feishu", "chat-1", "session-key-1", "codex-server")
        task = self.store.create_chat_task("openclaw-feishu", "chat-1", "实现需求")
        status = self.store.chat_status("openclaw-feishu", "chat-1")
        commands = self.store.claim_commands("company-main")

        self.assertEqual(binding["project_alias"], "codex-server")
        self.assertEqual(task["chat_channel"], "openclaw-feishu")
        self.assertEqual(task["chat_id"], "chat-1")
        self.assertEqual(task["profile"], "session-key-1")
        self.assertEqual(task["session_id"], "thread-1")
        self.assertEqual(status["binding"]["project_alias"], "codex-server")
        self.assertEqual(status["active_task"]["task_id"], task["task_id"])
        self.assertEqual(commands[0]["payload"]["project"]["alias"], "codex-server")

    def test_chat_message_guides_active_task_by_default(self):
        self.store.register_endpoint("company-main", "Company", {"vscode": True}, [
            {"id": "thread-1", "source": "vscode", "title": "codex-server", "cwd": "/repo/codex-server"}
        ])
        self.store.register_project("codex-server", "company-main", "/repo/codex-server")
        self.store.bind_chat("openclaw-feishu", "chat-1", "session-key-1", "codex-server")
        task = self.store.create_chat_task("openclaw-feishu", "chat-1", "先做 A")
        first_command = self.store.claim_commands("company-main")[0]
        self.store.record_worker_events("company-main", {
            "command_results": [{
                "command_id": first_command["command_id"],
                "task_id": task["task_id"],
                "ok": True,
                "task_status": "running",
                "session_id": "thread-1",
            }]
        })

        guided = self.store.create_chat_task("openclaw-feishu", "chat-1", "补充：先改方向 B")
        guidance_command = self.store.claim_commands("company-main")[0]

        self.assertEqual(guided["task_id"], task["task_id"])
        self.assertTrue(guided["guidance"])
        self.assertEqual(guidance_command["task_id"], task["task_id"])
        self.assertTrue(guidance_command["payload"]["guidance"])
        self.assertEqual(guidance_command["payload"]["prompt"], "补充：先改方向 B")
        self.assertEqual(guidance_command["payload"]["session_id"], "thread-1")

    def test_chat_project_prefix_is_passthrough_guidance(self):
        self.store.register_endpoint("company-main", "Company", {"vscode": True}, [
            {"id": "server-thread", "source": "vscode", "title": "codex-server", "cwd": "/repo/codex-server"},
            {"id": "database-thread", "source": "vscode", "title": "codex-database", "cwd": "/repo/codex-database"},
        ])
        self.store.register_project("codex-server", "company-main", "/repo/codex-server")
        self.store.register_project("codex-database", "company-main", "/repo/codex-database")
        self.store.bind_chat("openclaw-feishu", "chat-1", "session-key-1", "codex-server")
        active = self.store.create_chat_task("openclaw-feishu", "chat-1", "先处理服务器")
        first_command = self.store.claim_commands("company-main")[0]
        self.store.record_worker_events("company-main", {
            "command_results": [{
                "command_id": first_command["command_id"],
                "task_id": active["task_id"],
                "ok": True,
                "task_status": "running",
                "session_id": "server-thread",
            }]
        })

        prompt = "codex-database 检查OpenWrt连通性"
        routed = self.store.create_chat_task("openclaw-feishu", "chat-1", prompt)
        command = self.store.claim_commands("company-main")[0]

        self.assertEqual(routed["task_id"], active["task_id"])
        self.assertEqual(routed["project_alias"], "codex-server")
        self.assertEqual(routed["session_id"], "server-thread")
        self.assertTrue(routed["guidance"])
        self.assertEqual(command["payload"]["project"]["alias"], "codex-server")
        self.assertEqual(command["payload"]["prompt"], prompt)
        self.assertTrue(command["payload"].get("guidance", False))

    def test_chat_message_can_explicitly_start_new_task(self):
        self.store.register_endpoint("company-main", "Company", {"vscode": True}, [
            {"id": "thread-1", "source": "vscode", "title": "codex-server", "cwd": "/repo/codex-server"}
        ])
        self.store.register_project("codex-server", "company-main", "/repo/codex-server")
        self.store.bind_chat("openclaw-feishu", "chat-1", "session-key-1", "codex-server")
        task = self.store.create_chat_task("openclaw-feishu", "chat-1", "先做 A")
        first_command = self.store.claim_commands("company-main")[0]
        self.store.record_worker_events("company-main", {
            "command_results": [{
                "command_id": first_command["command_id"],
                "task_id": task["task_id"],
                "ok": True,
                "task_status": "running",
                "session_id": "thread-1",
            }]
        })

        new_task = self.store.create_chat_task("openclaw-feishu", "chat-1", "新任务：做 C")
        new_command = self.store.claim_commands("company-main")[0]

        self.assertNotEqual(new_task["task_id"], task["task_id"])
        self.assertNotIn("guidance", new_task)
        self.assertFalse(new_command["payload"].get("guidance", False))

    def test_unbind_chat(self):
        self.store.register_endpoint("company-main", "Company", {})
        self.store.register_project("codex-server", "company-main", "/repo/codex-server")
        self.store.bind_chat("openclaw-feishu", "chat-1", None, "codex-server")

        result = self.store.unbind_chat("openclaw-feishu", "chat-1")

        self.assertTrue(result["removed"])
        self.assertIsNone(self.store.chat_binding("openclaw-feishu", "chat-1"))

    def test_sync_session_chats_and_route_by_number(self):
        self.store.register_endpoint("company-main", "Company", {"vscode": True}, [
            {"id": "thread-1", "source": "vscode", "title": "first", "cwd": "/repo/codex-server"},
            {"id": "thread-2", "source": "vscode", "title": "second", "cwd": "/repo/other"},
        ])
        self.store.register_project("codex-server", "company-main", "/repo/codex-server")

        synced = self.store.sync_session_chats("feishu", "direct:ou_user", "feishu-profile")
        first_session_id = synced["mappings"][0]["session"]["session_id"]
        routed = self.store.create_session_chat_task("feishu", "direct:ou_user", "1", "继续这个会话")
        commands = self.store.claim_commands("company-main")

        self.assertEqual(synced["count"], 2)
        self.assertEqual(synced["mappings"][0]["binding"]["session_policy"], "fixed-session")
        self.assertEqual(routed["task"]["session_id"], first_session_id)
        self.assertEqual(routed["task"]["chat_channel"], "feishu")
        self.assertIn(f":session:{first_session_id}", routed["task"]["chat_id"])
        self.assertEqual(commands[0]["payload"]["session_id"], first_session_id)


if __name__ == "__main__":
    unittest.main()
