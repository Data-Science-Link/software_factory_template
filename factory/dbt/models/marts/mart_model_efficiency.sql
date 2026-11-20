select
    model_id as model,
    harness,
    provider,
    concat_ws('::', model_id, harness, provider) as efficiency_grain_key,
    count(*) as run_count,
    sum(case when gate_passed then 1 else 0 end) as passed_count,
    round(
        avg(case when gate_passed then 100.0 else 0.0 end),
        6
    ) as pass_rate_pct,
    sum(actual_cost_usd) as total_cost_usd,
    avg(actual_cost_usd) as avg_cost_usd,
    median(actual_cost_usd) as median_cost_usd,
    case
        when sum(case when gate_passed then 1 else 0 end) > 0
            then sum(actual_cost_usd) / sum(case when gate_passed then 1 else 0 end)
        else null
    end as cost_per_passed_run_usd,
    sum(
        coalesce(tokens_in, 0)
        + coalesce(tokens_out, 0)
        + coalesce(tokens_reasoning, 0)
    ) as total_tokens,
    avg(duration_s) as avg_duration_seconds
from {{ ref('fct_agent_runs') }}
group by model_id, harness, provider