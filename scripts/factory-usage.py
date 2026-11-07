#!/usr/bin/env python3
"""Parse OpenCode session exports and compute run totals."""

import decimal
import json
import os
import sys
from collections import defaultdict

# Set precision for decimal operations
decimal.getcontext().prec = 10


def main():
    # Get file paths from arguments or environment variable
    file_paths = sys.argv[1:]
    
    if not file_paths:
        fixture_env = os.environ.get('OPENCODE_USAGE_FIXTURE')
        if not fixture_env:
            print('factory-usage: no inputs', file=sys.stderr)
            return 2
        file_paths = fixture_env.split(':')
    
    # Process each file and accumulate totals
    session_ids = set()
    totals = {
        'tokens_in': 0,
        'tokens_cached': 0,
        'tokens_out': 0,
        'tokens_reasoning': 0,
        'requests': 0,
        'sessions': 0,
        'opencode_cost_usd': decimal.Decimal('0'),
        'models': set(),
    }
    
    all_costs_available = True
    
    for file_path in file_paths:
        if not os.path.exists(file_path):
            print(f'factory-usage: file not found: {file_path}', file=sys.stderr)
            return 2
            
        # Check if file is valid UTF-8
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
        except UnicodeDecodeError:
            print(f'factory-usage: non-UTF-8 file: {file_path}', file=sys.stderr)
            return 3
        except (json.JSONDecodeError, OSError) as e:
            print(f'factory-usage: invalid JSON in {file_path}', file=sys.stderr)
            return 3
        
        # Validate top-level JSON is an object
        if not isinstance(data, dict):
            print(f'factory-usage: top-level JSON is not an object in {file_path}', file=sys.stderr)
            return 3
        
        # Validate basic structure
        if 'info' not in data or 'messages' not in data:
            print(f'factory-usage: missing info or messages in {file_path}', file=sys.stderr)
            return 3
            
        # Validate messages is a list
        if not isinstance(data['messages'], list):
            print(f'factory-usage: messages is not a list in {file_path}', file=sys.stderr)
            return 3
            
        session_info = data['info']
        if 'id' not in session_info:
            print(f'factory-usage: missing session id in {file_path}', file=sys.stderr)
            return 3
            
        # Check for duplicate session IDs
        session_id = session_info['id']
        if session_id in session_ids:
            print(f'factory-usage: duplicate session id: {session_id}', file=sys.stderr)
            return 3
        session_ids.add(session_id)
        
        # Extract session-level tokens for cross-checking
        session_tokens = session_info.get('tokens', {})
        
        # Check for unknown keys in session tokens
        valid_session_token_keys = {'input', 'output', 'reasoning', 'cache'}
        for key in session_tokens:
            if key not in valid_session_token_keys:
                print(f'factory-usage: unknown session token key: {key} in {file_path}', file=sys.stderr)
                return 3
        
        # Require all keys in session tokens
        required_session_token_keys = ['input', 'output', 'reasoning']
        for key in required_session_token_keys:
            if key not in session_tokens:
                print(f'factory-usage: missing session token key: {key} in {file_path}', file=sys.stderr)
                return 3
            # Explicitly check for boolean values
            if not isinstance(session_tokens[key], int) or isinstance(session_tokens[key], bool) or session_tokens[key] < 0:
                print(f'factory-usage: invalid session {key} value in {file_path}', file=sys.stderr)
                return 3
                
        # Check cache keys if present
        if 'cache' in session_tokens:
            cache_obj = session_tokens['cache']
            if not isinstance(cache_obj, dict):
                print(f'factory-usage: session cache is not an object in {file_path}', file=sys.stderr)
                return 3
            
            # Check for unknown keys in session cache
            valid_cache_keys = {'read', 'write'}
            for key in cache_obj:
                if key not in valid_cache_keys:
                    print(f'factory-usage: unknown session cache key: {key} in {file_path}', file=sys.stderr)
                    return 3
                    
            required_cache_keys = ['read', 'write']
            for key in required_cache_keys:
                if key not in cache_obj:
                    print(f'factory-usage: missing session cache key: {key} in {file_path}', file=sys.stderr)
                    return 3
                # Explicitly check for boolean values
                if not isinstance(cache_obj[key], int) or isinstance(cache_obj[key], bool) or cache_obj[key] < 0:
                    print(f'factory-usage: invalid session cache.{key} value in {file_path}', file=sys.stderr)
                    return 3
        else:
            print(f'factory-usage: missing session cache object in {file_path}', file=sys.stderr)
            return 3
        
        expected_input = session_tokens['input']
        expected_cache_read = session_tokens['cache']['read']
        expected_cache_write = session_tokens['cache']['write']
        expected_output = session_tokens['output']
        expected_reasoning = session_tokens['reasoning']
        
        # Count assistant messages and their tokens
        message_totals = {
            'input': 0,
            'cache_read': 0,
            'cache_write': 0,
            'output': 0,
            'reasoning': 0,
            'cost': decimal.Decimal('0'),
            'count': 0
        }
        
        for message in data['messages']:
            if not isinstance(message, dict):
                continue
                
            if 'info' not in message:
                continue
                
            info = message['info']
            if not isinstance(info, dict):
                continue
                
            if info.get('role') != 'assistant':
                continue
                
            # Check for required fields
            if 'tokens' not in info:
                print(f'factory-usage: assistant message missing tokens in {file_path}', file=sys.stderr)
                return 3
                
            tokens = info['tokens']
            if not isinstance(tokens, dict):
                print(f'factory-usage: message tokens is not an object in {file_path}', file=sys.stderr)
                return 3
            
            # Check for unknown keys in message tokens
            valid_message_token_keys = {'input', 'output', 'reasoning', 'cache', 'total'}
            for key in tokens:
                if key not in valid_message_token_keys:
                    print(f'factory-usage: unknown message token key: {key} in {file_path}', file=sys.stderr)
                    return 3
            
            # Require all keys in message tokens
            required_message_token_keys = ['input', 'output', 'reasoning', 'cache']
            for key in required_message_token_keys:
                if key not in tokens:
                    print(f'factory-usage: missing message token key: {key} in {file_path}', file=sys.stderr)
                    return 3
                # Validate values are non-negative integers
                if key != 'cache':
                    # Explicitly check for boolean values
                    if not isinstance(tokens[key], int) or isinstance(tokens[key], bool) or tokens[key] < 0:
                        print(f'factory-usage: invalid message {key} value in {file_path}', file=sys.stderr)
                        return 3
            
            # Check cache keys
            if not isinstance(tokens['cache'], dict):
                print(f'factory-usage: message cache is not an object in {file_path}', file=sys.stderr)
                return 3
                
            # Check for unknown keys in message cache
            valid_cache_keys = {'read', 'write'}
            for key in tokens['cache']:
                if key not in valid_cache_keys:
                    print(f'factory-usage: unknown message cache key: {key} in {file_path}', file=sys.stderr)
                    return 3
                    
            required_cache_keys = ['read', 'write']
            for key in required_cache_keys:
                if key not in tokens['cache']:
                    print(f'factory-usage: missing message cache key: {key} in {file_path}', file=sys.stderr)
                    return 3
                # Explicitly check for boolean values
                if not isinstance(tokens['cache'][key], int) or isinstance(tokens['cache'][key], bool) or tokens['cache'][key] < 0:
                    print(f'factory-usage: invalid message cache.{key} value in {file_path}', file=sys.stderr)
                    return 3
            

                        
            # Accumulate message tokens
            message_totals['input'] += tokens['input']
            message_totals['output'] += tokens['output']
            message_totals['reasoning'] += tokens['reasoning']
            message_totals['cache_read'] += tokens['cache']['read']
            message_totals['cache_write'] += tokens['cache']['write']
            message_totals['count'] += 1
            
            # Handle cost
            if 'cost' not in info or not isinstance(info['cost'], (int, float)):
                all_costs_available = False
            else:
                try:
                    message_totals['cost'] += decimal.Decimal(str(info['cost']))
                except (ValueError, decimal.InvalidOperation):
                    all_costs_available = False
            
            # Collect model info
            provider_id = info.get('providerID')
            model_id = info.get('modelID')
            if provider_id and model_id:
                totals['models'].add(f'{provider_id}/{model_id}')
        
        # Cross-check message totals against session totals
        if (message_totals['input'] != expected_input or
            message_totals['cache_read'] != expected_cache_read or
            message_totals['cache_write'] != expected_cache_write or
            message_totals['output'] != expected_output or
            message_totals['reasoning'] != expected_reasoning):
            print(f'factory-usage: message totals do not match session totals in {file_path}', file=sys.stderr)
            return 3
            
        # No assistant messages found
        if message_totals['count'] == 0:
            print(f'factory-usage: no assistant messages in {file_path}', file=sys.stderr)
            return 3
        
        # Accumulate to global totals
        totals['tokens_in'] += message_totals['input'] + message_totals['cache_read'] + message_totals['cache_write']
        totals['tokens_cached'] += message_totals['cache_read']
        totals['tokens_out'] += message_totals['output']
        totals['tokens_reasoning'] += message_totals['reasoning']
        totals['requests'] += message_totals['count']
        totals['sessions'] += 1
        totals['opencode_cost_usd'] += message_totals['cost']
    
    # Check if we processed any sessions
    if totals['sessions'] == 0:
        print('factory-usage: no sessions processed', file=sys.stderr)
        return 3
    
    # Set cost to null if not all costs were available
    if not all_costs_available:
        totals['opencode_cost_usd'] = None
    else:
        # Round to 6 decimal places
        totals['opencode_cost_usd'] = float(totals['opencode_cost_usd'].quantize(decimal.Decimal('0.000001')))
    
    # Sort models
    sorted_models = sorted(list(totals['models']))
    
    # Prepare output
    output = {
        'models': sorted_models,
        'opencode_cost_usd': totals['opencode_cost_usd'],
        'requests': totals['requests'],
        'sessions': totals['sessions'],
        'source': 'opencode-export',
        'tokens_cached': totals['tokens_cached'],
        'tokens_in': totals['tokens_in'],
        'tokens_out': totals['tokens_out'],
        'tokens_reasoning': totals['tokens_reasoning']
    }
    
    # Print JSON output
    print(json.dumps(output, sort_keys=True))
    return 0


if __name__ == '__main__':
    exit_code = main()
    sys.exit(exit_code)