with fact as (
    select
        *,
        row_number() over (partition by issue order by started_at_utc, run_id) as issue_run_seq
    from {{ ref('stg_agent_runs') }}
)

select
    run_id,
    issue,
    pr,
    model_id,
    complexity,
    risk,
    work_type,
    cost_method,
    outcome,
    gate_passed,
    started_at_utc,
    ended_at_utc,
    cast(started_at_utc as date) as run_date,
    requests,
    tokens_in,
    tokens_cached,
    tokens_out,
    tokens_reasoning,
    predicted_cost_usd,
    actual_cost_usd,
    actual_cost_usd - predicted_cost_usd as cost_variance_usd,
    case
        when predicted_cost_usd > 0
            then (actual_cost_usd - predicted_cost_usd) / predicted_cost_usd * 100
        else null
    end as cost_variance_pct,
    tokens_cached / nullif(tokens_in, 0) as cache_hit_rate,
    cast(null as boolean) as is_merged,
    issue_run_seq,
    (issue_run_seq = 1 and gate_passed) as first_time_gate_pass,
    duration_s,
    actions_minutes
from fact