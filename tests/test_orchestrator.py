"""Adversarial tests for orchestrator — catch real bugs, not confirm code works."""

import os
from pathlib import Path

from octopus.orchestrator import (
    build_prompt, build_retry_prompt, load_config,
    ask_model, is_server_running, _prune_frames,
    STAGES, PROTOCOL_DIR,
)


def test_markov_boundary_no_context_leak(tmp_path):
    """Stage i prompt must NOT contain content from stage i-2."""
    identify_out = tmp_path / "identify.json"
    identify_out.write_text('{"devices": ["PROBE_MARKER"]}')
    prompt = build_prompt("interface", tmp_path / "out.json", identify_out)
    assert str(identify_out) in prompt


def test_retry_prompt_doesnt_embed_spec_when_edit_enabled(tmp_path):
    """When edit_specs=True, spec must NOT be inline."""
    agent_log = tmp_path / "agent.log"
    agent_log.write_text("error occurred")
    prompt = build_retry_prompt("serve", tmp_path / "out.py", None, agent_log, edit_specs=True)
    spec_content = (PROTOCOL_DIR / "serve.md").read_text()
    assert spec_content not in prompt
    assert str(PROTOCOL_DIR / "serve.md") in prompt


def test_build_prompt_handles_nonexistent_prev(tmp_path):
    """If prev_path doesn't exist, don't reference it."""
    prompt = build_prompt("identify", tmp_path / "out.json", tmp_path / "nope.json")
    assert "nope.json" not in prompt


def test_config_returns_ints_not_strings():
    """Config values must be int, not str."""
    config = load_config()
    assert isinstance(config["max_attempts"], int)
    assert isinstance(config["watch_interval"], int)


def test_config_survives_missing_file(tmp_path, monkeypatch):
    """Defaults when toml doesn't exist."""
    import octopus.orchestrator as orch
    monkeypatch.setattr(orch, "CONFIG_PATH", tmp_path / "nope.toml")
    config = load_config()
    assert config["agent_command"] == "pi"


def test_is_server_running_with_own_pid(tmp_path, monkeypatch):
    """Our own PID should register as running."""
    import octopus.orchestrator as orch
    pid_file = tmp_path / "server.pid"
    pid_file.write_text(str(os.getpid()))
    monkeypatch.setattr(orch, "SERVER_PID", pid_file)
    assert is_server_running() is True


def test_is_server_running_empty_file(tmp_path, monkeypatch):
    """Empty PID file shouldn't crash."""
    import octopus.orchestrator as orch
    pid_file = tmp_path / "server.pid"
    pid_file.write_text("")
    monkeypatch.setattr(orch, "SERVER_PID", pid_file)
    assert is_server_running() is False


def test_all_specs_exist():
    """Every stage must have a non-placeholder spec."""
    for stage, _ in STAGES:
        spec = PROTOCOL_DIR / f"{stage}.md"
        assert spec.exists() and spec.stat().st_size > 100


def test_ask_model_returns_empty_without_key(monkeypatch):
    """ask_model must not crash without API key."""
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    assert ask_model("test", {}) == ""


def test_perception_disabled_without_config(tmp_path, monkeypatch):
    """Perception must be off when no config file exists."""
    import octopus.orchestrator as orch
    monkeypatch.setattr(orch, "CONFIG_PATH", tmp_path / "nope.toml")
    config = load_config()
    assert config.get("perception_enabled", False) is False


def test_perception_enabled_in_project_config():
    """Project octopus.toml should have perception enabled by default."""
    config = load_config()
    assert config.get("perception_enabled") is True


def test_perception_config_simplified():
    """Perception config should not have AOBOCAM-specific fields."""
    config = load_config()
    assert "perception_stream_url" not in config
    assert "perception_snapshot_url" not in config
    assert "perception_username" not in config
    assert "perception_password" not in config
    assert "perception_camera_type" not in config


def test_perceive_spec_exists():
    """perceive.md spec must exist and be substantial (privileged step)."""
    spec = PROTOCOL_DIR / "privileged" / "perceive.md"
    assert spec.exists() and spec.stat().st_size > 100


def test_prune_frames_keeps_max(tmp_path):
    """Frame pruning should keep only max_frames."""
    for i in range(10):
        (tmp_path / f"frame_{i:04d}.png").write_text(f"frame {i}")
    _prune_frames(tmp_path, max_frames=3)
    remaining = sorted(tmp_path.glob("frame_*.png"))
    assert len(remaining) == 3
    assert remaining[-1].name == "frame_0009.png"
