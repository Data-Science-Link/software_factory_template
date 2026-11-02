select
    model_id,
    count(*) as runs,
    sum(tokens_in) as tokens_in,
    sum(tokens_cached) as tokens_cached,
    sum(tokens_out) as tokens_out,
    sum(actual_cost_usd) as spend_usd,
    sum(tokens_cached) / nullif(sum(tokens_in), 0) as cache_hit_rate,
    avg(case when gate_passed then 1.0 else 0.0 end) as gate_pass_rate
from {{ ref('fct_agent_runs') }}
group by model_id
