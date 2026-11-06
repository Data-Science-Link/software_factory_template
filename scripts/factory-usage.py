#!/usr/bin/env python3
"""Parse OpenCode session usage and sum tokens across all sessions."""

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Dict, Any, Optional


def parse_session_file(session_path: Path) -> Dict[str, Any]:
    """Parse a single session file and extract usage data."""
    try:
        with session_path.open('r', encoding='utf-8') as f:
            data = json.load(f)
        
        # Initialize usage counters
        usage = {
            "requests": 0,
            "tokens_in": 0,
            "tokens_cached": 0,
            "tokens_out": 0,
            "tokens_reasoning": 0,
            "provider_cost": 0.0,
            "has_provider_cost": False
        }
        
        # Extract usage from session data
        if isinstance(data, dict):
            # Check for provider-reported cost first
            if "usage" in data and isinstance(data["usage"], dict):
                provider_usage = data["usage"]
                if "estimated_cost" in provider_usage:
                    usage["provider_cost"] += float(provider_usage["estimated_cost"])
                    usage["has_provider_cost"] = True
                
                # Extract token counts if available
                if "prompt_tokens" in provider_usage:
                    usage["tokens_in"] += int(provider_usage["prompt_tokens"])
                if "completion_tokens" in provider_usage:
                    usage["tokens_out"] += int(provider_usage["completion_tokens"])
            
            # Look for tool usage data in messages
            if "messages" in data and isinstance(data["messages"], list):
                for msg in data["messages"]:
                    if isinstance(msg, dict) and "content" in msg:
                        content = msg["content"]
                        if isinstance(content, list):
                            # Look for token usage in tool messages
                            for item in content:
                                if isinstance(item, dict) and "usage" in item:
                                    tool_usage = item["usage"]
                                    if isinstance(tool_usage, dict):
                                        if "prompt_tokens" in tool_usage:
                                            usage["tokens_in"] += int(tool_usage["prompt_tokens"])
                                        if "completion_tokens" in tool_usage:
                                            usage["tokens_out"] += int(tool_usage["completion_tokens"])
                                        if "cached_tokens" in tool_usage:
                                            usage["tokens_cached"] += int(tool_usage["cached_tokens"])
                                        if "reasoning_tokens" in tool_usage:
                                            usage["tokens_reasoning"] += int(tool_usage["reasoning_tokens"])
                        
                        # Count requests by counting tool calls or assistant messages
                        if msg.get("role") == "assistant":
                            usage["requests"] += 1
            
            # Look for usage in session metadata
            if "stats" in data and isinstance(data["stats"], dict):
                stats = data["stats"]
                if "tokens_in" in stats:
                    usage["tokens_in"] += int(stats["tokens_in"])
                if "tokens_cached" in stats:
                    usage["tokens_cached"] += int(stats["tokens_cached"])
                if "tokens_out" in stats:
                    usage["tokens_out"] += int(stats["tokens_out"])
                if "tokens_reasoning" in stats:
                    usage["tokens_reasoning"] += int(stats["tokens_reasoning"])
                if "requests" in stats:
                    usage["requests"] += int(stats["requests"])
        
        return usage
    
    except (json.JSONDecodeError, OSError, KeyError, ValueError, TypeError) as e:
        print(f"Warning: Could not parse session file {session_path}: {e}", file=sys.stderr)
        return None


def sum_usage_across_sessions(usage_dir: Path) -> Dict[str, Any]:
    """Sum usage across all session files in the directory."""
    total_usage = {
        "requests": 0,
        "tokens_in": 0,
        "tokens_cached": 0,
        "tokens_out": 0,
        "tokens_reasoning": 0,
        "provider_cost": 0.0,
        "has_provider_cost": False
    }
    
    session_files = list(usage_dir.glob("*.json"))
    if not session_files:
        # Try looking for session files in subdirectories
        session_files = list(usage_dir.rglob("*.json"))
    
    if not session_files:
        return None
    
    found_any_valid = False
    for session_file in session_files:
        usage = parse_session_file(session_file)
        if usage is not None:
            found_any_valid = True
            total_usage["requests"] += usage["requests"]
            total_usage["tokens_in"] += usage["tokens_in"]
            total_usage["tokens_cached"] += usage["tokens_cached"]
            total_usage["tokens_out"] += usage["tokens_out"]
            total_usage["tokens_reasoning"] += usage["tokens_reasoning"]
            total_usage["provider_cost"] += usage["provider_cost"]
            if usage["has_provider_cost"]:
                total_usage["has_provider_cost"] = True
    
    return total_usage if found_any_valid else None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--usage-dir", 
        type=Path, 
        required=True,
        help="Directory containing OpenCode session usage files"
    )
    args = parser.parse_args()
    
    # Allow override for testing
    usage_fixture = os.environ.get("OPENCODE_USAGE_FIXTURE")
    if usage_fixture:
        usage_dir = Path(usage_fixture)
    else:
        usage_dir = args.usage_dir
    
    if not usage_dir.is_dir():
        print(f"ERROR: Usage directory does not exist: {usage_dir}", file=sys.stderr)
        return 1
    
    usage = sum_usage_across_sessions(usage_dir)
    if usage is None:
        print("ERROR: No valid usage data found", file=sys.stderr)
        return 1
    
    # Output as JSON
    output = {
        "requests": usage["requests"],
        "tokens_in": usage["tokens_in"],
        "tokens_cached": usage["tokens_cached"],
        "tokens_out": usage["tokens_out"],
        "tokens_reasoning": usage["tokens_reasoning"]
    }
    
    if usage["has_provider_cost"]:
        output["provider_cost"] = round(usage["provider_cost"], 6)
    
    print(json.dumps(output, separators=(',', ':')))
    return 0


if __name__ == "__main__":
    sys.exit(main())