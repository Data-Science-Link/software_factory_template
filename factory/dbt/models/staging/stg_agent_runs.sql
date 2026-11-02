with deduped as (
    select
        *,
        row_number() over (partition by run_id order by ended_at desc) as rn
    from {{ ref('agent_runs') }}
)

select
    run_id,
    repo,
    issue,
    pr,
    trigger,
    triggered_by,
    harness,
    provider,
    model,
    lower(trim(model)) as model_id,
    escalated_from,
    complexity,
    risk,
    work_type,
    price_table_version,
    price_in_per_mtok,
    price_cached_per_mtok,
    price_out_per_mtok,
    requests,
    tokens_in,
    tokens_cached,
    tokens_out,
    tokens_reasoning,
    predicted_cost_usd,
    actual_cost_usd,
    cost_method,
    key_spend_delta_usd,
    cost_check,
    budget_cap_usd,
    issue_spend_to_date_usd,
    started_at,
    cast(cast(started_at as timestamptz) at time zone 'UTC' as timestamp) as started_at_utc,
    ended_at,
    cast(cast(ended_at as timestamptz) at time zone 'UTC' as timestamp) as ended_at_utc,
    duration_s,
    actions_minutes,
    runner,
    outcome,
    gate_passed
from deduped
where rn = 1
